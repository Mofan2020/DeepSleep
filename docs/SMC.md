# Macs Fan Control 1.5.22 逆向分析报告

## ——它如何读取到「详细温度信息」，又如何控制系统风扇运转

> 分析对象：`/Users/mofan/Documents/temp/MacsFanControl/Macs Fan Control.app`
> 厂商：CrystalIDEA Software，Bundle ID `com.crystalidea.macsfancontrol`，版本 1.5.22 (build 89)
> 分析工具：**IDA Professional 9.5**（Hex-Rays v9.5.0.261001，headless `idat`）+ `otool/nm/lipo/strings` + **本机只读 SMC 探测**（Python/ctypes 直连 IOKit，未执行目标 App、未写入任何 SMC 键）
> 文档撰写日期：2026-10-25

### 快速导航

| 想做的事 | 直接看 |
|---|---|
| **给自己的特权 helper 写 SMC（实现风扇控制）** | **§2.8 写风扇速查卡**（可独立照抄）+ §2.6.1 写入规格 + §2.2 结构体偏移 |
| 读温度 / 枚举温度传感器 | §3.1 键枚举 · §3.2 解码 · §3.4 IOHID（Apple Silicon） |
| 理解风扇控制算法与曲线 | §4.7 控制主循环 · §4.8 温度→RPM 曲线状态机 |
| 了解特权 helper 的授权模型 | §4.5 XPC 协议 + 签名校验 + 会话归属 |
| 直接取 XML 传感器定义 | `rea-work/res/*.xml`（5 份，已解出） |
| 核对某个地址 | §8 地址索引 |
| 知道哪些结论是硬证据、哪些是推断 | **§7 观察/推断/未知汇总** |

> ⚠️ **写路径尚未端到端验证**：全文所有写入结论来自 helper 汇编逐条核对 + 读路径实测，
> **分析过程中一次真实写入都没执行过**（避免改坏风扇 / 触发权限弹窗）。首次实机验证请先写
> 一个与当前转速相同的值，确认无害后再试非零目标。


---

## 0. 结论速览

这个 App 的技术路线可以概括成一句话：**用 `IOKit` 的私有 `AppleSMC` 用户客户端拿温度和风扇状态，用一个通过 `SMJobBless` 安装的特权 helper（`com.crystalidea.macsfancontrol.smcwrite`）去写 SMC，用 IOKit HID 私有框架补齐 Apple Silicon 上已经不存在的 SMC 温度键。**

四个最关键的发现：

1. **温度不是从一个"温度接口"读的，而是被"枚举"出来的。** App 先读 SMC 的 `#KEY` 键拿到键总数，再对 SMC 键表做**二分查找**定位数据类型为 `T`（温度）的区间，然后只取首字母为 `T`、数据类型为 `sp78` 或 `flt ` 的键。解码规则是 Apple 公开但非官方的 `sp78` 定点数（`byte0 + byte1/256`）和 `flt ` 浮点数。
2. **Apple Silicon 上 `TA0P`/`TC0P`/`TC0C` 这类传统温度键根本不存在**（本机实测全部返回 `0x84` = key-not-found），所以 App 必须走 **IOHID 私有事件通道**（`PrimaryUsagePage=0xFF00` / `PrimaryUsage=5`）才能拿到 CPU/GPU/SoC 的真实温度——这是"详细温度"的真正来源。
3. **控制风扇要写 SMC 的 `F<n>...` 键，普通进程没有权限**，所以 App 自己不做写入，而是通过 **XPC** 把 `key` + `value` 交给一个 root 特权 helper 代写；helper 侧还做了**代码签名校验 + 会话归属（pid + 进程启动时间指纹）**双重授权。
4. **风扇控制的核心是一个带滞回和"半速/双速"档位的状态机**（`SensorBasedControl_Simple`），跑在 **1500 ms 周期**的控制线程里；把温度映射成 RPM 时不是线性插值，而是"每升/降 1 ℃ 走一档、每档 2 RPM、带 30 RPM 死区与 11 s/60 s 超时"的离散策略。

---

## 1. 目标与样本

### 1.1 Bundle 结构

```
Macs Fan Control.app/
├── Contents/
│   ├── Info.plist                      LSUIElement=1（无 Dock 图标），LSMinimumSystemVersion=10.13
│   ├── MacOS/Macs Fan Control          主程序，Mach-O Universal（x86_64 + arm64），7,706,496 B
│   ├── Frameworks/
│   │   ├── macked.app.dylib            7.7 MB 的注入式加载库（见 1.4）
│   │   └── Qt*.framework               Qt 5.15.17（Core/Gui/Widgets/DBus/Network/...）
│   ├── Library/LaunchServices/
│   │   └── com.crystalidea.macsfancontrol.smcwrite   特权 helper，arm64，94,672 B
│   └── Resources/...
```

`Info.plist` 关键项：

| 键 | 值 |
|---|---|
| `CFBundleShortVersionString` | `1.5.22` |
| `CFBundleVersion` | `89` |
| `CFBundleIdentifier` | `com.crystalidea.macsfancontrol` |
| `LSUIElement` | `1`（后台 agent，无主窗口） |
| `SMPrivilegedExecutables` | `{ com.crystalidea.macsfancontrol.smcwrite = <hash> }` |
| `NSHumanReadableCopyright` | `Created by CrystalIDEA Software` |

链接的框架：`IOKit`、`Security`、`ServiceManagement`、`Carbon`、`AppKit`、`Metal`、`CoreFoundation`。

### 1.2 签名状态

```
codesign -dv → Signature=adhoc, Identifier=com.crystalidea.macsfancontrol, 没有 Team ID
```

ad-hoc 签名、且注入了 `macked.app.dylib`，说明这份样本是**被重新签过、且加过壳/加载器的**版本。这对后面的两点有直接影响：

- 字符串混淆（见 §6）很可能就是壳的一部分；
- `macked.app.dylib` 里有一层"解密后再交给主程序"的加载逻辑（§6.4）。

**本报告只做技术分析，未做任何授权绕过，也未复现壳的加载过程。**

### 1.3 符号与源文件名

二进制**没有 strip**，`nm` 能拿到 6,164 个符号，包括完整的 C++ 命名空间符号（`SMC::Service`、`SMC::PlatformMac`、`QFanControl`、`TemperatureSensorSMC`、`FanProfile`、`FanControlMode`、`SensorsFromXML`、`smcWriteInstaller`、`SmcWriteHelper` …）。

`__FILE__` 字符串还还原出了原始工程结构，这对理解模块边界非常有用：

```
SMC/Service.cpp               SMC/Platform_mac.mm        SMC/Platform_mac_smcwrite.mm
FanControl/FanControl.cpp     FanControl/FanControlMode.cpp
FanControl/FanProfile.cpp     FanControl/FanProfileList.cpp
FanControl/SensorControl.cpp  Sensors/TempSensorProvider.cpp
Sensors/TempSensorSmc.cpp     Sensors/TempSensorIOKit.mm
Sensors/TempSensorGPU.cpp     Sensors/TempSensorDisk_mac.cpp
```

> 关键点：`TempSensorIOKit.mm`（`.mm` = Objective-C++）——Apple Silicon 的温度通道是单独一个模块，不是 Intel 路径的延续。

### 1.4 关于 `macked.app.dylib`

`Contents/Frameworks/macked.app.dylib` 是一个 7.7 MB 的 Universal dylib，在主程序的 `__rpath` 里被加载。它承担的是**加载期解密**职责：主程序里的字符串不是明文，而是被加密后放在 `__TEXT.__const`，由这个 dylib 在进程启动时解开（详见 §6）。

---

## 2. SMC 底层协议：与 `AppleSMC` 的私有 IOConnect 通道

所有 SMC 访问最终都落到 `Contents/MacOS/Macs Fan Control` 里的四个 C 风格函数。

### 2.1 `SMCOpen` — 建立连接

`SMCOpen` @ `0x100076b70`

```
IOMasterPort(0, &master)
  → IOServiceMatching("AppleSMC")
  → IOServiceGetMatchingServices(master, matching, &iter)
  → svc = IOIteratorNext(iter)
  → IOServiceOpen(svc, mach_task_self(), 0, &conn)
  → IOObjectRelease(iter)
```

要点：

- 匹配串固定是 `"AppleSMC"`；
- `IOServiceOpen` 必须传 `mach_task_self()`。**【实测】** 传 `0` 会返回 `0xE00002C2`（`kIOReturnNotPrivileged`），这正是很多第三方 SMC 工具踩的坑；
- 返回值 `conn` 是一个 `io_connect_t`，后续所有读写都用它。

### 2.2 80 字节请求/应答结构

所有调用都走 `IOConnectCallStructMethod(conn, 2, input, 0x50, output, &outputSize)`：

- **selector = 2**（`kSMCHandleYPCEvent`）；
- **输入、输出都是 80 字节（0x50）**；
- 同一块结构体既做入参也做出参。

**【实测】字段偏移（在本机 Apple Silicon 上逐字节验证，2026-10-25 二次全 80 字节转储校正）：**

| 偏移 | 宽度 | 方向 | 含义 |
|---|---|---|---|
| `+0x00` | 4 | 入 | Key 的 FourCC（字符反序，见 §2.4） |
| `+0x04`–`+0x1B` | 24 | 入 | 保留，必须清零 |
| `+0x1C` | 4 | 入/出 | `dataSize`：该键的数据字节数（读命令 9 时**必须回填**，否则读命令 5 拿不到值） |
| `+0x20` | 4 | 出 | **`dataType` 类型字符串**（4 字符：`flt ` / `ui8 ` / `ui16` / `ui32` / `sp78`…），**不是** key 回显 |
| `+0x24` | 4 | 出 | 未使用（实测恒为 0） |
| `+0x28` | 1 | 出 | SMC 操作状态字节（实测：命令 8 → `0x00`，命令 9 → `0x84`，命令 5 → `0x89`） |
| `+0x2A` | 1 | **入** | **命令字节**：5=ReadKey / 6=WriteKey / 8=ListKeys / 9=GetKeyInfo |
| `+0x2C` | 1 | 出 | **结果字节**：`0x00` = 成功，`0x84` = key 不存在 |
| `+0x2C` | 4 | 入 | 键索引（仅命令 8 使用，与上一行共用空间） |
| `+0x30` | 16 | 入/出 | 值的第 0–15 字节 |
| `+0x40` | 16 | 入/出 | 值的第 16–31 字节 |

两个必须注意的点：

1. **`+0x2A` 与 `+0x2C` 别搞混**：请求里 `+0x2A` 是命令字节，回包里 `+0x2C` 才是结果字节（0 = 成功，0x84 = key 不存在）。
2. **`+0x20` 放的是数据类型字符串，不是 key 名**。App 的 `SMC::key_info{uint8 dataSize; char key[4]; uint8 dataType;}` 里那个 `key[4]` 字段实际承载的正是 `flt `/`sp78` 这类类型串——所以 `getTemperatureKeys` 里是拿它跟 `"sp78"`、`"flt "` 做 `strcmp`。

> ⚠️ 这套偏移**不是** Intel Mac 上广为流传的 `SMCParamStruct`（那里 `dataSize` 在 `0x34`、`bytes` 在 `0x40`）。本 App（以及它的 helper）用的是自己的一套布局，并且**在本机实测可用**。这是做逆向/自研工具时最容易踩错的地方。

### 2.3 命令字节

| 值 | 语义 | 说明 |
|---|---|---|
| `5` | `ReadKey` | 读值 |
| `6` | `WriteKey` | 写值 |
| `8` | 列举键 | 索引放在 `+0x2C`，返回的键名在应答 `+0x00` |
| `9` | `GetKeyInfo` | 只取 `dataSize` / `dataType`，不取值 |

**【实测】** 命令 9 对不存在的键返回 `result = 0x84`；命令 8 索引 0 返回的键名是 `"YEK#"`（内存里是 `#KEY` 的反序），再次印证 FourCC 是**字节反序存放**的。

### 2.4 FourCC 的字节序（最容易搞错的一处）

`SMCReadKey` @ `0x100076f24` 里的打包公式：

```c
key = (k[1] << 16) + ((uint8_t)k[0] << 24) + (k[2] << 8) + k[3];
```

也就是说 `"#KEY"` 会被算成 `0x59454B23`，再以**主机序（小端）**写进结构体的 `+0x00`，于是在内存里 4 个字节是 `23 4B 45 59`——**正好是字符反序**。

**【实测】** 把 `"#KEY"` 正序写进去会失败；按上面的公式（等价于 `struct.pack_into('<I', buf, 0, struct.unpack('>I', b'#KEY')[0])`）写进去立刻成功。Apple Silicon 上 SMC 的 key 槽位确实是这个反序布局。

### 2.5 `SMCReadKey` — 两阶段读

`SMCReadKey` @ `0x100076f24`：

1. **先发一次命令 9（GetKeyInfo）**，拿到这个键的 `dataSize` 和 `dataType`；
2. **再发一次命令 5（ReadKey）**，值从应答 `+0x30` 起的 32 字节区取出；
3. 整个过程由一个 **per-4CC 的键缓存**兜底：`std::map` @ `0x1002ED900` 存 `{dataType, 4 字符 key}`，命中就不再发命令 9。

所以稳态下每个键**只发一次** IOConnect 调用；首次访问某个键才多一次。

> ⚠️ **【实测】踩坑点：读命令 5 必须先回填 `dataSize`。**
> 如果发命令 5 时请求结构体的 `+0x1C` 是 0，SMC **不会报错**，而是安静地返回全 0 的值——看起来像"读到了 0"。
> 实测对照（同一台机器、同一个键）：
>
> ```
> F0Mn   cmd5 不带 size → 00 00 00 00     cmd5 带 size=4 → 00 e0 95 44 (=1171.0)
> #KEY   cmd5 不带 size → 00 00 00 00     cmd5 带 size=4 → 00 00 06 de (=1758)
> FNum   cmd5 不带 size → 00 00 00 00     cmd5 带 size=1 → 01
> ```
>
> App 的实现正是这样：命令 9 拿到 `dataSize` 后，把 `input+0x1C` 填上再发命令 5（`SMCReadKey` 汇编 `0x1000770d0`：`ldr w8,[x19,#8]; stur w8,[x29,#-0x5c]`）。

失败时返回 `SMCKernCodeToString` @ `0x10007739c` 的错误串，例如 `0xE00002BC`（`kIOReturnError`）、`0xE00002C0`（`kIOReturnNoDevice`）、`0xE00002C7`（`kIOReturnUnsupported`）、`0xE0000001`（`kIOReturnInvalid`）。

### 2.6 `SMCWriteKey` — 先读后写，且强制长度一致

`SMCWriteKey` @ `0x100077294`：

1. 先 `SMCReadKey` 一次，拿到该键**真实的** `dataSize`；
2. **请求写入的长度必须与该键声明的长度一致**，否则直接返回 `0xE00002BC`（`kIOReturnError`）——SMC 不允许改变键的长度；
3. 组包：`+0x00` 放 FourCC、`+0x1C` 放 `dataSize`、`+0x2A` 放命令 `6`、`+0x30`/`+0x40` 放值；
4. 调用 `IOConnectCallStructMethod(conn, 2, in, 0x50, out, &80)`。

helper 里的实现是同一套逻辑（`SMCWriteKey` @ `0x100002f9c`，helper 二进制），只是寄存器安排不同。

### 2.6.1 写入规格（可直接照抄实现，已逐条核对汇编与实测）

helper 的 `SMCWriteKey` 汇编（`0x100002f9c`–`0x10000306c`）把组包过程暴露得很干净：

```
SMCWriteKey(conn, staging, key):
    staging = { char key[4] @+0x00 ; UInt32 size @+0x08 ; byte value[0..15] @+0x11 ; byte value[16..31] @+0x21 }

    SMCReadKey(key, &info, conn)            // 先读一次
    if (rc != 0) return rc
    if (info.dataSize != staging.size) return 0xE00002BC      // 长度必须完全一致

    in  = zeroed 80 bytes
    out = zeroed 80 bytes
    // 值的 32 字节：
    memcpy(in + 0x30, staging.value,      16)   // 低 16 字节 → in+0x30
    memcpy(in + 0x40, staging.value + 16, 16)   // 高 16 字节 → in+0x40
    // 四元组：
    in[0x00..0x04) = fourcc(key)               // 字符反序，见 §2.4
    in[0x1C..0x20) = uint32(info.dataSize)     // 必须回填真实长度
    in[0x2A]      = 6                          // WriteKey
    // in[0x04..0x1C) 与 in[0x20..0x30) 保持 0
    cnt = 80
    return IOConnectCallStructMethod(conn, 2, in, 0x50, out, &cnt)
```

FourCC 打包公式（主程序与 helper 完全一致）：

```c
uint32_t fourcc(const char *k) {
    return (uint32_t)k[1] << 16 | (uint32_t)(uint8_t)k[0] << 24
         | (uint32_t)k[2] << 8  | (uint32_t)k[3];
}
// 等价于：struct.pack_into('<I', buf, 0, struct.unpack('>I', b'F0Tg')[0])
```

**风扇相关的两类写入：**

| 键 | 类型 / 长度 | 写什么 |
|---|---|---|
| `F<n>Md`（或小写 `F<n>md`） | `ui8` / **1 字节** | `0x00` = 交回 SMC 自动；`0x01` = 手动 |
| `F<n>Tg` | `flt ` / **4 字节** | **IEEE754 小端 float**，值 = 目标 RPM（例：2500.0 → `44 9C 40 00`） |
| `F<n>Sf`（老机型） | `ui16` / **2 字节** | 大端序的 `RPM × 4`：高字节 = `rpm >> 6`，低字节 = `(rpm × 4) & 0xFF` |

2 字节形式的读回换算（App 的 `bswap32(LOWORD(v)) >> 18` 就是这个逆运算）：
`u16LE = (rpm>>6) | ((rpm*4 & 0xFF) << 8)` → `bswap32(u16LE) >> 18 == rpm`（实测等式成立）。

**写风扇的完整顺序（不可颠倒）：**

```
1. 写 F<n>Md = 1            // 先切到手动模式
2. 写 F<n>Tg = float(rpm)   // 再写目标转速
3. 需要交回自动时：写 F<n>Md = 0
```

App 侧对应 `QFanControl::applyFanProfileToSMC` → `setFansControlModes` → `setFanRPM(type=3)`。

> ⚠️ 两个实操坑：
> - **写入长度必须等于该键声明的长度**，否则直接 `0xE00002BC`。所以每个键都要先用命令 9 查一次 `dataSize`。
> - 本机实测 `F0Mn`（最低转速）= **1171.0**、`F0Mx`（最高转速）= **7296.0**。App 只写 `F0Tg`、不写 `F0Mn`；若目标 RPM 低于该机型的 `F0Mn`，部分机型会拒绝执行——**这一点我没有实测验证**（全程只读），你实现时建议把 `F0Mn` 也一并抬高到目标值附近，或至少留足余量。

### 2.6.2 本机风扇键实测快照

```
#KEY   size=4 type='ui32' raw=00 00 06 de   → 1758 个键
FNum   size=1 type='ui8 '  raw=01           → 1 个风扇
F0Md   size=1 type='ui8 '  raw=00           → 当前=自动
F0Ac   size=4 type='flt '  raw=00 00 00 00 → 实际转速 0.0
F0Mn   size=4 type='flt '  raw=00 e0 95 44 → 最低 1171.0
F0Mx   size=4 type='flt '  raw=00 f8 e0 45 → 最高 7296.0
F0Tg   size=4 type='flt '  raw=00 00 00 00 → 目标 0.0
F0Sf   size=2 type='ui16'  raw=00 00        → 速度 0
```

### 2.7 `SMC::PlatformMac` —— 平台层与"只读模式"

`SMC::PlatformMac` 是 `SMC::Service` 与 IOKit 之间的抽象层（`SMC/Platform_mac.mm`）。

| 函数 | 地址 | 职责 |
|---|---|---|
| `open` | `0x100077a74` | 打开连接 + 决定是否连接 helper |
| `readKey` | `0x1000780d4` | 加平台互斥锁 → `SMCReadKey` → 拷出 `min(dataSize, 请求长度)` 字节 |
| `writeKey` | `0x100078ae4` | **所有写都转发给 `SmcWriteHelper::write`（XPC）** |
| `getKeyInfo` | `0x10007854c` | 命令 9 探测 |
| `probeKey` | `0x100078828` | 命令 9 探测，返回 0=存在 / 1=不存在 / 2=IO 错误 |
| `getKeyByIndex` | `0x1000782a0` | 命令 8 列举键 |
| `connectToSMCWrite` | `0x100077e54` | 连接特权 helper |
| `close` | — | 关闭连接 |

`open` 的返回值即运行模式：

- `0` = 完全可用；
- `1` = **只读模式**（App 属性 `no-smc-write` 被设置 → 打印 `"connectToSMCWrite skipped"`，不连 helper）；
- `2` = 连接 helper 失败。

`writeKey` 会先检查 App 属性 `smc-write-installed`；没设置就先 `connectToSMCWrite()`，失败时打印 `"connectToSMCWrite failed!"` / `"_writeHelper not connected!"`。

> 这两条属性就是用户可见选项 `APP_FLAG_NO_SMCWRITE`（不装 helper / 只读）以及 `PREF_MAC_DONT_CHECK_SMC_HELPER_TOOL` 的内部实现。

### 2.8 写风扇速查卡（给实现者）

> 本节可独立照抄，不依赖前文。所有偏移均已在本机实测或逐条核对汇编。

**第 0 步：打开连接（特权进程内做）**

```c
io_connect_t conn;
IOServiceMatching("AppleSMC") → IOServiceGetMatchingServices → IOIteratorNext
IOServiceOpen(svc, mach_task_self(), 0, &conn)      // 必须传 mach_task_self()
```

**第 1 步：探测键是否存在及其真实长度/类型**

```c
in.key = fourcc("F0Tg"); in.command = 9;            // GetKeyInfo
IOConnectCallStructMethod(conn, 2, &in, 0x50, &out, &cnt);
if (out.result) return 键不存在;                     // out.result @ +0x2C, 0x84
// out.dataSize @ +0x1C, out.dataType 字符串 @ +0x20
```

**第 2 步：写模式键（1 字节）**

```c
uint8_t one = 1;
smc_write(conn, "F0Md", &one, 1);    // 1 = 手动；0 = 交回 SMC 自动
// 注意：模式键拼写可能是 "F0Md" 或 "F0md"，先用命令 9 探测哪个存在
```

**第 3 步：写目标转速（4 字节小端 float）**

```c
float rpm = 2500.0f;
smc_write(conn, "F0Tg", &rpm, 4);   // 'flt ' 类型，4 字节；值即 RPM
```

**第 4 步：校验（建议）**

```c
in.key = fourcc("F0Tg"); in.command = 9; ... 拿到 dataSize=4
in.command = 5; in.dataSize = 4;               // ← 必须回填 dataSize，否则静默返回 0
IOConnectCallStructMethod(...);
float now; memcpy(&now, out.bytes, 4);          // out.bytes @ +0x30
```

**三条硬性约束**

1. 写入长度必须 **等于** 该键声明的 `dataSize`，否则 `0xE00002BC`；
2. 读命令 5 **必须** 在请求里回填 `dataSize`，否则**不报错、静默返回全 0**；
3. 顺序必须 **先模式后目标**。

**本机可直接用的实测值（Apple Silicon，1 个风扇）**

```
FNum = 1        F0Md = 0（自动）    F0Mn = 1171.0    F0Mx = 7296.0
F0Tg = 0.0      F0Ac = 0.0          F0Sf = 0         #KEY = 1758
```

**其他机型的差异**（必须运行时探测，不要硬编码）

- 模式键大小写：`F0Md` ↔ `F0md`；
- 转速键长度：4 字节 float（现代）↔ 2 字节定点 `RPM×4`（老机型）；
- 是否存在全局模式键 `FS! `（2 字节位掩码）与辅助键 `Ftst`；
- 温度键集合：Intel 用 `smcSensors.xml`，Apple Silicon 用 `smcSensorsArm.xml`。

---

## 3. 温度读取全链路

### 3.1 第一步：把 SMC 键表枚举出来

#### 3.1.1 键总数

`sub_100050608`（`SMC/Service.cpp` 中的 `getSMCKeysCount`）@ `0x100050608`：

```
readKey("#KEY", &raw, 4)      // 4 字节
count = bswap32(raw)          // SMC 存的是大端
if (count >= 0x10000) count = 0;   // 明显不合理 → 视为失败
```

**【实测】** 本机 `#KEY` 存在，`dataType = ui32`，`dataSize = 4`。

#### 3.1.2 按索引取键

`SMC::PlatformMac::getKeyByIndex` @ `0x1000782a0`：命令 `8`，索引写在 `+0x2C`，返回的键名在应答 `+0x00`（4 字节）。

#### 3.1.3 二分查找定位"温度键区间"

`sub_1000508C0` @ `0x1000508C0`（日志里叫 `applesmc_get_lower_bound`）：

```
lo = 0, hi = keyCount
while (lo != hi) {
    mid = (lo + hi) / 2
    lock(); type = platform->getKeyByIndex(mid)  // 取该键的 dataType 字符串
    unlock()
    if (strcmp(type, filter) < 0) lo = mid + 1; else hi = mid;
}
*out = hi;      // lower_bound
```

**关键点：比较的是键的"数据类型"字符串，而不是键名本身**——SMC 的键表是按类型分块排序的，所以可以二分。

`SMC::Service::getTemperatureKeys` @ `0x10004fdf8` 完整流程：

```
1. 若平台缓存非空 → 直接返回缓存（键列表存在 platform+80..88）
2. count = getSMCKeysCount()
3. 分配 count 条 13 字节记录
4. lo_T = lower_bound(count, "T")      // 类型为 T（温度）的区间
   lo_U = lower_bound(count, "U")      // 类型为 U 的区间
5. 若 App 级开关打开 → 放弃二分，退化为全表线性扫描
   （日志 "Ignore binary search"）
6. 否则若 lo_T == 0 || lo_U <= lo_T || lo_U >= count
   → 日志 "one of applesmc_get_lower_bound failed {}, {}, {}"，走线性扫描分支
7. 遍历 [lo_T, lo_U)：
   - 读该索引的键
   - 若 dataType 是 "sp78" 或 "flt "，且键名首字节 == 'T'(0x54)
     → 收进结果列表
   - 若平台还没记住数据类型（platform+106 == 0）
     → 记下：sp78 → 2，flt  → 4
8. 日志 "{} keys found"
```

于是最终得到的温度键集合 = **「类型为 T、键名以 T 开头、数据类型是 sp78 或 flt 」的键**。

> 这里有一个细节值得注意：`sp78` 对应的数值 **2**，`flt ` 对应的数值 **4**。这两个数字就是后面 §3.2 解码时用的"数据类型号"。

#### 3.1.4 缓存

温度键列表缓存在 `platform+80..88`（一个 `std::vector<std::string>`），只在第一次枚举后填充；后续 `getTemperatureKeys` 直接返回缓存，避免每次都去遍历 SMC 键表。

### 3.2 第二步：读单个温度并解码

`SMC::Service::getTemperature` @ `0x100050d9c`：

```
lock(platform->mutex)
rc = platform->readKey(key, &value, &size)
if (rc == 0) {
    switch (dataType) {
      case 2:  /* sp78 */  value = byte0 + byte1 / 256.0;   break;
      case 4:  /* flt  */  value = (float)raw;             break;
    }
    if (value <= 0 || value >= 127) {
        log("getTemperature - failed reading sensor {}, its value is {}")
        return error;
    }
    /* 核心传感器反转 */
    if (key ∈ {TC0C, TC1C, TC2C, TC3C, TC2S, TCAC, TCBC})
        value = 100.0 - value;
}
unlock()
```

三个要点：

1. **`sp78` 解码**：`sp78` 是 Apple 的 7.8 定点格式，只有 2 个字节有效，值为 `byte0 + byte1/256`，量程 0–255.75。`SMC::Service::getTemperature(char*)` 的变体里也内联了同一段解码。
2. **合理性校验**：温度必须 `> 0` 且 `< 127`，否则视为读取失败并打日志。**【实测】** 本机 `F0Mn`/`F0Mx`/`F0Tg` 都是 `flt ` 类型，CPU/GPU 温度在 Apple Silicon 上根本不走 SMC（见 §3.4）。
3. **核心传感器反转**：`sub_100051084` @ `0x100051084` 判断键是否属于
   `TC0C / TC1C / TC2C / TC3C / TC2S / TCAC / TCBC`
   （代码里以小端 uint32 常量 `0x43304354`、`0x43314354`、`0x43324353`、`0x43324354`、`0x43334354`、`0x43414354`、`0x43424354` 匹配）。
   命中则 `value = 100.0 - value`。
   **原因**：2023 年后的 Apple Silicon 核心温度传感器改为上报**倒序温度**（即 `100 - 真实温度`），App 必须还原。
   这是一次**针对硬件行为变更的兼容性补丁**，不是解码错误。

### 3.3 第三步：2023 核心传感器低值修正

`TemperatureSensorSMC::fixLowValueForCoreSensor2023` @ `0x100049ac8`：

```
if (value >= 11.0) return value;            // 正常值直接返回
if (!key.startsWith("Tp")) return value;     // 只有 "Tp*" 系列才需要修
// 依次尝试读 "TCDX"，失败再读 "TCMb"（各只读一次，call_once 缓存）
if (TCDX 可读)  v = read("TCDX")
else if (TCMb 可读) v = read("TCMb")
else return value
if (v != 0) {
    double cur = 本传感器当前值;
    if (cur <= 11.0) return v + random(0..2)*0.1 + 1.0;
    else             return (v + cur) * 0.5 + random(0..2)*0.1 + 1.0;
}
return value;
```

`TemperatureSensorSMC::UpdateValue` @ `0x100049cf4` 在 `getTemperature` 之后调用它，并且**只有修正后 ≥ 10.0 ℃ 才写入传感器值**（否则保留上一次的值）。

`random` 用的是 `arc4random() % 3`，即给修正值加 0/0.1/0.2 ℃ 的抖动——目的是让多个传感器读数不整齐划一。

### 3.4 第四步：Apple Silicon 的 IOHID 温度通道（"详细温度"的真正来源）

`TemperatureSensorIOKit`（`Sensors/TempSensorIOKit.mm`）。

#### 3.4.1 建立 HID 事件系统客户端

`TemperatureSensorIOKit::loadAvailableSensors` @ `0x100073828`：

```
SensorsFromXML::loadOnce();                       // 先加载 XML 传感器定义
client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
matching = {
    "PrimaryUsagePage" : 0xFF00,                  // kHIDPage_VendorDefined
    "PrimaryUsage"     : 5
};
IOHIDEventSystemClientSetMatching(client, matching);
services = IOHIDEventSystemClientCopyServices(client);
```

`0xFF00 / 5` 就是 Apple 在 IOHID 私有事件系统里暴露的 **SMC 温度传感器**通道——非公开 API，但被大量工具使用。键名 `PrimaryUsagePage` / `PrimaryUsage` 在二进制里的 CFString 常量分别位于 `0x1002e1fd8` / `0x1002e1ff8`（IDA 命名 `cfstr_Primaryusagepa` / `cfstr_Primaryusage`）。

#### 3.4.2 枚举服务、拼 key、读值

对每个 HID service：

```
product   = IOHIDServiceClientCopyProperty(svc, "Product");     // CFString → QString
location  = IOHIDServiceClientCopyProperty(svc, "LocationID");  // CFNumber → 打包进 key
key       = <product> + <locationID 打包值>                       // 形如 "SOC MTR Temp Sensor0 (0x...)"
```

`LocationID` 的打包方式（现场还原）：取低 24 位保留为 `LODWORD & 0xFFFFFF00`，最低字节单独保留，中间接 `&_mh_execute_header` 拼一个指针位——**这是把 locationID 与一个运行时基址绑定**，用于区分同名但不同物理位置的传感器。

随后对每个 service：

```
event = IOHIDServiceClientCopyEvent(svc, 15 /* kIOHIDEventTypeTemperature */, 0, 0);
value = IOHIDEventGetFloatValue(event, 983040 /* kIOHIDEventFieldTemperatureLevel */);
log("IOKit sensor: {} ({}), {} C")
if (value <= 0) { log("Skipped incorrect temperature [{}]"); continue; }
if (同 key 已存在) { log("Skipped duplicate IOKit sensor {} ({}), using {}"); continue; }
if (SensorsFromXML::sensorByKey(key) 命中) {
    构造 TemperatureSensorIOKit 对象（虚表 off_1002CDEF8），持有 IOHIDServiceClient
    加入列表
}
```

`TemperatureSensorIOKit::UpdateValue` @ `0x100073798` 是它的实时刷新：

```
event = IOHIDServiceClientCopyEvent(client, 15, 0, 0);
value = IOHIDEventGetFloatValue(event, 983040);
atomic_store(this->value, value);       // 原子 double
```

> **这就是"详细温度"的来源**：IOHID 能给出每个 SoC 传感器、每个 GPU 传感器、每个电源管理 die 的独立读数，而传统 SMC 温度键在 M 系列上已经消失。

#### 3.4.3 IOHID 传感器与显示名的映射：`IOKitSensors.xml`

从二进制 Qt 资源里提取出来的 `IOKitSensors.xml`（2,689 B）：

```xml
<iokitSensors>
  <modelMatch models="all">
    <group name="GPU Proximity">
      <iokit name="GPU MTR Temp Sensor1" type="gpu">GPU Sensor 1</iokit>
      <iokit name="GPU MTR Temp Sensor4" type="gpu">GPU Sensor 2</iokit>
    </group>
    <iokit name="gas gauge battery">Battery Gas Gauge</iokit>
    <iokit name="NAND CH0 temp" type="ssd">SSD</iokit>
    <iokit name="SOC MTR Temp Sensor0">M1 SOC Sensor 1</iokit>
    <iokit name="SOC MTR Temp Sensor1">M1 SOC Sensor 2</iokit>
    <iokit name="SOC MTR Temp Sensor2">M1 SOC Sensor 3</iokit>
    <group name="CPU Efficiency Cores Average">
      <iokit name="eACC MTR Temp Sensor0" type="cpu">CPU Efficiency Cores Package 1</iokit>
      <iokit name="eACC MTR Temp Sensor3" type="cpu">CPU Efficiency Cores Package 2</iokit>
    </group>
    <group name="CPU Performance Cores Average">
      <iokit name="pACC MTR Temp Sensor2" type="cpu">CPU Performance Cores Package 1</iokit>
      ... pACC MTR Temp Sensor3/4/5/7/8/9 → Package 2..7
    </group>
    <iokit name="ANE MTR Temp Sensor1">M1 Neural Engine</iokit>
    <iokit name="ISP MTR Temp Sensor5">M1 Image Signal Processor</iokit>
    <group name="Power Manager SOC Die Average">
      <iokit name="PMGR SOC Die Temp Sensor0" type="psu">Power Manager SOC Die 1</iokit>
      ...
    </group>
    <group name="Power Manager Die Average">
      <iokit name="PMU tdie1" type="psu">Power Manager Die 1</iokit>
      ...
    </group>
    <iokit name="Charger TQ0d" type="psu">Charger Proximity</iokit>
  </modelMatch>
</iokitSensors>
```

三个要点：

- `<iokit name="...">` 的 `name` 必须与 IOHID service 的 **`Product` 属性**完全一致；
- `type` 决定这个传感器的**语义类别**（`cpu` / `gpu` / `psu` / `ssd` / `odd`…），供 UI 分组和"按类型选传感器"用；
- `<group name="...">` 表示**多个物理传感器聚合成一个逻辑传感器**（取平均），例如 `CPU Performance Cores Average` 由 7 个 `pACC MTR Temp Sensor` 平均而来。

### 3.5 GPU 温度

`TemperatureSensorGPU`（`Sensors/TempSensorGPU.cpp`）。

`TemperatureSensorGPU::UpdateValue` @ `0x100044bc4`：

```
card = this->gpuCard;
if (card == nullptr || this->useSMC) {
    smcSensor->UpdateValue();
    this->value = smcSensor->value;          // 直接抄 SMC GPU 传感器
    return;
}
card->getCoreTemperature(&clock);            // GPU::Card::getCoreTemperature
if (temp != 0) {
    this->value = temp;
    this->extraInfo = QString("%1 rpm").arg(clock);
    return;
}
// 取不到 → 一次性切换到 SMC 方案
log("Trying SMC instead")
this->useSMC = 1;
```

**重要发现**：`GPU::ProviderMac::getCoreTemperature(GPU::Card*, int&)` @ `0x10003f734` 在这个版本里**被编译成了一句 `return 0.0;`**（`movi d0, #0 ; ret`，8 字节函数体，已用 `otool` 逐字节核对）。

也就是说：**GPU 温度永远走不到 `Metal`/`IOReport` 那条路**——GPU 的实际温度是从 **SMC 的 GPU 传感器**（`TCGC`/`TG0D`/`TGDD`/`TG0H` 等，见 `smcSensorsArm.xml`）读出来的，App 只是把这个 SMC 传感器包在 `TemperatureSensorGPU` 里，并附带一个（永远是 0 的）频率值。

`TemperatureSensorProvider::getSmcGPUDieSensor` / `getSmcIntelGPUSensor` 负责挑选具体用哪颗 SMC GPU 传感器。

### 3.6 磁盘温度（SMART）

`TempSensorDiskMac`（`Sensors/TempSensorDisk_mac.cpp`），走 **SMART**，不用 SMC：

- `TempSensorDisk::loadAvailableSensors(bool)` @ `0x100042c24`：通过 IOKit 的存储设备驱动枚举磁盘，区分 `ATA` 与 `NVME` 两种总线；
- `TempSensorDisk::readSmartDriveIdInfo` @ `0x100041798`、`readNVMeDriveInfo` @ `0x100041c74`：读 IDENTIFY DEVICE / NVMe Identify Controller；
- `TempSensorDisk::readSmartTemperature` @ `0x100041f88`（ATA SMART Attribute）、`readNVMeDriveTemperature` @ `0x100041fe8`（NVMe SMART Log）；
- `TempSensorDiskMac::UpdateValue` @ `0x100043bb8`：每次刷新重新读 SMART，取温度字段；失败时打日志 `"Unable to read NVME data"`。

二进制里内置了 smartmontools 的 ATA/NVMe 解析代码（`ata_smart_values`、`smartmontools::nvme_id_ctrl`、`smartmontools::nvme_smart_log` 都是符号名）。

是否启用磁盘温度由两个 App 设置控制（`AppSettings::getInt`，键在 `0x1002ED290` / `0x1002ED298`）。

### 3.7 传感器描述体系：5 份 XML

全部是从 Qt `rcc` 资源里提取出来的。提取方法：Qt 资源块是 gzip 成员，但头部非标准，需要用**裸 deflate 从偏移 +10 开始**解：

```python
o = zlib.decompressobj(-15); out = o.decompress(data[off+10:])
```

| 文件偏移 | 大小 | 文件名 | 作用 |
|---|---|---|---|
| `0x25abe6` | 9,901 B | `smcSensorsArm.xml` | ARM Mac 的 SMC 温度键 → 显示名 / 分组 / 类型 |
| `0x25b703` | 18,282 B | `smcSensors.xml` | Intel Mac 的同类定义 |
| `0x25b2a5` | 2,689 B | `IOKitSensors.xml` | IOHID Product 名 → 显示名 / 分组 |
| `0x25b4d0` | 1,142 B | `fanInfo.xml` | 机型 → 风扇显示名 |
| `0x25be10` | 2,321 B | `idSwapRules.xml` | 传感器 id 互换规则（按机型） |

#### `smcSensorsArm.xml` 结构

```xml
<smcSensors>
  <modelMatch models="all">
    <smc name="TA0P">Ambient</smc>
    <smc name="TB0T">Battery Max</smc>
    <group name="CPU Core (average)" key="cpucoreavg" hideSensors="0">
      <smc name="TC0c" type="cpu">CPU Core 1</smc>
      <smc name="TC1c" type="cpu">CPU Core 2</smc>
      ... TC9c → CPU Core 10
    </group>
    <smc name="TCXC" type="cpu">CPU PECI</smc>
    <smc name="TC0H" type="cpu">CPU Heatsink</smc>
    <smc name="TC0D" type="cpu">CPU Diode</smc>
    <smc name="TCGC" type="gpu">GPU PECI</smc>
    <smc name="TG0D" type="gpu">GPU Diode</smc>
    <smc name="Tg0P" type="gpu">GPU Proximity</smc>
    <smc name="Tp0P" type="psu">Power Supply Proximity</smc>
    <smc name="TPCD">Platform Controller Hub Die</smc>
    ...
  </modelMatch>
  <modelMatch models="Macmini1,1"> ... </modelMatch>
  <modelMatch models="MacBookAir2,1"> ... </modelMatch>
</smcSensors>
```

- `models="all"` 是通配；也可以写 `Macmini1,1`、`MacBookPro15,1;MacBookPro15,2` 这种精确机型列表；
- `key="cpucoreavg"` 是**组键**，也是配置档里引用的传感器 id（用户偏好文件里就存着 `baseOnCPUtemperature|2,cpu_core_average,55,85`）；
- `type` 决定分类（`cpu`/`gpu`/`psu`/`ssd`/`odd`/`airport`…）；
- `exclude="1"` 表示该机型下屏蔽这个键。

#### `fanInfo.xml`：风扇显示名

```xml
<modelMatch models="iMacPro1,1"><fan0>Dual-fan cooler</fan0></modelMatch>
<modelMatch models="MacBookPro15,1;...;MacBookPro18,1+">
  <fan0>Left side</fan0><fan1>Right side</fan1>
</modelMatch>
<modelMatch models="MacPro7,1">
  <fan0>Exhaust</fan0><fan1>Intake 1</fan1><fan2>Intake 2</fan2><fan3>Intake 3</fan3>
</modelMatch>
<modelMatch models="iMac21,1+"><fan0>Left side</fan0><fan1>Right side</fan1></modelMatch>
<modelMatch models="MacStudio1,1+"><fan0>Dual-fan exhaust</fan0></modelMatch>
<modelMatch models="MacBookAir8,1;...;Macmini8,1+"><fan0>Exhaust</fan0></modelMatch>
```

#### XML 加载流程

| 函数 | 地址 | 说明 |
|---|---|---|
| `SensorsFromXML::loadOnce` | `0x100040be8` | 一次性装载（内部有 `call_once` 保护） |
| `SensorsFromXML::loadSensorsForMatchedModel` | `0x10003fde8` | 按当前机型挑 `<modelMatch>`，逐条建传感器对象 |
| `SensorsFromXML::sensorByKey` | `0x100040fd0` | 按 key 查传感器定义（IOHID 与 SMC 两条路径都用） |
| `SensorsFromXML::removeSensorByKey` | `0x100040994` | 按机型规则删除被排除的传感器 |

### 3.8 传感器编排：`TemperatureSensorProvider::load`

`TemperatureSensorProvider::load` @ `0x100045d3c` 是总装配：

```
log("TemperatureSensorProvider::loadAvailableSensors")
1. TemperatureSensorIOKit::loadAvailableSensors()      → 存到 this+88
2. TemperatureSensorSMC::loadAvailableSensors(service) → 存到 this+16
3. 读两个 App 设置
4. 若 GPU 列表为空 → 用 SMC 的 GPU die / Intel GPU 传感器兜底
5. TemperatureSensorGPU::loadAvailableSensors(gpuProvider, smcGpuDie, smcIntelGpu) → this+64
6. 一次性初始化磁盘传感器 (call_once)
7. 若设置允许 → TempSensorDisk::loadAvailableSensors(...) → this+40
8. 标记 GPU/SMC 传感器的"可平均"属性
9. TemperatureSensorProvider::addAverageSensors(this+88)
10. log("InitialLoadThread: number of supported SMC sensors: {}")
    log("InitialLoadThread: number of supported DISK sensors: {}")
    log("InitialLoadThread: number of supported IOKit sensors: {}")
    log("InitialLoadThread: number of supported GPU sensors: {}")
```

`addAverageSensors`（`0x100045534`）把 XML 里 `<group>` 声明的多个物理传感器**聚合成一个平均值传感器**（`TemperatureSensorAverage::UpdateValue` @ `0x10004b5c0`），另有 `TemperatureSensorGreatest::UpdateValue` @ `0x10004b544` 用来取组内最大值。

---

## 4. 风扇控制全链路

### 4.1 风扇枚举

`SMC::Service::getFanCount` @ `0x10004db2c`：

```
n = readKey("FNum", 1)          // 1 字节
cache 到 platform+72
if (n == 2 && platform[107] == 1) {
    log("Dual fan: the mac has a dual-fan cooler with two syncronized fans.")
    return 1;                  // 双风扇散热器按 1 个风扇处理
}
```

**【实测】** 本机 `FNum` 存在，`dataType = ui8`，`dataSize = 1`。

`SMC::Service::getFanName` @ `0x10004dfb8`：

```
key = format("F{}I", fanIndex)      // 例：F0ID
name = readKey(key, 16)             // 16 字节字符串
if (失败) log("Unable to read fan {:d} name. smc key {}")
if (name 为空) name = format("Fan {}", fanIndex)
```

读不到时回落到 `fanInfo.xml` 里按机型定义的名字（"Left side"/"Right side"/"Exhaust"…），再兜底为 "Fan N"。

### 4.2 风扇控制模式键

这是整个控制链路的枢纽。App 需要知道"每个风扇当前是自动还是手动"。

#### 4.2.1 两种模式键布局

平台对象上有两个开关：

| 字段 | 含义 |
|---|---|
| `platform[105]` (`m_smcFanModeKey`) | 模式键布局类型：**1 = 全局单键**（`FS! `，2 字节位掩码）；**2 = 每风扇一个键** |
| `platform[110]` | 大小写选择：1 = 用小写模板 `F{}m`，0 = 用大写模板 `F{}M` |

#### 4.2.2 读取：`SMC::Service::getFansControlModes` @ `0x10004ebfc`

```
if (m_smcFanModeKey == 2) {
    for (i = 0; i < fanCount; i++) {
        key = format(platform[110] ? "F{}m" : "F{}M", i);   // 例：F0Md / F0md
        rc = readKey(key, &byte, 1);
        if (rc != 0) { log("Unable to query fan mode {}"); break; }
        result.push_back(byte != 0);                        // vector<bool>：是否手动
    }
} else if (m_smcFanModeKey == 1) {
    rc = readKey("FS! ", &mask, 2);                        // 全局位掩码
    ... 按位展开成 vector<bool>
} else {
    log("Unknown m_smcFanModeKey")
}
```

#### 4.2.3 大小写探测：`detectLowercaseManualModeKey` @ `0x100051a78`

```
a = probeKey(format("F{}m", 0))     // → "F0md"
b = probeKey(format("F{}M", 0))     // → "F0Md"
if (a != 0 && (b != 1 || a != 2))  用大写模板
else                               用小写模板
log("Fan manual mode key: {} (SMC: {} {}, {} {})")
```

不同年代的 Mac 上，模式键的拼写不一样（`F0Md` vs `F0md`），App 在启动时**主动探测**一遍并记住。

#### 4.2.4 手动模式辅助键：`detectFtstForManualControl` @ `0x100051ea4`

探测字面键 **`"Ftst"`** 是否存在，以判断这台机器是否支持进入手动模式：

```
log("Manual mode helper key {}: {}")   // "unknown" / "absent" / "present"
```

**【实测】** 本机 `Ftst` **不存在**（返回 `0x84`），`FS! ` 也不存在。

#### 4.2.5 写入：`SMC::Service::setFansControlModes` @ `0x10004f2e4`

```
if (m_smcFanModeKey == 1) {
    // 把 vector<bool> 打包成 2 字节掩码，写入 "FS! "
} else {
    if (platform[109] == 1) {
        // 需要先写 "Ftst"（1 字节，0/1），用于进入/退出手动模式
        writeKey("Ftst", &firstFanManualBit, 1);
    }
    for (i = 0; i < fanCount; i++) {
        key = format(platform[110] ? "F{}m" : "F{}M", i);
        writeKey(key, &manualBit, 1);
        if (rc != 0) log("Unable to set fan {} control mode");
    }
}
if (platform[107] == 1 && fanCount != 1)
    log("Dual fan: unexpected error, must be only one fan")
```

> **注意**：这里也是写 SMC，因此同样**必须经过特权 helper**（`SMC::PlatformMac::writeKey` 内部一律转发给 `SmcWriteHelper::write`）。

### 4.3 风扇 RPM 键：五种类型

`SMC::rpmTypeToString(FanTpmType, fanIndex)` @ `0x10004e7c0` 把"类型 + 风扇号"格式化成具体键名：

| `FanTpmType` | 模板全局变量 | 混淆后的前缀 | 推断的完整模板 | 语义 |
|---|---|---|---|---|
| 0 | `0x1002ED368` | `F{}A` | `F{}Ac` | Actual，当前实际转速 |
| 1 | `0x1002ED358` | `F{}M` | `F{}Mn` | Min，允许的最低转速 |
| 2 | `0x1002ED360` | `F{}M` | `F{}Mx` | Max，允许的最高转速 |
| 3 | `0x1002ED370` | `F{}T` | `F{}Tg` | Target，**写转速用的就是它** |
| 4 | `0x1002ED378` | `F{}S` | `F{}Sf` | Speed，另一种转速表示（ui16 定点） |

`SMC::Service::getFanRPM(key, &rpm)` @ `0x10004e26c`：

```
lock()
rc = readKey(key, &raw, m_smcFanKeySize)
if (rc == 0) {
    rpm = bswap32(LOWORD(raw)) >> 18;          // 2 字节情形：定点 /4
    if (m_smcFanKeySize == 4) rpm = (int)raw;   // 4 字节情形：直接取整
}
else log("Unable to read fan rpm, smc key {}")
unlock()
```

`m_smcFanKeySize` 由 `sub_10004D578`（`SMC::Service::doInit`）在启动时探测：把 `F{}M` 模板（风扇 0）用 `getKeyInfo` 问一次，记下 `dataSize` 与 `dataType`，日志为 `"detectSmcFanKeySize KeyType {}"` / `"detectSmcFanKeySize KeyLen {}"`；失败时打 `"Unexpected failure at getKeyInfo for SMC_KEY_FANS_CONTROL_MODE, using 2"`（回退成 2 字节）。

**【实测】** 本机风扇键清单与类型：

| 键 | dataType | dataSize | 状态 |
|---|---|---|---|
| `FNum` | `ui8` | 1 | ✅ 存在 |
| `F0Ac` | `flt ` | 4 | ✅ 存在 |
| `F0Md` | `ui8` | 1 | ✅ 存在（**1 字节 ⇒ 正是"模式"键**） |
| `F0Mn` | `flt ` | 4 | ✅ 存在 |
| `F0Mx` | `flt ` | 4 | ✅ 存在 |
| `F0Tg` | `flt ` | 4 | ✅ 存在 |
| `F0Sf` | `ui16` | 2 | ✅ 存在 |
| `F0A` / `F0M` / `F0m` / `F0T` / `F0S` / `F0I` / `F0ID` | — | — | ❌ 不存在（`0x84`） |
| `Ftst` / `FS! ` / `LKSB` | — | — | ❌ 不存在 |
| `TA0P` / `TC0P` / `TC0C` / `TCGC` | — | — | ❌ **不存在**（Apple Silicon 无 SMC 温度键） |

这组实测数据把 §4.3 的映射钉死了：**只有 4 字符的 `F0X` 是不存在的，真实键一律是 `F0` + 3 字符**，即模板必须是 5 字符 `F{}` + 2 个字符，而不是 4 字符。

`QFanControl::UpdateFanInfo` @ `0x10002f0a4` 每次刷新读三个值：

```
current = getFanRPM(service, i, type=0, &v)   // Actual
min     = getFanRPM(service, i, type=1, &v)   // Min
max     = getFanRPM(service, i, type=2, &v)   // Max
```

### 4.4 写 RPM：`SMC::Service::setFanRPM`

`SMC::Service::setFanRPM(index, type, rpm)` @ `0x10004e9e8`：

```
key = rpmTypeToString(type, index)
SMC::Service::setFanRPM(key, rpm)               // @ 0x10004e428
    → SMC::PlatformMac::writeKey(key, &rpm, size)
    → SmcWriteHelper::write(key, bytes)         // XPC
```

调用方一律传 `type = 3`（即 Target 键 `F0Tg`）。

双风扇机型有额外约束：风扇号必须是 0，日志 `"Dual fan: unexpected error, fan index is supposed to be 0"`。

`QFanControl::SetFanRPM` @ `0x10003248c` 是 UI 层的入口。

### 4.5 特权 helper `smcwrite`：XPC 协议与授权模型

helper 二进制：`Contents/Library/LaunchServices/com.crystalidea.macsfancontrol.smcwrite`，arm64，94,672 B，**未 strip**，由 `SMJobBless` 以 `SMPrivilegedExecutables` 声明安装。

#### 4.5.1 XPC 线格式

用的是**老式 `xpc_*` C API**（不是 `NSXPCConnection`）：

```
xpc_connection_create_mach_service("com.crystalidea.macsfancontrol.smcwrite",
                                   &dispatch_main_queue, 1 /* LISTENER */)   @ 0x1000044e4
xpc_connection_set_event_handler(conn, handler)                              @ 0x100004514
xpc_connection_resume(conn)                                                 @ 0x100004528
dispatch_main()                                                             @ 0x10000452c
```

事件处理函数 `__XPC_Connection_Handler` 的 block_invoke @ `0x1000045c0` 读 `"command"` 字段（`0x10000464c`），用 `strcmp` 分派：

| command | 处理函数 |
|---|---|
| `"open"` | `process_command_open` @ `0x1000038bc` |
| `"close"` | `process_command_close` @ `0x100003eb4` |
| `"write"` | `process_command_write` @ `0x10000408c` |

`"write"` 的载荷：

```
"key"   : string     @ 0x1000062ea，读于 0x100004168
"value" : string     @ 0x1000062ee，读于 0x10000417c
```

#### 4.5.2 值的编码：十六进制字符串

GUI 侧 `SmcWriteHelper::write` @ `0x10007b008` 把字节数组转成**小写十六进制字符串**：

```c
snprintf(p, 3, "%02x", byte);       // @ 0x10007b0cc，每字节 2 个字符
```

helper 侧 `process_command_write` @ `0x10000408c` 解析：

```
len = strlen(value);
if (len == 0 || len % 2 != 0 || len >= 0x41)  → "value length %zu is not valid"
for (i = 0; i < len; i += 2) {
    if (!isxdigit(value[i]) || !isxdigit(value[i+1])) → "value is not a hex string"
    buffer[17 + i/2] = strtol(pair, NULL, 16);
}
```

即 **2–64 个十六进制字符 → 1–32 字节**。

#### 4.5.3 Key 的编码

helper 侧直接截断：

```c
strncpy(buffer, key, 5);   // @ 0x100004388 / 0x10000438c
buffer[4] = 0;             // @ 0x100004390
```

所以 key 恒为 4 个 ASCII 字符。

#### 4.5.4 应答格式

`send_command_reply` @ `0x100003810` 固定返回三个字段：

```
"command" = "reply"    @ 0x100005fe2，set @ 0x100003854
"type"    = int64      @ 0x100005fe8，set @ 0x100003868   // 0 = 成功，1 = 失败
"msg"     = string     @ 0x100005fed，set @ 0x10000387c
```

通过 `xpc_dictionary_create_reply` @ `0x100003838` → `xpc_connection_send_message` @ `0x100003888` 发回。

#### 4.5.5 helper 内部的 SMC 写

`SMCWriteKey` @ `0x100002f9c`（helper 二进制）：

```
1. SMCReadKey @ 0x100002c2c  先读一次，拿到该键的真实长度
2. 请求长度 != 实际长度 → 返回 0xE00002BC  (@ 0x10000306c)
3. 组 80 字节请求：
   +0x00  FourCC（@ 0x10000300c–0x100003028，存入 @ 0x100003034）
   +0x1C  dataSize (@ 0x100003038)
   +0x2A  命令字节：6=WriteKey (@ 0x10000302c)，9=GetKeyInfo (@ 0x100002d10)，5=ReadKey (@ 0x100002dc8)
   +0x30  值字节 0–15，+0x40 值字节 16–31
4. IOConnectCallStructMethod(conn, 2, in, 0x50, out, &80)   // selector 2，80 字节
```

helper 的 `SMCOpen` @ `0x100002878` 与主程序一致，只是 AppleSMC 不存在时返回 `0xE00002C0`（`kIOReturnNoDevice`）。

> **XPC 线上没有"读"命令**——helper 只在写之前自己读一次以校验长度。

#### 4.5.6 授权模型：两层

**第一层：代码签名校验**（`shouldAcceptNewConnection` @ `0x1000047ec`，只由 `process_command_open` 调用）

```
if (macOS >= 10.14) {
    audit_token = xpc_connection_get_audit_token(conn, &token);   @ 0x100004844
    // 打包成 NSData，属性 key = "audit"                            @ 0x100006650
    guest = SecCodeCopyGuestWithAttributes(..., attributes, ...);   @ 0x100004898
    SecCodeCopySigningInformation(guest, 8 /* kSecCodeInfoSigning */, &info);  @ 0x1000048e8
    status = info[kSecCodeInfoStatus];
    if ((status & 0x300) != 0x300) → 非 hardened+killable，只告警不拦截
        log("Warning: the peer has no CS_HARD|CS_KILL. Flags = %u")   @ 0x10000669b
    else {
        req = SecRequirementCreateWithString(
                  CFSTR("identifier \"com.crystalidea.macsfancontrol\" ..."), 0, &req);  @ 0x10000495c
        if (!SecCodeCheckValidityWithErrors(guest, req, ...)) → 拒绝连接  @ 0x1000049d8
    }
} else {
    return 1;    // < 10.14 一律接受
}
```

要点：**只有当对端同时具备 `CS_HARD | CS_KILL`（已加固且 killable）时，才强制要求其签名为 `com.crystalidea.macsfancontrol`；非加固对端（或任何一步取信息失败）一律放行**。也就是说这道防线拦的是"普通进程伪装成加固签名"，而不是做用户级授权。

**第二层：会话归属**（对每次 write/close 生效）

helper 用**进程 pid + 进程启动时间指纹**锁定唯一持有者：

```
g_smcConnection  0x10000c290     // 当前 IOKit 连接
g_szReply        0x10000c294
g_mfcProcessID   0x10000c394     // 持有者 pid
g_mfcStartTime   0x10000c3a0     // 持有者启动时间指纹
g_mfcConnection  0x10000c398
```

指纹计算（`process_command_open`）：

```
proc_pidinfo(pid, 3 /* PROC_PIDTBSDINFO */, 0, buf, 0x88);      @ 0x100004110–0x100004118
startTime = ((u64)buf[0x78] << 20) | (u32)buf[0x80];             @ 0x100004130
```

之后每次 write/close 都比对 pid 与指纹，不一致就拒绝：

```
log("process_command_write: rejected, pid %d is not the session owner (pid %d)")   @ 0x1000062a0
```

同一时刻只允许一个客户端：

- 已有持有者且仍存活 → 第二个 `open` 被拒：
  `"process_command_open: connection is still open! Current pid is %d (uid %d, alive), requested pid is %d (uid %d)"` @ `0x1000060e3`
- 持有者已消失 → 接管：`"previous owner is gone"` @ `0x100006153`

`reset_smc_session` @ `0x100003db4` 负责关闭 IOKit 连接并释放被 retain 的 XPC 连接。

#### 4.5.7 GUI 侧的失败分类

`smcWriteFailureToString` @ `0x100079520`（表 `off_1002CE078`）+ `smcWriteLastFailure` @ `0x100079514`：

| 值 | 枚举 | 触发点 |
|---|---|---|
| 0 | `None` | — |
| 1 | `ServiceUnavailable` | `xpc_error_connection_invalid`（`sub_10007A958` @ `0x10007a958`） |
| 2 | `HelperDied` | `xpc_error_connection_interrupted` |
| 3 | `HelperRefused` | helper 回包 msg 含拒绝原因 |
| 4 | `SignatureRejected` | helper 回包 msg 含 `"shouldAcceptNewConnection failed"` |
| 5 | `BadReply` | 回包格式非法 |

3/4 由 `SmcWriteHelper::connect` @ `0x10007a1cc` / `0x10007a1c0` → `0x10007a1d4` 判定。

客户端函数：`SmcWriteHelper::connect` @ `0x100079a30`（发 `{"command":"open"}` @ `0x100079c14`/`0x100079c1c`）、`SmcWriteHelper::write` @ `0x10007b008`（发 `{"command":"write","key":…,"value":…}` @ `0x100079b078`/`0x100079b090`/`0x100079b0fc`）。

### 4.6 配置档与预设

`FanControlMode` 枚举（`FanControlMode::toString` @ `0x1000358d0`）：

| 值 | 字符串 | 含义 |
|---|---|---|
| 0 | `INVALID` | 无效 |
| 1 | `FanControlNotAssigned!` | 未指定 |
| 2 | `0` | 自动（交回 SMC） |
| 3 | `1,<rpm>` | 恒定转速 |
| 4 | `2,<key>,<min>,<max>` | 传感器驱动 |

`FanControlMode::fromString` @ `0x100035ce8` 反解析，`FanControlMode::sensor` @ `0x10003630c` 构造类型 4。

`FanProfile`（`FanProfile::toString` @ `0x100037524`、`getFanMode` @ `0x100038220`、`setFanMode` @ `0x100038260`）是"每个风扇一个模式"的集合，整体序列化成一行文本存进偏好设置。**【实测】** 本机偏好文件里就有：

```xml
<key>CustomPresets</key>
<array><string>YmFzZU9uQ1BVVGVtcGF0dXJlfDIsY3B1X2NvcmVfYXZlcmFnZSw1NSw4NQ==</string></array>
```

Base64 解码 = `baseOnCPUtemperature|2,cpu_core_average,55,85`：

- 预设名 `baseOnCPUtemperature`
- 模式 `2` = 传感器驱动
- 传感器 key `cpu_core_average` ——正是 `smcSensorsArm.xml` 里那个 `<group name="CPU Core (average)" key="cpucoreavg">` 的组键
- 温度窗口 `55`–`85` ℃

`FanProfileList`（`FanControl/FanProfileList.cpp`）负责预设的增删改查与"当前激活预设"（偏好里的 `ActivePreset = "Predefined:0"`）。

### 4.7 控制主循环

`QFanControl::controlFanSpeedThread` @ `0x100031aa8`，周期 **1500 ms**（`core::threads::waitForMultipleEvents`）：

```
for each fan i:
    mode = activeProfile->getFanMode(i)

    if (mode.type == 3 /* 恒定转速 */) {
        target = mode.rpm
        current = atomic_load(该风扇最后一次已知的 RPM)
        if (|target - current| > 0x1E (30 RPM) || forceFlag) {
            updateFansControlModeToSMC();          // 先把风扇切到手动模式
            SMC::Service::setFanRPM(i, 3 /*Target*/, target);
        }
    }
    else if (mode.type == 4 /* 传感器驱动 */) {
        sensor = TemperatureSensorProvider::sensorByKey(mode.sensorKey)
        if (sensor 存在 && sensor->value != 0) {
            rpm = FanInfo::updateSensorControl(fanInfo, sensor->value, mode);
            // 返回 -1 表示"本次不动作"
            if (rpm != -1) {
                updateFansControlModeToSMC();
                SMC::Service::setFanRPM(i, 3, rpm);
            }
        } else {
            // 传感器丢了 → 复位并退回自动模式
            FanInfo::resetSensorControl(fanInfo);
            log("ControlFanSpeedThread: reset fan mode for {}")
            newMode = FanControlMode::automatic();
            modifyActiveProfile(i, newMode, 0);
        }
    }

if (收到睡眠信号) {
    resetSensorControlForSleepMode();
    sleepProfile = getProfileToApplyForSleepMode();
    if (sleepProfile != activeProfile) {
        进入睡眠：应用睡眠配置档
        唤醒：恢复原配置档
    }
}

退出时: restoreDefaultControl();
```

两个配套函数：

- `QFanControl::updateFansControlModeToSMC` @ `0x10002e770`：把"哪些风扇是手动"的 `vector<bool>` 写进 SMC（对应 §4.2.5）。
- `QFanControl::checkFansControlModeFromSMC` @ `0x10002dbc4`：反向读取，检测用户是否在别的工具里动过风扇。

`QFanControl::applyFanProfileToSMC(profile, isSleep)` @ `0x10002e03c`：

```
for each fan:
    mode = profile->getFanMode(i)
    manualFlags[i] = (mode.type != 2)      // 除"自动"外都算手动
SMC::Service::setFansControlModes(service, &manualFlags)
if (存在恒定转速模式 || isSleep) {
    for each fan: SMC::Service::setFanRPM(i, 3, rpm)
}
```

`QFanControl::wakeSMCOnMacBookWorkaround` @ `0x10002e3dc`：日志 `"Waking SMC system"`——MacBook 上 SMC 会在长时间空闲后进入低功耗，需要"唤醒"它才能响应风扇写入。

`QFanControl::initialLoadThread` @ `0x10002f63c`：启动时的初始化线程。

### 4.8 传感器→RPM 曲线算法：`SensorBasedControl_Simple`

`FanInfo::updateSensorControl` @ `0x100036d0c` 只是一层转发，真正的算法在 `SensorBasedControl_Simple::update(ThreadSafeRPMs&, double, FanControlMode&)` @ `0x10003c704`（4,728 字节的大函数，源文件 `FanControl/SensorControl.cpp`）。

#### 4.8.1 对象状态

```cpp
struct SensorBasedControl_Simple {
    int      lastTemperature;      // +0x00
    int      targetRpm;            // +0x04   当前目标转速
    int      lastAppliedRpm;       // +0x08   上次真正下发的转速
    int      tendency;             // +0x18   0=Unknown 1=Increase 2=Decrease 3=DoNothing
    uint8_t  halfIncreaseOn;       // +0x1C
    uint8_t  doubleIncreaseOn;     // +0x1B
    uint8_t  halfDecreaseOn;       // +0x1D
    uint64_t lastAppliedAt;        // +0x10   上次下发的时间戳（秒）
    QDateTime tIncrease, tDecrease, tDoNothing;   // +0x20 / +0x28 / +0x30
    QString   name;                // +0x38
};
```

`getTendencyString()` @ `0x10003c65c` → `TendencyUnknown` / `TendencyIncrease` / `TendencyDecrease` / `TendencyDoNothing`。

#### 4.8.2 输入

- `ThreadSafeRPMs`：`uint16 minRpm`（+0x02）、`uint16 maxRpm`（+0x04）、`uint16 currentRpm`（+0x00），原子读取；
- `FanControlMode`：`int minTemp`（+0x10）、`int maxTemp`（+0x14）；
- `temperature`：当前温度（℃）。

#### 4.8.3 算法

```
rpmPerDegree = (maxRpm - minRpm) / (maxTemp - minTemp)      // 每 ℃ 对应多少 RPM
```

**① 温度低于 minTemp**

```
targetRpm = minRpm
lastAppliedRpm = -1;  lastAppliedAt = -1        // 强制下一次重新下发
return -1                                        // 本次不下发
```

**② 温度高于 maxTemp**

```
targetRpm = maxRpm
→ 走下面的正常下发流程
```

**③ 温度在区间内**（核心逻辑）

```
step = rpmPerDegree
if (lastTemperature == -1) {          // 第一次采样：只对齐，不动作
    half = minRpm + (temperature - minTemp) * step
    half = clamp(half, minRpm, maxRpm - step)
    full = clamp(half + step, ..., maxRpm)
    if (half >= currentRpm || full <= currentRpm) {
        targetRpm = half;
        tendency = Increase;
        halfIncreaseOn = 1;
        log("{}: HALF INCREASE ON")
    } else {
        targetRpm = currentRpm;
        tendency = DoNothing;
    }
    lastAppliedAt = now
    return -1                       // 第一次不动作
}

if (temperature == lastTemperature) {
    // 温度没变：只有当 tendency == DoNothing 且距上次动作 ≥ 60 s，
    // 且温度 ≤ 区间中点时才切到 Decrease，否则切回 Increase
    if (tendency == DoNothing && now - tDoNothing >= 60) {
        tendency = (temperature <= minTemp + (maxTemp-minTemp)/2) ? Decrease : Increase;
        log("{}: HALF DECREASE ON") / log("{}: HALF INCREASE ON")
    }
    return -1                       // 温度不变不下发
}

/* 温度变了 */
if (temperature > lastTemperature) {          // 升温
    log("{}: Temperature INCREASED to {}")
    switch (tendency) {
      case Unknown: log("TendencyUnknown is unexpected! (2)"); break;
      case Increase:
          if (halfIncreaseOn) log("{}: HALF INCREASE OFF");
          else { doubleIncreaseOn = 1; log("{}: DOUBLE INCREASE ON"); }
          break;
      case Decrease:
          if (now - tDecrease < 11) { log("{}: Ignoring temperature change"); return -1; }
          tendency = Increase;  tIncrease = now;  break;
      case DoNothing:
          if (now - tDoNothing < 11) { log("{}: Ignoring temperature change"); return -1; }
          tendency = Increase;  tIncrease = now;  break;
    }
} else {                                   // 降温
    log("{}: Temperature DECREASED to {}")
    switch (tendency) {
      case Unknown: log("TendencyUnknown is unexpected! (1)"); break;
      case Increase:
          if (now - tIncrease < 11) { log("{}: Ignoring temperature change"); return -1; }
          tendency = DoNothing;  tDoNothing = now;  break;
      case Decrease:
          tendency = Decrease;  tDecrease = now;  break;
    }
}

/* 计算目标 RPM */
v40 = (temperature <= maxTemp) ? temperature : lastTemperature
half = clamp(minRpm + (v40 - minTemp) * step, minRpm, maxRpm - step)
full = clamp(half + step, ..., maxRpm)

if (tendency == Increase) {
    if (half - targetRpm > 2 * step) {
        targetRpm += step / 3;                  // 差得多时先补 1/3 步
        log("{}: Adding extra {} from current rpm {}")
    }
    targetRpm += 2;                             // 常规步进：+2 RPM
    if (doubleIncreaseOn) targetRpm += 2;       // 双倍档：再 +2
    targetRpm = min(targetRpm, full);
    if (targetRpm >= full) {
        tendency = DoNothing;  tDoNothing = now;
        log("{}: PEEK MAX RPM '{}' for current temperature, do nothing now")
    }
} else if (tendency == Decrease) {
    if (targetRpm - half > step) {
        targetRpm -= step / 3;                  // 差得多时先退 1/3 步
        log("{}: Subtracting extra {} from current rpm {}")
    }
    targetRpm -= 2;
    if (halfIncreaseOn) targetRpm -= 1;         // 半速档：再 -1
    targetRpm = max(targetRpm, half);
    if (targetRpm <= half) {
        tendency = DoNothing;  tDoNothing = now;
        log("{}: PEEK MIN RPM '{}' for current temperature, do nothing now")
    }
}

if (changed) lastTemperature = temperature;

/* 下发判定 */
if (targetRpm != lastAppliedRpm) {
    lastAppliedRpm = targetRpm;
    log("{}: Setting fan speed to {}")
}
if (lastAppliedAt == -1) return -1;
if (now - lastAppliedAt < 31) return -1;      // 30 秒内不重复下发
lastAppliedAt = now;
return targetRpm;
```

#### 4.8.4 这套算法的设计意图

- **基本量程映射**：`rpm = minRpm + (T - minTemp) * (maxRpm - minRpm) / (maxTemp - minTemp)`，即把 `[minTemp, maxTemp]` 线性映射到 `[minRpm, maxRpm]`；
- **离散步进**：每次只动 ±2 RPM（`rpmPerDegree` 决定一格多大），避免转速抖动；
- **半速 / 双速档**：`HALF INCREASE`、`DOUBLE INCREASE`、`HALF DECREASE` 等状态让升温时更快、降温时更慢，或者反之；
- **时间滞回**：11 秒内忽略同向温度变化（防抖），60 秒后才允许从 DoNothing 切换方向；
- **30 秒下发节流**：`lastAppliedAt` 机制保证同一个转速不会重复写 SMC（写 SMC 要走 XPC，很贵）；
- **与主循环配合**：主循环还有一道 **30 RPM 死区**（`|target - current| > 30` 才写），两层过滤叠加。

#### 4.8.5 复位

`SensorBasedControl_Simple::reset` @ `0x10003c6e8`（由 `FanInfo::resetSensorControl` @ `0x100036d20` 调用）：

```cpp
*(_QWORD *)this = -1;          // lastTemperature = -1, targetRpm = -1
*((_DWORD *)this + 2) = -1;    // lastAppliedRpm = -1
*((_QWORD *)this + 2) = -1;    // lastAppliedAt = -1
return NAN;
```

即把状态机清零，下次调用走"第一次采样"路径。

### 4.9 睡眠 / 唤醒

- `QFanControl::getProfileToApplyForSleepMode` @ `0x100031568`：返回睡眠期间应使用的配置档（通常是"自动"或一个低转速档）；
- 主循环检测到睡眠信号（本文件 `this+1329` 的标志位）时：先 `resetSensorControlForSleepMode()`，再比较睡眠档与当前档，不同则应用；
- 唤醒时恢复原配置档；
- 线程退出时调用 `restoreDefaultControl()`，把所有风扇交回 SMC 自动控制。

---

## 5. 数据流总图

```
┌──────────────────── 温度侧 ────────────────────────────────────────┐
│ SMC 路径 (Intel 有效 / ARM 退化)                                    │
│   getSMCKeysCount("#KEY") → lower_bound("T") → 遍历区间             │
│      → 过滤: dataType ∈ {sp78, flt } 且 key[0]=='T'                │
│   getTemperature(key): sp78 = b0 + b1/256 | flt = float             │
│      → 0 < v < 127 校验 → 核心键(TC0C…) 取 100 - v                  │
│      → fixLowValueForCoreSensor2023（"Tp*" 且 <11℃ 时替换）          │
│                                                                     │
│ IOHID 路径 (Apple Silicon 主路径)                                   │
│   IOHIDEventSystemClientCreate                                     │
│      SetMatching{PrimaryUsagePage:0xFF00, PrimaryUsage:5}           │
│      CopyServices → 每 service: "Product" + "LocationID" → key      │
│      CopyEvent(15) → GetFloatValue(983040) → 温度                    │
│      → SensorsFromXML::sensorByKey 命中才建立传感器对象              │
│                                                                     │
│ GPU: 实际走 SMC GPU 传感器（ProviderMac::getCoreTemperature 是空桩） │
│ 磁盘: SMART (ATA IDENTIFY/SMART Attr, NVMe Identify/SMART Log)      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                    TemperatureSensorProvider（编排 + 分组平均）
                                   │
┌──────────────────── 风扇侧 ────────────────────────────────────────┐
│ getFanCount("FNum") ; getFanName("F<n>ID") ; fanInfo.xml 兜底        │
│ getFansControlModes: 逐扇读 F0Md/F0md (1 字节) 或全局 FS! (2 字节)    │
│ setFansControlModes: 写 F0Md/F0md；必要时先写 Ftst                  │
│ getFanRPM: type0=Actual(F0Ac) type1=Min(F0Mn) type2=Max(F0Mx)        │
│ setFanRPM: type3=Target(F0Tg)                                      │
│                                                                     │
│ 写路径: PlatformMac::writeKey → SmcWriteHelper::write (XPC)          │
│    → helper: {command:"write", key:"F0Tg", value:"<hex>"}           │
│    → helper 内 SMCWriteKey (先读校验长度) → IOConnectCallStructMethod│
│    → 应答 {command:"reply", type:0|1, msg:"..."}                    │
└─────────────────────────────────────────────────────────────────────┘
                                   │
        SensorBasedControl_Simple（温度 → RPM，滞回 + 步进 + 限速）
                                   │
        controlFanSpeedThread（1500 ms 周期，30 RPM 死区，30 s 节流）
```

---

## 6. 字符串混淆机制

App 把 15 个 SMC 相关的关键字符串加密存放，运行时解开。

### 6.1 两张表

在 `__TEXT.__const`：

| 文件偏移 | 内容 |
|---|---|
| `0x225520` | **掩码表**，15 条 × 8 字节；每条 8 字节中**偶数位是 XOR 密钥，奇数位为 0** |
| `0x225598` | **密文表**，15 条 × 8 字节；前 4 字节是密文，后 4 字节为 0 |

### 6.2 解密算法

```
plaintext[j] = cipher[j] ^ mask[2*j]      (j = 0..3)
```

验证：**15 条全部解出有意义的字符串**，无一例外：

| # | 全局变量 | 解密结果 | 用途 |
|---|---|---|---|
| 0 | `0x1002ED338` | `#KEY` | SMC 键总数 |
| 1 | `0x1002ED340` | `FNum` | 风扇数量 |
| 2 | `0x1002ED348` | `FS! ` | 全局手动模式位掩码 |
| 3 | `0x1002ED350` | `F{}I` | 风扇名/ID 模板 |
| 4 | `0x1002ED358` | `F{}M` | 风扇 RPM 模板（type 1） |
| 5 | `0x1002ED360` | `F{}M` | 风扇 RPM 模板（type 2） |
| 6 | `0x1002ED368` | `F{}A` | 风扇 RPM 模板（type 0，Actual） |
| 7 | `0x1002ED370` | `F{}T` | 风扇 RPM 模板（type 3，Target） |
| 8 | `0x1002ED378` | `F{}S` | 风扇 RPM 模板（type 4，Speed） |
| 9 | `0x1002ED380` | `F{}M` | 风扇**模式**键模板（大写） |
| 10 | `0x1002ED388` | `F{}m` | 风扇**模式**键模板（小写） |
| 11 | `0x1002ED390` | `Ftst` | 手动模式辅助键 |
| 12 | `0x1002ED398` | `LKSB` | 键盘背光 |
| 13 | `0x1002ED3A0` | `sp78` | SMC 数据类型名 |
| 14 | `0x1002ED3A8` | `flt ` | SMC 数据类型名 |

> 交叉验证：把 15×15 种掩码/密文配对全部穷举，只有**对角线**能解出可打印字符串，且 15 条结果全部语义成立——排除了巧合。

### 6.3 运行时解密器

`InitFunc_13` @ `0x100055128`，每条目的解密序列（以第 0 条为例）：

```asm
adrp x0, 0x1002e8000 ; add x0, x0, #0x60      ; 取该条目的缓冲区指针
ldr  x8, [x0] ; blr x8                        ; 由壳的加载器给出已装载的密文缓冲区
ldrb w8, [x0, #0x5] ; cmp w8, #1 ; b.ne skip  ; "已解密"标记检查
ldr  s0, [x0]                                 ; 取前 4 字节密文
ushll.8h v0, v0, #0x0                         ; 4 字节 → 8 字节零扩展（放到偶数 lane）
adrp x8, 0x100225000 ; ldr d1, [x8, #0x520]    ; 取该条目的 8 字节掩码
eor.8b v0, v0, v1                             ; 逐字节 XOR
uzp1.8b v0, v0, v0                            ; 取偶数 lane 压回 4 字节
str  s0, [x0]                                 ; 写回明文
ldrb w8, [x0, #0x4] ; mov w9, #0xa5 ; eor ; strb   ; 第 5 字节：XOR 0xA5
strb wzr, [x0, #0x5]                          ; 结尾 NUL
adrp x8, 0x1002ed000 ; str x0, [x8, #0x338]   ; 存到全局指针
```

`ushll.8h` 是**加宽移位**：把 4 个字节分别放进 4 个 16 位 lane 的低字节（偶数 lane），这样后续 `eor.8b` 正好让掩码的偶数位（密钥）与密文的对应字节配对，`uzp1.8b` 再把偶数 lane 压回 4 字节——**这正是 §6.2 公式的硬件实现**。

### 6.4 第 5 / 第 6 字节：逐条常量

第 0～2、11～14 条只额外处理**第 5 个字节**；第 3～10 条（正是全部风扇相关模板）会额外处理**第 5 和第 6 两个字节**。每条各有自己的 XOR 常量：

| # | 第 5 字节常量 | 第 6 字节常量 | 说明 |
|---|---|---|---|
| 0 | `0xA5` | — | `#KEY` |
| 1 | `0x1F` | — | `FNum` |
| 2 | `0x45` | — | `FS! ` |
| 3 | `0x39` | `0x2B` | `F{}I…` |
| 4 | `0xBF` | `0x03` | `F{}M…` |
| 5 | `0xBB` | `0xEF` | `F{}M…` |
| 6 | `0x73` | `0x49` | `F{}A…` |
| 7 | `0x69` | `0x9B` | `F{}T…` |
| 8 | `0x67` | `0xE5` | `F{}S…` |
| 9 | `0x9B` | `0xC1` | `F{}M…`（模式键） |
| 10 | `0xD9` | `0x41` | `F{}m…`（小写模式键） |
| 11 | `0x45` | — | `Ftst` |
| 12 | `0x23` | — | `LKSB` |
| 13 | `0xA1` | — | `sp78` |
| 14 | `0x75` | — | `flt ` |

（第 0～2 条的"标记"检查在 `+0x5`，第 3～14 条在 `+0x6`，说明后者的缓冲区布局多一个字节。第 0～2、11～14 条的字符串本身只有 4 字符，第 5 字节落在字符串长度之外，因此那几行的常量对最终字符串没有影响——真正起作用的是第 3～10 条。）

**【推断】风扇模板是 5 字符**，第 5 个字符在磁盘镜像里对应的密文字节是 `0x00`（表尾 4 字节全零），真正的密文由壳的加载器在运行时填入——**因此第 5 个字符无法从静态文件里直接还原**。

但可以**高置信度地推断**出来，依据有三条：

1. **【实测】** 本机真实存在 `F0Ac` / `F0Md` / `F0Mn` / `F0Mx` / `F0Tg` / `F0Sf`，而 `F0A` / `F0M` / `F0m` / `F0T` / `F0S` / `F0I` / `F0ID` 全部返回 `0x84` 不存在 → 模板必须再多一个字符；
2. **【实测】** `F0Md` 的 `dataSize = 1`，而模式键正是按 **1 字节**读的（§4.2.2）→ `F{}M`+`d` 即模式键；
3. 三条 `F{}M` 前缀的条目 ↔ 三个 `F0M*` 键（`Md`/`Mn`/`Mx`），一条 `F{}A` ↔ `F0Ac`，一条 `F{}T` ↔ `F0Tg`，一条 `F{}S` ↔ `F0Sf`，一条 `F{}I` ↔ `F0ID`，一条 `F{}m` ↔ `F0md`（大小写变体）。

由此得到最终模板表：

| 类型 | 模板 | 实际键（风扇 0） | dataType / size |
|---|---|---|---|
| Actual | `F{}Ac` | `F0Ac` | `flt ` / 4 |
| Min | `F{}Mn` | `F0Mn` | `flt ` / 4 |
| Max | `F{}Mx` | `F0Mx` | `flt ` / 4 |
| Target | `F{}Tg` | `F0Tg` | `flt ` / 4 |
| Speed | `F{}Sf` | `F0Sf` | `ui16` / 2 |
| 模式（大写） | `F{}Md` | `F0Md` | `ui8` / 1 |
| 模式（小写） | `F{}md` | `F0md` | 本机不存在 |
| 风扇名 | `F{}ID` | `F0ID` | 本机不存在（回落到 `fanInfo.xml`） |

> ⚠️ 第 5 个字符属于**推断**，不是从磁盘直接读出的事实。其余 15 条 4 字符前缀、以及整个掩码/密文机制，都是**静态可完全复现**的事实。

### 6.5 其它被混淆的东西

- **日志文件**：`QMacFanControlApp::logPath` @ `0x10000d70c`，日志每行是 base64 + 逐字节 XOR（`stringDecode` @ `0x10000cfac`，`stringEncode` @ `0x10000cd4c`）。但实测本机日志解码后仍非文本，说明实际使用的密钥比 `0x89` 更强（穷举 256 个单字节 XOR 密钥均失败）。**本报告不对其做进一步破解。**

---

## 7. 观察 / 推断 / 未知 汇总

| 结论 | 证据等级 | 依据 |
|---|---|---|
| SMC 走 `IOConnectCallStructMethod(conn, 2, …)` + 80 字节结构 | **实测确认** | 本机探测成功读出 `#KEY`/`F0Md` 等 |
| 结构体偏移 `+0x1C/+0x20/+0x24/+0x2A/+0x30` | **实测确认** | 逐字段实测 |
| 命令字 5/6/8/9 的语义 | **实测确认** | 实测行为一致 |
| FourCC 反序存放 | **实测确认** | 正序写入失败，反序成功 |
| 温度键的发现规则（T 开头 + sp78/flt） | **静态确认** | `getTemperatureKeys` 反编译 |
| `sp78 = b0 + b1/256`、`flt ` 直读 | **静态确认** | `getTemperature` 反编译 |
| 核心传感器 `100 - v` 反转 | **静态确认** | `sub_100051084` |
| IOHID 匹配 `0xFF00/5`、事件类型 15、字段 983040 | **静态确认** | `TempSensorIOKit.mm` 反编译 |
| `GPU::ProviderMac::getCoreTemperature` 是空桩（`return 0.0`） | **静态确认** | 8 字节函数体，指令逐字节核对 |
| 特权 helper 的 XPC 协议、hex 编码、签名校验、会话归属 | **静态确认** | helper 二进制完整分析 |
| 风扇模板为 5 字符，第 5 字符为 `c/d/n/x/g/f/D` | **推断（强）** | 实测键清单 + 1 字节模式键 + 命名约定 |
| `m_smcFanKeySize` 的确切取值随机器而定 | **推断** | 由 `getKeyInfo` 动态探测，失败回退 2 |
| 壳（`macked.app.dylib`）在运行时改写字符串缓冲区第 5 字节 | **推断** | 文件中该字节为 0，且解密器明确对它做 XOR |
| 写路径（`smc_write` 完整流程、值编码、模式→目标顺序） | **静态逐条核对 + 读侧实测** | helper 汇编逐条核对；**但全程未执行过一次真实写入**（只读安全考虑），端到端未验证 |
| 目标 RPM 低于该机 `F0Mn` 时是否会被 SMC 拒绝 | **未知** | App 只写 `F0Tg` 不写 `F0Mn`；本机 `F0Mn`=1171.0，未实测该行为 |
| 日志文件的加密算法 | **未知** | 单字节 XOR 穷举失败，已放弃 |

---

## 8. 地址索引（arm64 切片，基址 `0x100000000`）

### 8.1 主程序

**SMC 底层（C 风格）**

| 地址 | 符号 |
|---|---|
| `0x100076b70` | `SMCOpen` |
| `0x100076c10` | `SMCCall` |
| `0x100076f24` | `SMCReadKey` |
| `0x100077294` | `SMCWriteKey` |
| `0x10007739c` | `SMCKernCodeToString` |

**SMC 平台层**

| 地址 | 符号 |
|---|---|
| `0x100077a74` | `SMC::PlatformMac::open` |
| `0x100077e54` | `SMC::PlatformMac::connectToSMCWrite` |
| `0x1000780d4` | `SMC::PlatformMac::readKey` |
| `0x1000782a0` | `SMC::PlatformMac::getKeyByIndex` |
| `0x10007854c` | `SMC::PlatformMac::getKeyInfo` |
| `0x100078828` | `SMC::PlatformMac::probeKey` |
| `0x100078ae4` | `SMC::PlatformMac::writeKey` |

**SMC 服务层**

| 地址 | 符号 |
|---|---|
| `0x10004d4ac` | `SMC::Service::connect` |
| `0x10004d578` | `SMC::Service::doInit` / `detectSmcFanKeySize` |
| `0x10004db2c` | `SMC::Service::getFanCount` |
| `0x10004dfb8` | `SMC::Service::getFanName` |
| `0x10004e26c` | `SMC::Service::getFanRPM(std::string)` |
| `0x10004e428` | `SMC::Service::setFanRPM(std::string)` |
| `0x10004e7c0` | `SMC::rpmTypeToString` |
| `0x10004e96c` | `SMC::Service::getFanRPM(index, type)` |
| `0x10004e9e8` | `SMC::Service::setFanRPM(index, type, rpm)` |
| `0x10004ebfc` | `SMC::Service::getFansControlModes` |
| `0x10004f2e4` | `SMC::Service::setFansControlModes` |
| `0x10004fdf8` | `SMC::Service::getTemperatureKeys` |
| `0x100050608` | `getSMCKeysCount` |
| `0x1000508c0` | `applesmc_get_lower_bound` |
| `0x100050d9c` | `SMC::Service::getTemperature` |
| `0x100051084` | 核心传感器键过滤 |
| `0x100051300` | `SMC::Service::dumpSMC` |
| `0x100051a78` | `detectLowercaseManualModeKey` |
| `0x100051ea4` | `detectFtstForManualControl` |

**传感器层**

| 地址 | 符号 |
|---|---|
| `0x100045d3c` | `TemperatureSensorProvider::load` |
| `0x100045534` | `TemperatureSensorProvider::addAverageSensors` |
| `0x10004b544` | `TemperatureSensorGreatest::UpdateValue` |
| `0x10004b5c0` | `TemperatureSensorAverage::UpdateValue` |
| `0x100049960` | `TemperatureSensorSMC::isSameSensor` |
| `0x100049ac8` | `TemperatureSensorSMC::fixLowValueForCoreSensor2023` |
| `0x100049cf4` | `TemperatureSensorSMC::UpdateValue` |
| `0x10004a210` | `TemperatureSensorSMC::loadSmcSensors` |
| `0x100044bc4` | `TemperatureSensorGPU::UpdateValue` |
| `0x100044f98` | `TemperatureSensorGPU::loadAvailableSensors` |
| `0x100042c24` | `TempSensorDisk::loadAvailableSensors` |
| `0x100043bb8` | `TempSensorDiskMac::UpdateValue` |
| `0x100073798` | `TemperatureSensorIOKit::UpdateValue` |
| `0x100073828` | `TemperatureSensorIOKit::loadAvailableSensors` |
| `0x10003fde8` | `SensorsFromXML::loadSensorsForMatchedModel` |
| `0x100040be8` | `SensorsFromXML::loadOnce` |
| `0x100040fd0` | `SensorsFromXML::sensorByKey` |

**风扇控制层**

| 地址 | 符号 |
|---|---|
| `0x10002e03c` | `QFanControl::applyFanProfileToSMC` |
| `0x10002e3dc` | `QFanControl::wakeSMCOnMacBookWorkaround` |
| `0x10002e770` | `QFanControl::updateFansControlModeToSMC` |
| `0x10002e88c` | `QFanControl::loadFansFromSMC` |
| `0x10002dbc4` | `QFanControl::checkFansControlModeFromSMC` |
| `0x10002f0a4` | `QFanControl::UpdateFanInfo` |
| `0x10002f63c` | `QFanControl::initialLoadThread` |
| `0x100031568` | `QFanControl::getProfileToApplyForSleepMode` |
| `0x100031aa8` | `QFanControl::controlFanSpeedThread` |
| `0x10003248c` | `QFanControl::SetFanRPM` |
| `0x100036d0c` | `FanInfo::updateSensorControl` |
| `0x100036d20` | `FanInfo::resetSensorControl` |
| `0x1000358d0` | `FanControlMode::toString` |
| `0x100035ce8` | `FanControlMode::fromString` |
| `0x10003630c` | `FanControlMode::sensor` |
| `0x100037524` | `FanProfile::toString` |
| `0x100038220` | `FanProfile::getFanMode` |
| `0x100038260` | `FanProfile::setFanMode` |
| `0x10003c6e8` | `SensorBasedControl_Simple::reset` |
| `0x10003c704` | `SensorBasedControl_Simple::update` |
| `0x10003c65c` | `SensorBasedControl_Simple::getTendencyString` |

**helper 客户端与混淆**

| 地址 | 符号 |
|---|---|
| `0x100079a30` | `SmcWriteHelper::connect` |
| `0x100079514` | `smcWriteLastFailure` |
| `0x100079520` | `smcWriteFailureToString` |
| `0x10007a958` | XPC 回包解析 |
| `0x10007b008` | `SmcWriteHelper::write` |
| `0x100055128` | `InitFunc_13`（字符串池解密器） |

### 8.2 特权 helper `smcwrite`

| 地址 | 符号 |
|---|---|
| `0x100002878` | `SMCOpen` |
| `0x100002c2c` | `SMCReadKey` |
| `0x100002f9c` | `SMCWriteKey` |
| `0x1000030a4` | `SMCKernCodeToString` |
| `0x100003810` | `send_command_reply` |
| `0x1000038bc` | `process_command_open` |
| `0x100003db4` | `reset_smc_session` |
| `0x100003eb4` | `process_command_close` |
| `0x10000408c` | `process_command_write` |
| `0x1000044c0` | `main` |
| `0x1000045c0` | XPC 事件处理 block |
| `0x1000047ec` | `shouldAcceptNewConnection` |

---

## 附录 A：实时 SMC 探测原始数据

**方法**（只读，不写任何键）：

```python
master = ctypes.c_uint(); IOMasterPort(0, byref(master))
svc = IOServiceOpen(IOIteratorNext(IOServiceGetMatchingServices(
        master, IOServiceMatching(b"AppleSMC"), &it)),
        mach_task_self(), 0, &conn)          # 必须传 mach_task_self()

def call(key4, cmd, index=None, size=80):
    buf = (c_ubyte*80)(); out = (c_ubyte*80)()
    struct.pack_into('<I', buf, 0, struct.unpack('>I', key4)[0])   # 反序 FourCC
    if cmd:  buf[42] = cmd
    if index is not None: struct.pack_into('<I', buf, 44, index)
    IOConnectCallStructMethod(conn, 2, byref(buf), 80, byref(out), byref(c_uint(80)))
    return bytes(out)
```

**结果**（本机，Apple Silicon）：

```
#KEY   -> dataType='ui32' size=4      F0Ac  -> dataType='flt ' size=4
FNum   -> dataType='ui8'  size=1      F0Md  -> dataType='ui8'  size=1
F0Mn   -> dataType='flt ' size=4      F0Mx  -> dataType='flt ' size=4
F0Tg   -> dataType='flt ' size=4      F0Sf  -> dataType='ui16' size=2

F0A / F0M / F0m / F0T / F0S / F0I / F0ID / Ftst / FS!  / LKSB
TA0P / TC0P / TC0C / TCGC                                   -> 全部 0x84 (key not found)
```

---

## 附录 B：复现用命令

```bash
cd "/Users/mofan/Documents/temp/MacsFanControl"
mkdir -p rea-work

# 抽出 arm64 切片
lipo -thin arm64 "Macs Fan Control.app/Contents/MacOS/Macs Fan Control" -output rea-work/main_arm64
lipo -thin arm64 "Macs Fan Control.app/Contents/Library/LaunchServices/com.crystalidea.macsfancontrol.smcwrite" \
     -output rea-work/smcwrite_arm64

# IDA Pro 9.5 headless：建库 + 跑脚本
"/Applications/IDA Professional 9.5.app/Contents/MacOS/idat" -A -c \
    -o"/abs/out.i64" -S"/abs/script.py /abs/arg" -L/tmp/ida.log "/abs/input"

# IDA Pro 9.5 headless：打开已有库再跑脚本
"/Applications/IDA Professional 9.5.app/Contents/MacOS/idat" -A \
    -S"/abs/script.py /abs/arg" -L/tmp/ida.log "/abs/out.i64"

# 还原混淆字符串池
cd rea-work && python3 -c "
d=open('main_arm64','rb').read()
for i in range(15):
    m=d[0x225520+i*8:0x225520+i*8+8]; c=d[0x225598+i*8:0x225598+i*8+4]
    print(i, bytes(c[j]^m[j*2] for j in range(4)))"

# 提取 5 份 Qt XML 资源（gzip 成员，裸 deflate 从 +10 开始）
cd rea-work && python3 -c "
import zlib
d=open('main_arm64','rb').read()
for off in (0x25abe6,0x25b2a5,0x25b4d0,0x25b703,0x25be10):
    o=zlib.decompressobj(-15); print(hex(off), len(o.decompress(d[off+10:])))"
```

> 本文所列 IDA 脚本、数据库、反编译输出与提取出的 XML，均保存在
> `/Users/mofan/Documents/temp/MacsFanControl/rea-work/` 下：
> `main_arm64.i64`、`smcwrite_arm64.i64`、`scripts/`、`decomp_main/`、`decomp_helpers/`、
> `decomp_glob/`、`decomp_fan/`、`decomp_gpu/`、`decomp_more/`、`decomp_helper/`、`res/`。
