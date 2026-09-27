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
- 菜单栏常驻面板
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
| `--status` | 输出当前状态，格式 `hold=... count=... fullControl=... sleepDisabled=...` |

> 注意：`--hold` / `--release` 作用于启动它的那个实例。macOS 单实例机制下，
> 对已运行的实例再次传参不会生效 —— 需要脚本化持续控制时，请用自动化规则。

---

## 项目结构

```
DeepSleep/
├── project.yml                     XcodeGen 工程定义
├── Shared/                         两个 target 共用的代码
│   ├── HelperProtocol.swift        命令 / 响应 / 常量定义
│   └── UnixSocket.swift            UNIX socket 封装（长度前缀分帧）
├── DeepSleep/                      主应用
│   ├── DeepSleepApp.swift          App 入口（窗口 + 菜单栏）
│   ├── AppDelegate.swift           生命周期清理 + 命令行接口
│   ├── Core/
│   │   ├── AssertionKind.swift     断言类型定义（能力清单）
│   │   ├── SleepController.swift   核心状态机：意图合并 → 实际持有
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
- 正常退出（AppleEvent quit）会走清理路径并释放全部 assertion
- `BiometricAuth` 环境下 `deviceOwnerAuthentication` 可用，`biometryType = touchID`
- 安装/卸载脚本通过 `sh -n` 语法检查、变量缺失保护、源文件缺失保护
- 脚本 dry-run：正确生成 LaunchDaemon plist（`plutil -lint` 通过）、
  拷贝出的助手校验和与源文件一致、socket 就绪检测与超时路径均正确
- 助手非 root 运行会被守卫拒绝（退出码 1）

未实测：

- 助手的**真实安装**与提权操作（需要一次管理员授权；`sudo` 无法在无交互环境下完成）
- Touch ID 弹窗的实际交互（需要人工按指纹确认）

详见 `docs/notes.md`。

---

## 已知限制

- 合盖状态下能否被定时唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被唤醒
- 取消唤醒会清除所有由 `pmset` 排定的唤醒任务，包括其他程序排定的
- 分发版本需要自己的开发者证书；ad-hoc 签名仅适合本机使用
