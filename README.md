# Deep Sleep

原生 Swift 写的 macOS 睡眠管理器。用来保持清醒、彻底禁止休眠，也能定时睡眠与计划唤醒。

- **Bundle ID**：`com.skyc8266.deepsleep`
- **应用名**：Deep Sleep
- **最低系统**：macOS 26.0
- **语言 / 框架**：Swift 5、SwiftUI + AppKit、IOKit、LocalAuthentication
- **当前版本**：1.3.1

## 安装

从 [Releases](https://github.com/Mofan2020/DeepSleep/releases) 下载 `DeepSleep.zip`，
解压后把 `Deep Sleep.app` 放进 `/Applications`。

应用是 ad-hoc 签名，首次打开若被系统拦下，到「系统设置 → 隐私与安全性」里点「仍要打开」。
想自己构建见下文。

## 功能

### 保持清醒

| 能力 | 说明 | 需要授权 |
| --- | --- | --- |
| 阻止空闲睡眠 | 等同 `caffeinate -i`，系统不再因无操作而睡眠 | 否 |
| 保持屏幕常亮 | 显示器不因空闲关闭 | 否 |
| 阻止系统睡眠 | 合盖也不睡 | 是（完全控制） |

### 完全控制

一次管理员授权装上特权助手，之后这些能力长期可用，不再要求管理员密码：

- 阻止系统睡眠（含合盖）：由助手持有 `PreventSystemSleep` 断言
- 完全禁止系统睡眠：写入 `pmset -a disablesleep 1`，重启后依然生效
- 电源设置读写：`sleep`、`displaysleep`、`disksleep`、`hibernatemode`、`powernap`、
  `womp`、`ttyskeepawake`、`lowpowermode`、`autorestart`、`lidwake` 等
- 计划唤醒：`pmset schedule wake`，由系统电源服务执行

「停用并卸载」会把 `/Library` 下的文件与 launchd 任务全部移除，系统回到安装前的状态，
也可以手动执行 `DeepSleep/Resources/uninstall-helper.sh`。

### 自动化规则

规则由「触发条件」和「要保持的状态」组成，引擎每 5 秒评估一次：

- 时间段：工作日 09:00–18:00 保持清醒，支持跨零点区间
- 电源状态：接入电源时 / 使用电池时
- 应用运行中：指定的应用在前台运行时

规则只表达意图，申请与释放由控制器统一处理，所以规则和手动开关不会互相打架。

### 交给系统自动化

| 通道 | 怎么用 |
| --- | --- |
| Siri | 说「用 Deep Sleep 保持清醒」「用 Deep Sleep 查询睡眠状态」，完整短语用 `--automation` 查看 |
| 快捷指令 | 「快捷指令」App 里直接有 Deep Sleep 的动作，可以拼进任何自动化流程 |
| 自动操作 / AppleScript / shell | 调用 `deepsleep://` URL，见下文 |
| 聚焦 / 控制中心 | 上面的动作也会出现在这里 |

### 快速退出

指定一个全局快捷键（默认 **⌥⇧⌘H**，可在界面里重新录制），按下就把选定的应用连同全部子进程一起结束。

- 这是强制结束，不等待保存，也不给应用收尾的机会
- 系统进程有硬编码名单保护（Finder、Dock、WindowServer、powerd、tccd 等，
  完整清单见 [docs/architecture.md](docs/architecture.md) 第六节）。命中的进程连同整棵子树一起跳过，没有开关能绕过
- 需要 root 的进程交给特权助手；助手不可达时退回本进程权限，并在结果里说明
- 名单里的应用没在运行时，结果会写「未在运行」
- 「演练一次」只列出会结束哪些进程，不动手

### 其他

- 倒计时睡眠
- 菜单栏常驻：左键打开主界面，右键弹出快速设置，Control + 左键等同右键
- 关掉所有窗口后隐藏 Dock 图标，应用继续在菜单栏后台运行
- 运行日志页，按条数与天数自动裁剪
- 外部活动：谁在阻止休眠、谁改了电源设置
- 应用与特权助手都能自我更新

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
| `--helper-version` | 显示特权助手的版本状态（与内置那份的摘要比对结果） |
| `--helper-update` | 手动检查并按内置的那一份更新助手（与界面「立即检查并更新」同一条路径） |
| `--update-check` | 立即检查应用更新并输出结果 |
| `--update-script` | 打印将要执行的更新器脚本（只打印，不执行；用于人工审查） |
| `--quick-quit` | 立刻执行一次快速退出（结束选定的应用及其全部子进程） |
| `--dry-run` | 与 `--quick-quit` 配合：只列出会结束哪些进程，不动手 |
| `--automation` | 打印 Siri 短语与 `deepsleep://` 的命令清单 |
| `--hotkey-status` | 打印快速退出快捷键的注册状态（排查「按了没反应」） |

> `--hold` 与 `--release` 作用于启动它的那个实例。macOS 是单实例机制，
> 对已经在运行的实例再传参不会生效。需要脚本持续控制时，请用下面的 URL 或自动化规则。

### `deepsleep://` URL 接口

```sh
open "deepsleep://hold?kind=idle-system,display&minutes=60"
open "deepsleep://release"
open "deepsleep://quick-quit?dry-run=1"
```

URL 每次都会送到正在运行的那个实例，所以比命令行参数更适合重复调用。
AppleScript 用 `open location "deepsleep://release"`，自动操作用「打开 URL」动作。
完整的命令表与参数见 [docs/architecture.md](docs/architecture.md) 的「URL 命令一览」。

## 外部活动

电源控制往往是几个程序在抢，Deep Sleep 只保证自己那一份。

```sh
open -a "Deep Sleep" --args --blockers   # 谁在阻止休眠
open -a "Deep Sleep" --args --changes    # 谁改了电源设置
open -a "Deep Sleep" --args --rivals     # 谁在跟 Deep Sleep 抢
```

`--blockers` 直接向内核取所有电源断言，按进程分组，并标出 Deep Sleep 自己。
`UserIsActive` 这类表示「用户正在操作」的断言不计入。

`--changes` 每 6 秒对 `pmset -g` 做一次快照比对，能给出改了什么、从什么变成什么、
什么时候，以及是不是 Deep Sleep 自己改的。macOS 没有公开 API 能查出是哪个进程写进去的，
所以这里不猜进程名。

`--rivals` 扫描正在运行的非 Apple 应用，在二进制里找 `disablesleep` /
`SleepDisabled` 字符串，用来找出那些直接改系统设置的程序，例如 AlDente。
读不到文件一律当作「不是」，宁可漏报也不误报。

检测到冲突只把事实列出来，不会去关掉别的程序。

## 权限与安全

真正彻底的睡眠控制都需要 root，所以这里用「一次性安装、长期驻留」的助手，避免每次操作都弹密码框：

1. 在「完全控制」页点「启用完全控制」，系统弹出一次管理员授权
   （已录入 Touch ID 的机器可以直接用指纹确认）
2. 授权用于把助手二进制写入 `/Library/PrivilegedHelperTools/`，
   并注册一个 launchd LaunchDaemon 让它常驻
3. 之后的提权操作只需要 Touch ID / 登录密码做本地确认，再经 UNIX socket 交给助手执行

助手侧的防护：

- socket 在 `/var/run/com.skyc8266.deepsleep.sock`，归当前登录用户所有，权限 `0600`
- 每个连接都用 `getpeereid()` 校验对端 uid，非登录用户直接拒绝
- 可写入的 `pmset` 键有白名单，取值必须是纯数字
- 只接受固定的命令枚举，不执行任何外部传入的 shell 字符串
- 必须以 root 运行，否则直接退出

## 更新

两条互不影响的更新路径。

**应用自己。** 启动 15 秒后拉取 Release 列表，取版本号最高的一条（跳过草稿，
保留预发布），下载其中名为 `DeepSleep.zip` 的资产。只有版本号严格更高时才更新，
版本号解析失败按「没有更新」处理。

安装前要过这几道检查，任何一步不过就放弃：

| 检查 | 排除的情况 |
| --- | --- |
| zip 能解开 | 中断的下载 |
| 里面的 `.app` 的 bundle id 是 `com.skyc8266.deepsleep` | 拿错了东西 |
| 版本号与 Release 声称的一致 | 版本错配 |
| 通过 `codesign --verify` | 包结构损坏 |
| Release 附了 `DeepSleep.zip.sha256` 时比对摘要 | 内容被改动 |

替换由临时目录里的独立脚本完成，脚本先等应用退出，再「挪走旧的、放入新的」，
任一步失败都回滚。可以先用 `--update-script` 把脚本打印出来人工审查。

**特权助手。** 助手装在 `/Library/PrivilegedHelperTools/`，可能落后于应用内置的那一份。
它是 root 常驻，能自己替换自己（`updateSelf`），所以更新不需要再授权一次。

- 应用启动后自动检查一次，两份内容不同就地替换；失败时本轮不再试，原因显示在「更新」页
- 也可以在「更新」页点「立即检查并更新」：先检查，有差异会弹框说明并询问，确认后更新
- 判据是两份二进制的内容摘要，不是版本号。只改了应用、没动助手时摘要不变，助手不会白重启一遍
- 旧版助手不认识 `updateSelf`，会返回解码错误而不是崩溃。这种情况需要重新授权安装一次

## 已知限制

- 合盖时能否被定时唤醒取决于机型与电源状态，Apple Silicon 机型合盖时通常不会被唤醒
- 取消唤醒会清掉所有由 `pmset` 排定的唤醒任务，包括别的程序排的
- 分发版本需要自己的开发者证书，ad-hoc 签名只适合本机使用

## 自己构建

需要 Xcode 26 以上（含 macOS 26 SDK）与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen

cd DeepSleep
xcodegen generate                     # 由 project.yml 生成 DeepSleep.xcodeproj

xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Release -derivedDataPath build build

open "build/Build/Products/Release/Deep Sleep.app"
```

构建时会自动把 `deepsleep-helper` 嵌进
`Deep Sleep.app/Contents/Library/PrivilegedHelperTools/`。
`project.yml` 里配置的是 ad-hoc 签名，本机可以直接运行。

## 项目结构

```
DeepSleep/
├── project.yml                     XcodeGen 工程定义
├── Shared/                         两个 target 共用的代码
│   ├── HelperProtocol.swift        命令 / 响应 / 常量定义
│   ├── UnixSocket.swift            UNIX socket 封装（长度前缀分帧）
│   ├── PMSetOutput.swift           `pmset -g` 解析（app 与助手共用一份）
│   ├── Version.swift               版本号解析与比较（自动更新的判断依据）
│   ├── ProcessInventory.swift      进程枚举与进程树（快速退出用）
│   ├── ProcessGuard.swift          强杀保护名单与「该杀谁」的裁决
│   └── TerminationReport.swift     强杀结果的结构与编解码
├── DeepSleep/                      主应用
│   ├── DeepSleepApp.swift          App 入口（主窗口场景）
│   ├── AppDelegate.swift           生命周期 + 命令行接口 + URL 入口
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
│   │   ├── AutomationEngine.swift  规则求值引擎
│   │   ├── QuickQuit.swift         快速退出引擎（目标名单 → 进程树 → 强杀）
│   │   ├── GlobalHotkey.swift      全局快捷键（Carbon，不需要辅助功能权限）
│   │   └── URLCommands.swift       `deepsleep://` 命令表与解析
│   ├── Intents/
│   │   ├── DeepSleepIntents.swift      App Intents（Siri / 快捷指令 / 聚焦）
│   │   └── DeepSleepAppShortcuts.swift App Shortcuts：说出口的短语
│   ├── Privileged/
│   │   ├── HelperClient.swift      socket 客户端
│   │   └── HelperInstaller.swift   一次性安装 / 卸载
│   ├── Auth/BiometricAuth.swift    Touch ID 授权封装
│   ├── Views/                      SwiftUI 界面（含快速退出页 QuickQuitView.swift）
│   └── Resources/
│       ├── Info.plist              （含 `deepsleep://` 的 CFBundleURLTypes）
│       ├── install-helper.sh       以 root 运行的安装脚本
│       └── uninstall-helper.sh     以 root 运行的卸载脚本
└── DeepSleepHelper/
    ├── main.swift                  特权助手守护进程
    └── SelfUpdate.swift            助手替换自己（权限最高的一条路径）
```

`scripts/` 下是配套工具：`build-release.sh` 打包发布用的 zip 与摘要，
`check-docs.py` 检查文档与代码是否一致，`test-check-docs.py` 验证前者真的会拦，
`test-pmset-parse.swift` / `test-version-compare.swift` / `test-selfupdate.swift` /
`test-process-guard.swift` / `test-helper-update.sh` 是回归与端到端测试，
`helper-probe.py` 直接与特权助手对话，`probe-unknown-command.py` 验证助手对未知命令的反应，
`make-icon.py` 生成应用图标。

## 开发文档

改代码之前先读 [docs/](docs/README.md)。那里写的是「为什么长这样」和「改动时要注意什么」，
这两件事代码本身说不清楚。

| 文档 | 内容 |
| --- | --- |
| [docs/README.md](docs/README.md) | 索引、五分钟跑起来、文档保鲜机制、硬约定 |
| [docs/architecture.md](docs/architecture.md) | 架构与运作逻辑：权限模型、三层防护、对账范围、两套更新机制 |
| [docs/maintenance.md](docs/maintenance.md) | 常见改动怎么做、怎么验证、调试工具 |
| [docs/release.md](docs/release.md) | 发布流程与检查清单 |
| [docs/gotchas.md](docs/gotchas.md) | 踩过的坑，想简化某段代码之前先看这里 |
| [docs/notes.md](docs/notes.md) | 开发记录：实测证据、未实测项与原因、设计决策 |

文档与代码的一致性由脚本保证，改完跑一次：

```sh
python3 scripts/check-docs.py
```

它会比对命令行参数表、协议命令表、URL 命令表、Siri 短语、保护名单、版本号与文件引用。

## 许可证

MIT License，见 [LICENSE](LICENSE)。Copyright © 2026 Skyc8266。
