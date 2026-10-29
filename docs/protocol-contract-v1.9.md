# DeepSleep v1.9 协议契约（风扇 / 温度）

本文件是**主 Agent 钉死的跨模块契约**。三个角色（helper 端 / 应用端 / 设计）都按它实现，
不要各自发明字段名。字段名一旦定下就当已发布，改动要三边同步。

## 1. HelperCommand 新增项

全部追加到 `Shared/HelperProtocol.swift` 的 `HelperCommand` 枚举里，
**追加在 `getCPUTemperature` 之后**（不要动已有 case 的顺序，避免影响既有解析）。

```swift
/// 读风扇实时状态：数量、每个风扇的当前转速 / 最低 / 最高 / 是否手动模式。
/// 返回 payload 见 `Shared/FanModels.swift` 的 `FanState.encode()`。
/// 无参数。
case getFanState

/// 写风扇目标转速 + 模式。参数：
///   `fan`      = 风扇序号（0 起）
///   `rpm`      = 目标转速（整数；0 表示交回系统自动控制）
///   `lease`    = 租约秒数（整数）。助手在此秒数内没收到同风扇的新指令，
///                自动把该风扇交回系统自动模式。传 0 = 不设租约（危险，
///                应用侧禁止使用，只给测试用）。
///   `reason`   = 可选，写入日志。
/// 写入顺序必须是「先写模式键，后写目标键」（见 SMC.md §2.6.1）。
case setFanSpeed

/// 读全部温度传感器（IOHID 通道）。
/// 返回 payload 见 `Shared/FanModels.swift` 的 `TemperatureSnapshot.encode()`。
/// 无参数。
case getTemperatureSnapshot

/// 强制把所有风扇交回系统自动控制（安全兜底：应用退出 / 崩溃 / 租约到期时调用）。
/// 无参数。
case releaseFanControl

/// 同步「用户已同意风扇免责声明」的状态给助手。参数 `accepted` = "true" / "false"。
case setFanDisclaimerAccepted
```

**协议版本**：`HelperConstants.protocolVersion` 保持 **2** 不升。
理由沿用项目既定原则（docs/maintenance.md 3.2）：新增命令不需要升 protocolVersion，
旧助手收到会回 `unknown command`，应用侧用「unknown command」关键字识别能力缺失并静默降级。

## 2. Shared/FanModels.swift 的数据模型与编码

新建 `Shared/FanModels.swift`，**应用与助手编译同一份**（放进 `Shared/` 目录即可，
两个 target 都已包含该目录）。编码沿用 `ProcessStats` / `TerminationReport` 的既有约定：
**百分号编码 + 字段间 `|` + 记录间 `,`**，不引入 JSON。

### 2.1 风扇状态

```swift
public struct FanState: Sendable, Equatable {
    public struct Fan: Sendable, Equatable {
        public let index: Int        // 0 起
        public let name: String      // 显示名（读不到时 "Fan N"）
        public let currentRPM: Int   // 当前实际转速
        public let minRPM: Int       // 允许的最低转速（写目标值时不得低于它）
        public let maxRPM: Int       // 允许的最高转速
        public let isManual: Bool    // 当前是否处于手动模式
    }
    public let fans: [Fan]
    public let timestamp: TimeInterval
    public let stalledFans: [Int]        // 连续写不进、已停止修改转速的
    public let releaseFailedFans: [Int]   // 连交回系统控制都失败的（严重）
}
```

payload 键：
- `fans` = 记录串，字段顺序固定为 `index|name|currentRPM|minRPM|maxRPM|isManual`
  （`isManual` 写 `1` / `0`），记录间用 `,`
- `count` = 风扇数量
- `timestamp` = unix epoch 秒
- `stalled` = 逗号分隔的风扇序号（已停止修改转速的），空则空串
- `releaseFailed` = 逗号分隔的风扇序号（交还系统控制失败的），空则空串

### 2.2 连续写不进 → 停止修改、交回系统

用户硬要求：**风扇持续 60 秒改不动转速时，停止修改，交由系统控制；
交还控制权都失败（严重问题）时必须警告用户。**

判定口径（`Shared/FanWriteFailureTracker.swift`）：

- 「改不动」= 写入操作失败，**或**写后读回的实际目标转速与预期目标转速不同。
  两种都算，两种都由 `setSpeed` 的异常路径记账。
- 一次成功就清零连续失败记录。
- 升级条件：**距第一次失败 ≥ 60 秒**（`FanControl.stallThresholdSeconds`）
  **且**最近一次失败在 30 秒内（`FanControl.stallActivityGraceSeconds`）。
  后半条是为了区分「持续改不动」和「早先失败过一次、之后一直没再试」——
  用户把规则关掉之后，那个失败记录不该自己升级成「交还系统」。
- 升级动作（helper 侧，心跳每 5 秒检查一次）：
  1. 该风扇标记为「停止修改」，之后 `setSpeed`（rpm > 0）一律拒绝，
     返回 `fanStalled` 错误。`rpm == 0`（交回系统）始终允许 —— 那是安全方向。
  2. 写模式键交回系统自动控制。
  3. 交还不成功 → 记进 `releaseFailedFans`，应用侧发通知 + 界面常驻警告。
- 90°C 紧急兜底生效中**不**做升级交还：那时候风扇归兜底管，
  交回系统意味着转速可能掉下来。兜底解除后再处理。

### 2.3 进程快照里的整机 CPU 占用

`getProcessStats` 的 payload 除了 `records`，还带一个 `systemCpuPercent`：

- `systemCpuPercent` = 整机 CPU 占用百分比（0–100，100% = 全机所有核都跑满）。

**它不是各进程 `cpuPercent` 的和。** 内核时间（kernel_task）不属于任何用户
进程，求和会漏掉；而且各进程 `cpuPercent` 的口径是「占整机百分比」，
加起来没有意义。整机值由 helper 用 `host_statistics(HOST_CPU_LOAD_INFO)`
的两次采样增量算出，跟 `top` 的口径一致。

单进程 `cpuPercent` 的数据源也换了：不再用 `proc_taskinfo.pti_total_user`
（在本机 macOS 27.2 上少报 42 倍，跟 `getrusage` 对不上），改用 Mach 的
`task_for_pid` → `task_threads` → `thread_info(THREAD_BASIC_INFO)`，
把进程所有线程的 user+system 加起来。这条路需要 root，所以只能在助手侧跑。

### 2.4 温度快照

```swift
public struct TemperatureSnapshot: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public let sensorID: String   // IOHID Product 名（例："PMU tdie1"）
        public let celsius: Double
    }
    public let readings: [Reading]
    public let timestamp: TimeInterval
}
```

payload 键：
- `readings` = 记录串，字段顺序固定为 `sensorID|celsius`，记录间用 `,`
- `count` = 读数条数
- `timestamp` = unix epoch 秒

**注意**：`celsius` 用 `%.2f` 格式化。**读不到就是缺失，不许写 0** ——
0 °C 是有效数值，混进 0 会让「最高温」判定失效。

## 3. 温度通道（IOHID 私有事件系统）

**实测结论（本机 macOS 27.2 / M2 / 38 个传感器全部读到真实读数）：**

```
IOHIDEventSystemClientCreate(NULL)
  → SetMatching({ "PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5 })
  → CopyServices() → CFSet
  → 每个 service: IOHIDServiceClientCopyProperty(svc, "Product") 取名字
  → IOHIDServiceClientCopyEvent(svc, 15, 0, 0)   // 15 = kIOHIDEventTypeTemperature
  → IOHIDEventGetFloatValue(event, 0xF0000)       // 0xF0000 = kIOHIDEventFieldTemperatureLevel
```

**两个必须踩准的点（都是实测踩出来的）：**

1. `IOHIDEventGetFloatValue` 返回 **double**，不是 float。
   按 float 读会得到**全部 0.0**（arm64 返回值在 FP 寄存器低 32 位是 0），
   看起来像「传感器没数据」，实际是类型错。上一版 CPU 温度一直读不到就是这个原因。
2. 函数不在公开 SDK 头文件里，需要自己声明符号。
   链接 `-framework IOKit` 后用 `@_silgen_name` 或直接 `dlsym` 都行。
   **推荐 `dlsym`**：编译期不依赖私有符号存在，运行时取不到就优雅降级成
   「温度不可用」，而不是链接失败导致整个 app 起不来。

3. 事件类型 15 与字段 0xF0000 是本机实测值，不是从 SDK 抄的（SDK 里没有这些常量）。

**不需要 root**：普通用户进程即可读（实测 Python ctypes 直连成功）。
所以温度这条路径**不走助手**，应用侧直接读，避免给用户强加一个授权门槛。
但 `Shared/` 里的模型仍要与助手共用 —— 助手侧要读温度来执行「≥90°C 强制最大转速」兜底。

## 4. SMC 写入规格（helper 侧）

**SMC.md 里的偏移是实测过的，直接照抄，不要用网上流传的 `SMCParamStruct`：**

| 偏移 | 宽度 | 含义 |
|---|---|---|
| `+0x00` | 4 | FourCC，**字节反序**（`#KEY` → 内存里是 `59 45 4B 23`） |
| `+0x1C` | 4 | dataSize |
| `+0x20` | 4 | dataType（4 字符类型串，如 `flt `、`ui8 `） |
| `+0x2A` | 1 | 命令字节（5=读 / 6=写 / 8=列举 / 9=查信息） |
| `+0x2C` | 1 | 结果字节（0=成功，0x84=键不存在） |
| `+0x30` | 32 | 值区（低 16 字节在 +0x30，高 16 字节在 +0x40） |

**三条硬性约束：**

1. **写入长度必须等于该键声明的 dataSize**，否则返回 `0xE00002BC`。
   写之前必须先查一次 GetKeyInfo。
2. **读命令 5 必须回填 dataSize**，否则**不报错、静默返回全 0**。
3. **顺序必须先模式后目标**：写 `F<n>Md` = 1（手动）→ 再写 `F<n>Tg` = float(rpm)。
   交回自动：写 `F<n>Md` = 0。

**机型差异必须运行时探测，不得硬编码：**

- 模式键大小写：`F<n>Md` ↔ `F<n>md`（本机是 `F0Md`）
- 转速键长度：4 字节 float（现代）↔ 2 字节定点 `RPM×4`（老机型）
- 是否存在全局模式键 `FS! `（2 字节位掩码）
- 本机实测：`FNum`=1，`F0Mn`=1171.0，`F0Mx`=7296.0，`F0Tg`/`F0Ac`/`F0Mn`/`F0Mx` 都是 `flt `/4 字节

**⚠️ SMC.md 明确标注：写路径从未端到端验证过（分析阶段刻意不写任何键）。**
所以第一次真机写入必须按这个顺序：
1. 先写**与当前实际转速相同**的目标值（无害）
2. 读回校验，确认写入生效
3. 再试非零目标
4. 任何一步异常 → 立刻写 `F<n>Md` = 0 交回自动

## 5. 租约机制（安全底线，主 Agent 加的硬要求）

**没有租约的手动模式是危险的**：应用崩溃 / 被强杀 / 用户登出，风扇会永久卡在手动低速，
等于把散热交给一个已经死掉的进程。所以：

- 助手侧维护「风扇 → 租约到期时间」。
- `setFanSpeed` 每次调用**刷新**该风扇的租约。
- 助手有一个 5 秒周期的心跳，检查是否有风扇租约到期；到期即写 `F<n>Md` = 0 交回自动，
  并记日志。
- 应用侧每次改风扇状态都重发 `setFanSpeed`（租约给 15 秒）。
- 应用启动时先发一次 `releaseFanControl` 清掉上一次残留（应用被强杀时助手可能还没到期）。
- 应用正常退出时也发一次 `releaseFanControl`。

租约秒数常量放 `Shared/FanModels.swift`：`FanControl.leaseSeconds = 15`，
心跳周期 `FanControl.heartbeatSeconds = 5`。

## 6. 90°C 强制最大转速（用户硬要求，任何规则不可覆盖）

**优先级必须是最高的一档，压过用户设置的任何风扇模式与规则。**

判定：温度快照里**任意一个**传感器的读数 `>= 90.0` °C 即触发。

行为：
1. 立刻把**所有**风扇写到各自 `maxRPM`（目标转速 = max）
2. 保持手动模式
3. 记日志 + 弹一次告警（不要每次 tick 都弹）
4. 温度回落到 90 °C 以下后，经过**冷却时间 60 秒**再恢复用户原来的模式（自动 / 固定 / 规则）
   —— 冷却是为了避免温度在阈值附近抖动导致风扇反复启停

### 6.1 两侧都要有，且 helper 侧是最终防线

这条逻辑**必须同时存在于两处**：

- **应用侧**（`FanController`）：正常路径下的即时响应，用户可见状态与告警。
- **助手侧**（root helper）：应用崩溃、被强杀、租约断了之后，helper 自己读温度、自己判断、
  自己写 maxRPM。**helper 侧独立执行，不依赖应用是否还活着。**

两侧的判定阈值一致（`>= 90.0`），冷却时间一致（60 秒）。

在紧急状态下，**任何降速意图一律拒绝**，包括：
- 「交回系统自动控制」
- 「按规则调整转速」
- 应用发出的任何更低的目标转速

紧急状态只在温度回落且冷却结束后才解除。解除时写日志。

helper 侧判定用的温度来自 IOHID 通道（普通进程可读，helper 同样能读）。

## 7. 免责声明（用户硬要求）

**开启 SMC 写入功能前必须让用户明确同意免责声明。**

### 7.1 应用侧

- 同意状态持久化：`UserDefaults` key `fanControl.disclaimerAccepted`（Bool）+ `fanControl.disclaimerVersion`（Int，当前版本 = 1）
- 判定：`accepted == true && version >= 1` 才算已同意。两个 key 都满足才算。
- 正文语义有实质变化时把版本 +1，老用户下次进入要重新同意一次。
- 免责声明是**独立于「完全控制」助手授权**的一层 —— 助手权限是「能不能做」，
  免责声明是「用户知不知道风险」。两者都要过。
- 未经同意：所有 `setFanSpeed` 调用一律拒绝，UI 上写风扇的控件禁用并显示「需先同意免责声明」。
- 页面保留「查看免责声明」入口，可随时重看；关闭风扇控制时提示「将把风扇交回系统自动控制」。

### 7.2 助手侧也要有硬门禁

应用层的同意状态拦不住「绕过应用直接打 helper 协议」。因此 helper 侧独立持久化一份：

- 新增命令 `setFanDisclaimerAccepted`（参数 `accepted=true/false`）
- helper 把状态写到 root-only 的位置（`/var/db/deepsleep/fan-disclaimer.json`，0600 root）
- helper 启动时读取；未同意时**一切写 SMC 的命令**（`setFanSpeed` / `releaseFanControl`）
  直接返回失败，message 明确写「需先同意免责声明」
- 应用在用户勾选同意后，通过该命令同步给 helper；应用启动时也会同步一次当前同意状态

这样即使有人绕过 UI 直接构造协议包，helper 也会拒绝写风扇。

## 8. 自定义告警规则

在现有 `MonitorConfig` 的固定阈值之外，增加用户自定义规则列表。

规则模型（放 `DeepSleep/Core/AlertRule.swift`）：

```swift
struct AlertRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var metric: AlertMetric      // 指标
    var operator: AlertOperator  // 比较
    var threshold: Double
    var durationSeconds: Int     // 持续超阈多少秒才报
    var action: AlertAction      // 动作
}

enum AlertMetric: String, Codable, CaseIterable {
    case cpuPercent, ramPercent, singleProcessRAMGB, cpuTemperature, diskUsagePercent
}
enum AlertOperator: String, Codable, CaseIterable {
    case greaterThan, lessThan
}
enum AlertAction: String, Codable, CaseIterable {
    case notification, email, both
}
```

- 持久化 key：`alertRules.v1`（UserDefaults JSON）
- 判定与冷却沿用 `SystemMonitor` 的既有做法（5 分钟冷却、按事件种类 + 阈值独立计算）
- 触发后走 `MonitoringCoordinator` → `SystemNotifier` + `AlertWindowController` + 邮件通道
- **不要**在规则里加「冻结 / 结束进程」动作 —— 温度与内存类阈值下杀进程会造成误伤，
  这与项目既有的「温度场景只告警不杀进程」立场一致

## 9. 外部磁盘防休眠（高级选项）

实测：`kIOPMAssertPreventDiskIdle`（`"PreventDiskIdle"`）**在普通用户进程即可创建**，
`pmset -g assertions` 可见（`PreventDiskIdle 1`）。**不需要 root。**

- 实现为新的 `AssertionKind` case（`DeepSleep/Core/AssertionKind.swift`）：
  `case preventDiskIdle`，`iokitType` 返回 `"PreventDiskIdle"`，
  `requiresPrivilege` 返回 **false**（实测普通用户可创建）
- `assertionName` 用 ASCII：`"Deep Sleep - prevent disk idle"`
- 与其他 assertion 一样走 `SleepController` 的申请 / 释放路径
- **边界**：`PreventDiskIdle` 阻止的是「已连接磁盘进入低功耗态」，
  对外置 USB / Thunderbolt 盘有效；但它**不能**阻止系统在电池耗尽时关机，
  也**不是** `pmset disksleep 0`（那个是全局禁用内置盘休眠，语义不同，不要混用）。
  UI 文案要如实说明这一点，不要写成「外置盘永不休眠」。

## 10. 增强排定唤醒

现状：只有一条 `pmset schedule wake <date>`，取消是 `cancelall`（会连别人排的一起取消）。

实测 `pmset -g sched` 输出格式：
```
Scheduled power events:
 [0]  wake at 10/28/2026 03:17:00 by 'pmset'
```

增强目标：
1. **多条排定**：应用侧维护列表（持久化 `scheduledWakes.v1`），每条有 id / 时间 / 备注。
2. **按条取消**：`pmset schedule cancel <type> <date+time>`（不是 cancelall），
   避免误伤其它程序排的唤醒。
3. **循环排定**：`pmset repeat wake <weekdays> <time>`（weekdays 形如 `MTWRFSU`），
   支持「每周一三五 8:00 唤醒」。`pmset repeat cancel` 取消全部循环。
4. **读回真实状态**：排定后从 `pmset -g sched` 解析实际生效项，
   与本地列表对账（外部可能改过）。
5. 助手侧新增命令（追加到 `HelperCommand`，放在本文件 §1 那一批之后）：
   ```swift
   /// 读系统当前所有排定项。返回 payload：
   ///   `entries` = 记录串 `kind|when|owner`，记录间 `,`
   ///   `count`   = 条数
   case listScheduledEvents

   /// 排定一次唤醒（带 owner 标记，便于按条取消）。参数 `date`（MM/dd/yy HH:mm:ss）、`owner`。
   case scheduleWakeWithOwner

   /// 按条取消。参数 `date` + `kind`（默认 wake）。
   case cancelScheduledEvent

   /// 循环排定唤醒。参数 `weekdays`（MTWRFSU 子集）、`time`（HH:mm:ss）。
   case scheduleRepeatWake

   /// 取消全部循环排定。
   case cancelRepeatWake
   ```

**注意**：`pmset schedule` / `pmset repeat` 都**必须 root** → 这几条命令走助手。
`pmset -g sched` 读取不需要 root，但统一放助手侧读，避免两套解析。

## 11. UI（设计师产出）

三个新页面 + 侧边栏入口。设计师产出 `docs/ui-spec-thermal-fan.md`：

1. **温度监控**（侧边栏「诊断」段）
   - 顶部多颗温度传感器读数（不是只有 CPU 一个值 —— 本机有 38 个传感器）
   - 传感器按类别分组（SoC / GPU / 电池 / 存储 / 其它），名称用可读中文
   - 超阈值高亮
   - 「90°C 强制最大转速」这个安全兜底要在界面上明确可见
2. **风扇控制**（侧边栏「系统控制」段）
   - 每个风扇一行：当前转速 / 模式（自动 / 固定 / 规则）/ 最小 / 最大
   - 三种模式可切
   - 固定模式：转速滑杆（范围取该风扇 minRPM..maxRPM 实测值）
   - 规则模式：三个字段 —— **目标风扇**、**最低温度**、**最高温度**
     （用户原始要求就是这三个；实现上「目标风扇」指作用在哪个风扇上，
     温度区间决定该风扇的转速映射）
   - 开启前必须先同意免责声明
3. **自定义告警规则**（侧边栏「自动化」段）
   - 规则列表 + 增删改
   - 指标 / 比较 / 阈值 / 持续时间 / 动作
4. **高级选项里的「外部磁盘防休眠」开关**（放在「电源设置」页或总览页，设计师定）

界面风格：沿用现有 `SectionCard` / `Tag` / `StatusPill` / `SettingRow` 组件，
不要另起一套。macOS HIG，液态玻璃质感。
