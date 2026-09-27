# Deep Sleep

原生 Swift 编写的 macOS 睡眠管理器。目标是把 MacBook 的睡眠行为完全交给用户掌控：
既能精细地保持清醒，也能彻底禁止休眠、定时睡眠、计划唤醒。

- **Bundle ID**：`com.skyc8266.deepsleep`
- **应用名**：Deep Sleep
- **最低系统**：macOS 26.0
- **语言 / 框架**：Swift 5、SwiftUI + AppKit、IOKit、LocalAuthentication
- **当前版本**：1.2.0

---

## 功能

### 保持清醒（无需任何授权）

| 能力 | 说明 |
| --- | --- |
| 阻止空闲睡眠 | 等价于 `caffeinate -i`，系统不再因无操作而睡眠 |
| 保持屏幕常亮 | 显示器不因空闲而关闭 |
| 阻止系统睡眠 | **连合盖也不睡眠**，需要「完全控制」 |

### 完全控制（一次性授权后长期可用）

- **阻止系统睡眠（含合盖）**：通过特权助手申请 `PreventSystemSleep` assertion
- **完全禁止系统睡眠**：写入 `pmset -a disablesleep 1`，重启后依然生效
- **电源设置读写**：`sleep` / `displaysleep` / `disksleep` / `hibernatemode` / `powernap` /
  `womp` / `ttyskeepawake` / `lowpowermode` / `autorestart` / `lidwake` 等
- **计划唤醒**：`pmset schedule wake`，由系统电源服务执行

### 自动化

规则由「触发条件 → 要保持的状态」组成，引擎每 5 秒评估一次：

- **时间段**：如工作日 09:00–18:00 保持清醒（支持跨零点区间）
- **电源状态**：接入电源时 / 使用电池时
- **应用运行中**：指定的某个应用在前台运行时

规则只表达意图，实际申请与释放由控制器统一收敛，因此手动开关和规则不会互相打架。

### 其他

- 倒计时睡眠（到点自动进入睡眠）
- 菜单栏常驻：左键打开主界面，右键弹出快速设置
- 关掉所有窗口后隐藏 Dock 图标，应用继续在菜单栏后台运行
- 运行日志页
- 外部活动：谁在阻止休眠、谁改了电源设置
- 外部活动还会点名**其他会改电源设置的软件**（例如 AlDente），见下文
- 日志自动清除（按条数与天数双重裁剪）
- 自动更新：应用从 GitHub Release 拉取并自行替换，助手版本不一致时自我更新

---

## 权限模型：管理员密码只输一次

这是本项目在设计上最核心的一处取舍。

macOS 上真正彻底的睡眠控制（`PreventSystemSleep`、`pmset disablesleep`、修改电源设置、
排定唤醒）都需要 root。如果每次操作都弹密码框，体验无法接受。

因此提供一个**一次性安装、长期驻留**的特权助手：

1. 用户在「完全控制」页点击**启用完全控制** → 系统弹出**一次**管理员授权对话框
   （已配置 Touch ID 的机器上，这个对话框可以直接用指纹确认）
2. 授权被用来把助手二进制写入 `/Library/PrivilegedHelperTools/`，
   并注册一个 launchd LaunchDaemon 让它常驻
3. 此后的所有提权操作，都只要求 **Touch ID / 登录密码**做本地确认，
   再经 UNIX socket 把命令交给助手执行 —— **不会再要求输入管理员密码**

### 助手的安全设计

- socket 路径 `/var/run/com.skyc8266.deepsleep.sock`，归当前登录用户所有，权限 `0600`
- 每个连接都用 `getpeereid()` 校验对端 uid，非登录用户直接拒绝
- 可写入的 `pmset` 键有白名单，取值必须是纯数字，杜绝参数注入
- 助手只接受固定的命令枚举，不执行任何外部传入的 shell 字符串
- 助手必须以 root 运行，否则直接退出（有显式守卫）

### 完全可回退

「停用并卸载」会移除 `/Library` 下的全部文件与 launchd 任务，系统回到安装前状态。
也可手动执行 `DeepSleep/Resources/uninstall-helper.sh`。

---

## 构建

需要 Xcode 26 以上（含 macOS 26 SDK）与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen

cd DeepSleep
xcodegen generate          # 由 project.yml 生成 DeepSleep.xcodeproj
open DeepSleep.xcodeproj   # 或用命令行构建，见下
```

命令行构建：

```sh
xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Release -derivedDataPath build build

open "build/Build/Products/Release/Deep Sleep.app"
```

`project.yml` 里配置了 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`），本机可直接运行。
要分发则需要改成自己的开发者证书。

构建时会自动把 `deepsleep-helper` 嵌入
`Deep Sleep.app/Contents/Library/PrivilegedHelperTools/`。

---

## 命令行接口

Deep Sleep 可以被脚本调度：

```sh
open -a "Deep Sleep" --args --hold idle-system,display
open -a "Deep Sleep" --args --release
open -a "Deep Sleep" --args --status
```

| 参数 | 说明 |
| --- | --- |
| `--hold <kinds>` | 逗号分隔。接受 `idle-system` / `display` / `system`，以及 `idle`、`screen`、`lid`、`all` 等别名 |
| `--release` | 释放全部保持 |
| `--status` | 输出当前状态，含 `powerWatcher=`、`audits=` 等诊断字段 |
| `--wait <秒>` | 与 `--status` 配合，等一段时间后再报告（用于验证对账频率） |
| `--enable-full-control` | 触发一次性管理员授权安装特权助手，等价于界面按钮 |
| `--disable-full-control` | 卸载特权助手并恢复系统原状 |
| `--window-self-test` | 自检窗口显示与 Dock 图标策略（关窗 → 隐藏 Dock → 重开 → 恢复） |
| `--blockers` | 列出当前所有在阻止休眠的进程 |
| `--changes` | 列出检测到的电源设置改动（区分自身与外部） |
| `--rivals` | 列出其他会修改电源设置的程序 |
| `--helper-version` | 显示特权助手的版本状态与内置构建号 |
| `--update-check` | 立即检查应用更新并输出结果 |
| `--update-script` | 打印将要执行的更新器脚本（只打印，不执行；用于人工审查） |

> 注意：`--hold` / `--release` 作用于启动它的那个实例。macOS 单实例机制下，
> 对已运行的实例再次传参不会生效 —— 需要脚本化持续控制时，请用自动化规则。

---

## 外部改动的对抗

`pmset` 那类设置是系统级的持久配置，任何 root 程序都能改。用户打开「阻止睡眠」的语义
是「我不希望它睡」，所以 Deep Sleep 不会把设置写进去就不管，而是持续纠偏。

三层防护：

| 层 | 机制 | 覆盖场景 |
| --- | --- | --- |
| 1 | **3 秒周期对账** | 空闲睡眠。idle timer 以分钟计，3 秒足够抢在到点之前把设置改回去 |
| 2 | **`PreventSystemSleep` 断言加固** | 合盖、菜单「睡眠」等**主动**请求。`disablesleep` 只在 powerd 评估空闲睡眠时生效，断言才能在决策阶段挡下来 |
| 3 | **睡前拦截** | 已经走到睡眠等待路径时的最后机会。收到 `willSleep` 后系统会等待 `IOAllowPowerChange`，这段窗口里重建防护，powerd 即会取消本次睡眠 |

第 3 层的安全边界：用户没有要求阻止睡眠时**立刻放行**，并且始终有 5 秒兜底超时 ——
绝不允许出现「永远不放行」把系统吊死的状态。

关于两个常见疑问：

- **断言会被别的程序取消吗？** 不会。断言归创建它的进程所有，跨进程释放返回
  `kIOReturnNotPermitted`（已实测）。系统也确认把它算作阻止睡眠的贡献者
  （`sleep 1 (sleep prevented by ... Deep Sleep)`）。唯一失效途径是自己进程死亡，
  这也是对账要覆盖的场景之一（助手进程被重启后断言会消失）。
- **能保证一定不睡吗？** 不能。Apple 文档明确写着断言只是「建议」：
  *"In the case of low power or a thermal emergency, the system may sleep anyway
  despite the assertion."* 低电量与过热时任何软件都挡不住。

---

## 菜单栏与 Dock 图标

菜单栏图标用 AppKit 的 `NSStatusItem` 手动搭建，而不是 SwiftUI 的 `MenuBarExtra`
—— 后者的点击一律弹出它自己的面板，**无法区分左右键**，做不到「左键打开、右键设置」。

| 操作 | 行为 |
| --- | --- |
| **左键**点图标 | 打开主界面（窗口已存在则直接前置，保留界面上的选中项） |
| **右键**点图标 | 弹出快速设置菜单：三项保持开关、30 分钟倒计时、打开主界面、退出 |
| Control + 左键 | 同右键（触控板与鼠标的通用习惯） |

菜单每次弹出都重新构建，所以开关的勾选状态永远是当下的真实状态，不需要订阅同步。
需要 root 的那一项在没启用完全控制时会标注「需先启用完全控制」，而不是点了没反应。

**Dock 图标是动态的。** 关掉所有窗口后应用切换为 `.accessory` 激活策略：
Dock 图标消失，进程继续在菜单栏后台运行；再次打开界面时切回 `.regular`。
最小化的窗口仍然算「有窗口」—— 否则 Dock 图标一消失，用户就再也找不回那个窗口了。
关掉窗口后从访达或聚焦再次打开会触达 `applicationShouldHandleReopen`，把界面叫回来。

---

## 修复记录：为什么会一直报「设置被外部改回」

1.1.0 之前，日志会持续输出「检测到 disablesleep 被外部改回，立即恢复」，
大约每 3 秒一条。**但系统里的值一直是 1，没有任何程序在跟 Deep Sleep 抢控制权。**

根因是 `pmset -g` 的解析只按空格切分，而这份输出的分隔符是混用的：

```
System-wide power settings:
 SleepDisabled		1        ← TAB 分隔
Currently in use:
 standby              0        ← 空格对齐
```

`SleepDisabled` 因为切不出两段被 `guard parts.count == 2` 整行跳过，
于是每轮对账都判定「值不是 1」→ 无条件重写一遍 → 下一轮重复。
写入本身是成功的，所以系统状态一直正确，只有日志在空转。

更麻烦的是这段解析在 **app 与特权助手各有一份**，同一个 bug 存在两处。
现已合并到 `Shared/PMSetOutput.swift` 共用，并配了回归测试
`scripts/test-pmset-parse.swift`（直接编译真实源码、喂真实 `pmset` 输出做断言）。

另外补了一道防御：助手返回的读数里缺少 `SleepDisabled` 时不再当作「值为 0」，
而是回退到本地读取。这样即使装的是旧版助手，界面上的状态也是对的。

顺带修掉一个很有迷惑性的问题：助手日志里每条记录都出现两次，看起来像
「每个命令被执行了两遍」。原因是 LaunchDaemon 的 `StandardOutPath` 与
`StandardErrorPath` 都指向同一个日志文件，而代码里又显式写了这个文件 ——
同一行写了两遍。统计调用次数时必须把它算进去：改动前看到的 1406 条
`setSleepDisabled`，实际是 703 次调用，与「35 分钟 ÷ 3 秒」完全吻合。

---

## 日志不会写爆磁盘

两处日志，两套策略：

| 位置 | 存储 | 清理方式 |
| --- | --- | --- |
| 应用内「运行日志」页 | 内存，不写磁盘 | 按**条数**（默认 500，可调 50–5000）+ 按**天数**（默认 7，可调 0–365）双重裁剪 |
| 助手日志 `HelperConstants.logPath` | 文件 | 按**天**归档为 `.log.YYYY-MM-DD`；单日超 512 KB 保留尾部；超过 7 天的归档自动删除 |

两个维度都要，因为失效方式不同：只限条数时，一台安静运行的机器会把几个月前的
日志一直留着；只限天数时，一个话痨循环能在几小时内把内存撑爆 —— 对账循环正是
后者，判断一错就是每 3 秒一条（上面那条修复记录就是真实例子）。

助手日志原本超过 1 MB 就整个删掉，那等于在出问题的时候把最该看的最近几行一起丢掉；
现在改成保留尾部、并在换行处切割，不留半行乱码。

---

## 外部活动：谁在碰电源管理

电源控制是多方博弈，Deep Sleep 只是其中之一。界面上的「外部活动」页回答两个问题。

### 谁在阻止休眠

用 `IOPMCopyAssertionsByProcess()` 直接向内核取当前所有电源断言，按进程分组，
标出是「阻止系统睡眠」还是「仅阻止屏幕睡眠」，并显示断言原因字符串。
Deep Sleep 自己的断言也会列出并标记「本应用」，方便对照。

`UserIsActive` 这类不计入 —— 那是系统对「用户正在操作」的描述，
不是某个程序在索要保持清醒。

进程名优先用 `NSRunningApplication` 取；取不到时（powerd、coreaudiod 这类系统
守护进程）退回 `proc_pidpath` 读可执行文件路径的末段。

```sh
open -a "Deep Sleep" --args --blockers
```

### 谁改了电源设置

每 6 秒对 `pmset -g` 做一次快照比对，记录变化的键、旧值、新值和时间。

**能确定的**：改了什么、从什么变成什么、什么时候，以及**是不是 Deep Sleep 自己改的**
（我们跟踪自己的写入，所以能明确排除自己）。

**不能确定的**：是哪个进程写进去的。macOS 没有公开 API 给出这个信息，
所以这里不猜一个进程名出来，只给事实。
（`pmset -g log` 只有睡眠/唤醒事件，不含设置变更记录，对这个问题没有帮助，已实测。）

```sh
open -a "Deep Sleep" --args --changes
```

### 谁在跟 Deep Sleep 抢控制权

有一类程序**既不持有断言、也不阻止自己睡眠**，而是直接去改系统电源设置 ——
它们不会出现在断言列表里，也不会在系统日志里留名。

实测抓到过一个真实例子：**AlDente**（`com.apphousekitchen.aldente-pro` 1.39.4）
自带「完全禁用睡眠」功能，其二进制里直接含 `completelyDisableSleep`、
`isSleepDisabled`、`Failed to execute pmset command:` 等字符串，并且直接调用 `pmset`。
它和 Deep Sleep 会互相覆盖同一批设置 —— 这类冲突是真实存在的，不是理论上的。

```sh
open -a "Deep Sleep" --args --rivals
```

检测方式：扫描当前运行的非 Apple 应用，在可执行文件里搜索 `disablesleep` /
`SleepDisabled` 字符串常量，结果按包路径缓存（同一个二进制内容不会变）。
读不到文件一律当作「不是」—— 这个列表宁可漏报也不要误报，
一个总在冤枉别的程序的警示等于没有警示。

---

## 更新

两条互相独立的更新路径。

### 应用自己

启动 15 秒后检查 GitHub Release 的 `latest`，下载资产里固定名为 `DeepSleep.zip` 的包。

**只有在版本号严格更高时才更新。** 判断用分段数字比较而非字符串 ——
`"1.10.0" < "1.9.0"` 在字符串比较下是 true，方向一错就是「永远在更新」。
版本号解析失败一律按「没有更新」处理，绝不按「有更新」处理：
宁可漏一次，也不能陷入每回都重装下载的循环。

安装前的校验，任何一步不过就放弃：

| 检查 | 排除的情况 |
| --- | --- |
| zip 能解开 | 中断的下载 |
| 里面的 `.app` 的 bundle id 是 `com.skyc8266.deepsleep` | 拿错了东西 |
| 版本号与 Release 声称的一致 | 版本错配 |
| 通过 `codesign --verify` | 包结构损坏 |
| 若 Release 附了 `DeepSleep.zip.sha256`，比对摘要 | 内容被改动 |

替换由**临时目录里的独立脚本**完成 —— 因为 `.app` 正是要被替换的对象，脚本不能住在里面。
脚本先等本进程退出（最多 30 秒），再「挪走旧的 → 放入新的」，任一步失败都回滚，
并且**不用 `rm -rf` 去清目标路径**：那样一旦「挪走旧的」这步失败，
会把用户的应用直接删掉且再也回不来。

脚本可以用 `--update-script` 打印出来人工审查。这个 dry-run 出口不是装饰 ——
它正是在开发期抓出上面那个回滚缺陷的方式。

### 特权助手

助手二进制装在 `/Library/PrivilegedHelperTools/`，可能落后于应用内置的版本。
因为助手本来就是 root 常驻，可以**自己替换自己**（`updateSelf` 命令），
所以这种更新不需要再输一次管理员密码。

版本判据是一个整数构建号 `HelperConstants.helperBuild`，
**改 `DeepSleepHelper/` 下的代码就要把它 +1**。判据是「已安装 < 内置」
而不是「两者不相等」—— 后者在应用比助手旧时会反复降级再升级。
此外每次运行最多尝试一次，且更新后必须重新探测到新构建号才算成功。

`updateSelf` 的校验（这是全项目权限最高的一条路径，它能把一个 root 二进制
写进 `/Library`）：

1. 来源必须是 `Deep Sleep.app` 内部的助手路径（固定相对路径）
2. 那个 `.app` 的 `CFBundleIdentifier` 必须是 `com.skyc8266.deepsleep`
3. 文件的 SHA-256 必须与调用方给的一致
4. 新构建号必须**严格大于**当前值 —— 不降级、不同版本重装

> 旧版助手不认识 `updateSelf`，收到它会返回解码错误而**不是崩溃**（已实测）。
> 这种情况被识别为「需要重新授权安装一次」，而不是反复重试。

---

## 项目结构

```
DeepSleep/
├── project.yml                     XcodeGen 工程定义
├── Shared/                         两个 target 共用的代码
│   ├── HelperProtocol.swift        命令 / 响应 / 常量定义
│   ├── UnixSocket.swift            UNIX socket 封装（长度前缀分帧）
│   ├── PMSetOutput.swift           `pmset -g` 解析（app 与助手共用一份）
│   └── Version.swift               版本号解析与比较（自动更新的判断依据）
├── DeepSleep/                      主应用
│   ├── DeepSleepApp.swift          App 入口（主窗口场景）
│   ├── AppDelegate.swift           生命周期 + 命令行接口 + 窗口自检
│   ├── Windows/
│   │   ├── MenuBarController.swift 菜单栏图标：左键打开 / 右键设置
│   │   └── WindowCoordinator.swift 主窗口显示与 Dock 图标策略
│   ├── Core/
│   │   ├── AssertionKind.swift     断言类型定义（能力清单）
│   │   ├── SleepController.swift   核心状态机：意图合并 → 实际持有
│   │   ├── PowerWatcher.swift      电源事件监听（睡前拦截 + 唤醒对账）
│   │   ├── PowerActivityMonitor.swift  外部活动：谁在阻止休眠 / 谁改了设置
│   │   ├── UpdateManager.swift     应用自更新：检查、校验、替换
│   │   ├── HelperVersionManager.swift  助手版本检测与自我更新
│   │   ├── AutomationRule.swift    自动化规则模型
│   │   └── AutomationEngine.swift  规则求值引擎
│   ├── Privileged/
│   │   ├── HelperClient.swift      socket 客户端
│   │   └── HelperInstaller.swift   一次性安装 / 卸载
│   ├── Auth/BiometricAuth.swift    Touch ID 授权封装
│   ├── Views/                      SwiftUI 界面
│   └── Resources/
│       ├── Info.plist
│       ├── install-helper.sh       以 root 运行的安装脚本
│       └── uninstall-helper.sh     以 root 运行的卸载脚本
└── DeepSleepHelper/
    ├── main.swift                  特权助手守护进程
    └── SelfUpdate.swift            助手替换自己（权限最高的一条路径）
```

把两个以 root 身份运行的 shell 脚本单独放在 `Resources/` 而不是内联进 Swift 字符串，
是为了让它们可以被 `sh -n` 静态检查和 dry-run 验证。

`scripts/` 下是配套工具：`make-icon.py` 生成应用图标，
`helper-probe.py` 直接与特权助手对话（排查与端到端测试），
`try-release-assertion.swift` 验证跨进程断言释放会被拒绝，
`dump-windows.swift` 从进程外部查看 Deep Sleep 的窗口是否真的出现，
`test-pmset-parse.swift` / `test-version-compare.swift` / `test-selfupdate.swift`
是三个回归测试（都直接编译真实源码，而不是抄一份逻辑来测），
`probe-unknown-command.py` 验证助手对不认识的命令的反应，
`build-release.sh` 打包 GitHub Release 需要的 `DeepSleep.zip` 与摘要文件。

---

## 设计要点

**意图与状态分离。** 用户手动开的保持项和自动化规则推导出的保持项是两个独立集合，
控制器取并集后再与「实际持有」求差，只对差异部分申请/释放。
这避免了「关掉规则时误关手动开关」这类问题，也保证退出时能干净释放。

**assertion 名必须是 ASCII。** IOKit 的非 ASCII assertion 名在
`pmset -g assertions` 里会显示为空，排查时无法辨认来源。因此统一使用
`Deep Sleep - prevent idle system sleep` 这类英文名。

**先释放后申请。** 睡眠请求会被自身的 assertion 挡住，因此「立即睡眠」和
倒计时到点都会先释放本进程持有的全部 assertion。

---

## 已验证 / 未验证

已实测（macOS 27.2 / Xcode 27.0 / M2 MacBook Pro）：

- Debug 与 Release 均可构建，产物结构、Bundle ID、最低系统版本正确
- 应用启动后真实创建系统级 assertion，`pmset -g assertions` 可观察到
- 系统确认 Deep Sleep 的断言计入阻止睡眠的贡献者：
  `sleep 1 (sleep prevented by UURemote, powerd, Deep Sleep)`
- 跨进程释放断言被内核拒绝（`kIOReturnNotPermitted`），断言归创建者所有
- 电源事件监听注册成功（`powerWatcher=on`），睡前拦截与唤醒对账通道可用
- 3 秒周期对账真实运行：`--wait 10 --status` 返回 `audits=3`
- 正常退出（AppleEvent quit）会走清理路径并释放全部 assertion
- `BiometricAuth` 环境下 `deviceOwnerAuthentication` 可用，`biometryType = touchID`
- 安装/卸载脚本通过 `sh -n` 语法检查、变量缺失保护、源文件缺失保护
- 脚本 dry-run：正确生成 LaunchDaemon plist（`plutil -lint` 通过）、
  拷贝出的助手校验和与源文件一致、socket 就绪检测与超时路径均正确
- 助手非 root 运行会被守卫拒绝（退出码 1）
- 菜单栏图标创建成功，左键 / 右键 / Control+左键三种点击判定均正确
- 右键菜单构建正确：持有两项保持时显示 `☑ 阻止空闲睡眠`、`☑ 保持屏幕常亮`，
  未持有的保持 `☐`
- 关掉主窗口后激活策略自动切到 `accessory`（Dock 图标消失），进程继续运行
- 再次打开后窗口恢复、激活策略切回 `regular`
- `pmset -g` 解析回归测试全部通过；真实系统读数 `SleepDisabled = 1`（修复前读成 `nil`）
- 外部改动检测端到端验证：运行中用助手 socket 把 `ttyskeepawake` 从 1 改成 0，
  6 秒内被识别并记为「外部改动」，`1 → 0` 与来源都正确
- `--blockers` 正确列出微信、UU远程、coreaudiod、powerd 等进程，并标出 Deep Sleep 自己
- 版本比较回归测试通过，含 `1.10.0 > 1.9.0`（字符串比较会判反）、
  相等不更新、解析失败不更新这三类防循环用例
- 助手自我更新的四条校验逐条验证：非法来源路径、bundle id 不匹配、
  摘要不符、构建号不大于当前（不降级、不同版本重装）全部被拒
- 旧版助手收到它不认识的 `updateSelf` 会返回解码错误，进程**继续存活**，
  没有崩溃重启
- 更新器脚本 dry-run 与替换演练：正常替换成功、备份与工作目录清理干净；
  新版本放入失败时**完整回滚**，旧应用仍在
- `--rivals` 正确识别出 AlDente（`com.apphousekitchen.aldente-pro`）

未实测：

- 助手的**真实安装**与提权操作（需要一次管理员授权；`sudo` 无法在无交互环境下完成）
- `disablesleep` 被外部改回后的**自动恢复**（依赖助手，助手未装则无法写入）
- 睡前拦截的实际效果（需要真的触发一次睡眠等待，且同样依赖助手持有的断言）
- Touch ID 弹窗的实际交互（需要人工按指纹确认）
- 用真实鼠标 / 触控板点击菜单栏图标。自检覆盖的是点击判定逻辑与菜单内容，
  系统级的鼠标事件合成需要「辅助功能」权限，未做
- 走完一次**真实的**应用自动更新（需要先发一个 GitHub Release；
  下载、校验、替换三段已分别验证，缺的是串起来的端到端）
- 助手的**真实自我更新**（当前装着的是旧版助手，它不认识该命令，
  需要先重装一次拿到支持自我更新的版本）

---

## 许可证

MIT License，见 [LICENSE](LICENSE)。Copyright © 2026 Skyc8266。

详见 `docs/notes.md`。

---

## 已知限制

- 合盖状态下能否被定时唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被唤醒
- 取消唤醒会清除所有由 `pmset` 排定的唤醒任务，包括其他程序排定的
- 分发版本需要自己的开发者证书；ad-hoc 签名仅适合本机使用
