# Deep Sleep

原生 Swift 编写的 macOS 睡眠管理器。目标是把 MacBook 的睡眠行为完全交给用户掌控：
既能精细地保持清醒，也能彻底禁止休眠、定时睡眠、计划唤醒。

- **Bundle ID**：`com.skyc8266.deepsleep`
- **应用名**：Deep Sleep
- **最低系统**：macOS 26.0
- **语言 / 框架**：Swift 5、SwiftUI + AppKit、IOKit、LocalAuthentication

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

## 项目结构

```
DeepSleep/
├── project.yml                     XcodeGen 工程定义
├── Shared/                         两个 target 共用的代码
│   ├── HelperProtocol.swift        命令 / 响应 / 常量定义
│   └── UnixSocket.swift            UNIX socket 封装（长度前缀分帧）
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
    └── main.swift                  特权助手守护进程
```

把两个以 root 身份运行的 shell 脚本单独放在 `Resources/` 而不是内联进 Swift 字符串，
是为了让它们可以被 `sh -n` 静态检查和 dry-run 验证。

`scripts/` 下是配套工具：`make-icon.py` 生成应用图标，
`helper-probe.py` 直接与特权助手对话（排查与端到端测试），
`try-release-assertion.swift` 验证跨进程断言释放会被拒绝，
`dump-windows.swift` 从进程外部查看 Deep Sleep 的窗口是否真的出现。

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

未实测：

- 助手的**真实安装**与提权操作（需要一次管理员授权；`sudo` 无法在无交互环境下完成）
- `disablesleep` 被外部改回后的**自动恢复**（依赖助手，助手未装则无法写入）
- 睡前拦截的实际效果（需要真的触发一次睡眠等待，且同样依赖助手持有的断言）
- Touch ID 弹窗的实际交互（需要人工按指纹确认）
- 用真实鼠标 / 触控板点击菜单栏图标。自检覆盖的是点击判定逻辑与菜单内容，
  系统级的鼠标事件合成需要「辅助功能」权限，未做

---

## 许可证

MIT License，见 [LICENSE](LICENSE)。Copyright © 2026 Skyc8266。

详见 `docs/notes.md`。

---

## 已知限制

- 合盖状态下能否被定时唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被唤醒
- 取消唤醒会清除所有由 `pmset` 排定的唤醒任务，包括其他程序排定的
- 分发版本需要自己的开发者证书；ad-hoc 签名仅适合本机使用
