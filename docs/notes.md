# 开发记录

## 环境

| 项目 | 值 |
| --- | --- |
| 测试机 | MacBook Pro (Mac14,7, Apple M2, 8 GB) |
| 系统 | macOS 27.2 (BuildVersion 26B5091g) |
| Xcode | 27.0 (27A266a)，macOS 27.0 SDK |
| 部署目标 | macOS 26.0 |
| 签名 | ad-hoc（`CODE_SIGN_IDENTITY = "-"`） |
| 工程生成 | XcodeGen |

## 已实测的项目与证据

### 1. 构建

- `xcodebuild -configuration Debug`：BUILD SUCCEEDED
- `xcodebuild -configuration Release`：BUILD SUCCEEDED
- 产物内容：

  ```
  Deep Sleep.app/Contents/MacOS/Deep Sleep
  Deep Sleep.app/Contents/Library/PrivilegedHelperTools/deepsleep-helper
  Deep Sleep.app/Contents/Resources/{AppIcon.icns,Assets.car,install-helper.sh,uninstall-helper.sh}
  ```

- `CFBundleIdentifier = com.skyc8266.deepsleep`、`LSMinimumSystemVersion = 26.0`

### 2. 应用真实创建系统级 assertion

启动 `--hold idle-system,display` 后 `pmset -g assertions`：

```
pid 55562(Deep Sleep): [0x000145180001896d] 00:00:01 PreventUserIdleSystemSleep
     named: "Deep Sleep - prevent idle system sleep"
pid 55562(Deep Sleep): [0x000145180005896e] 00:00:01 PreventUserIdleDisplaySleep
     named: "Deep Sleep - prevent display sleep"
```

系统级计数 `PreventUserIdleDisplaySleep = 1`、`PreventUserIdleSystemSleep = 1`。

### 3. 退出清理路径

通过 AppleEvent `quit` 正常退出后，应用日志输出
`Deep Sleep 退出，已释放全部 assertion`，且 `pmset -g assertions` 中
Deep Sleep 的 assertion 全部消失。说明 `applicationShouldTerminate` → `shutdown()` 生效。

### 4. 生物识别可用性

`deviceOwnerAuthentication` = true，`biometryType` = 1 (touchID)。
应用内的 `BiometricAuth.authenticate` 会走 Touch ID，失败时回退登录密码。

### 5. 安装 / 卸载脚本

- `sh -n` 语法检查通过
- 缺少必需环境变量时以非 0 退出，并指出缺少哪个变量
- 源文件不存在时以退出码 2 退出
- 沙盒 dry-run（仅用替身替换 `chown` 与 launchd 调用，其余逻辑原样）：
  - socket 就绪时输出 `helper-ready` 并以 0 退出
  - socket 不出现时输出 `helper-socket-missing` 并以 1 退出
  - 生成的 LaunchDaemon plist 通过 `plutil -lint`
  - `Label` / `ProgramArguments[0]` / `KeepAlive` 字段取值正确
  - 拷贝出的助手二进制 sha256 与源文件一致

### 6. 助手守卫

直接以非 root 运行 `deepsleep-helper`：输出「必须以 root 身份运行」并以 1 退出。

### 7. 未启用完全控制时的行为

`--hold system` 在未安装助手时被正确拒绝，`--status` 返回 `hold=none count=0 fullControl=off`。

## 未实测的项目与原因

### 助手的真实安装与提权操作

**原因**：安装需要一次管理员授权。当前执行环境无法交互式输入管理员密码，
`sudo` 也不可用。

**影响范围**：以下路径尚未在真机上跑通，仅有静态与沙盒级验证：

- `osascript ... with administrator privileges` 的实际弹窗与授权结果
- `launchctl bootstrap system` 在真实 `/Library/LaunchDaemons` 下的加载
- 助手进程的 socket 服务、`getpeereid` 校验、`PreventSystemSleep` 断言创建
- `pmset -a disablesleep 1` 的实际写入与回退
- `pmset schedule wake` 的实际排定

**验证方式**：在应用内点击「完全控制 → 启用完全控制」，输入一次管理员密码
（或按指纹），然后：

```sh
pmset -g assertions | grep "Deep Sleep"     # 应出现 PreventSystemSleep
pmset -g | grep SleepDisabled               # 开启完全禁止睡眠后应为 1
sudo launchctl print system/com.skyc8266.deepsleep.helper
tail -f /var/log/com.skyc8266.deepsleep.helper.log
```

### Touch ID 弹窗的实际交互

**原因**：需要人工按指纹，无法脚本化。

**已验证的替代证据**：`LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)`
在本机返回 true 且 `biometryType == .touchID`，即授权弹窗具备弹出条件。

### 界面外观

**原因**：`screencapture` 需要「屏幕录制」权限，`System Events` 需要
「辅助功能」权限，两者在当前环境均未授予，因此无法自动截图或驱动 UI。

**已验证的替代证据**：`CGWindowListCopyWindowInfo` 确认主窗口已创建，
尺寸 1000×700（与 `defaultSize` 一致），layer 0（普通窗口）。

## 设计决策记录

### 为什么需要「期望态 + 对账」而不是「设置了就不管」

实际威胁模型里有一个容易被忽略的场景：**外部程序（或系统本身）会改掉我们依赖的状态**。
原本的实现每 10 秒读一次 `pmset -g`，但那只是「更新界面显示」——
如果别的程序把 `disablesleep` 改回 0，Deep Sleep 只会把开关显示成关闭，不会纠回去。

用户的语义是明确的：「我打开了阻止睡眠，就是不希望它睡」。所以必须主动纠偏。

现在的三层防护：

| 层 | 机制 | 覆盖的场景 |
| --- | --- | --- |
| 1 | 3 秒周期对账 | 空闲睡眠（idle timer 以分钟计，3 秒足够抢在到点前恢复） |
| 2 | `PreventSystemSleep` 断言加固 | 合盖 / 菜单睡眠等**主动**请求（`disablesleep` 只在 powerd 评估空闲睡眠时起作用） |
| 3 | 睡前拦截（`IORegisterForSystemPower` + `IOAllowPowerChange`） | 已经在睡眠等待路径上的最后机会 |

第 3 层的安全边界写在 `PowerWatcher.swift` 里：**用户没有要求阻止睡眠时必须立刻放行**，
且始终有 5 秒兜底超时，绝不允许出现「永远不放行」把系统吊死的状态。

对账与 `reconcile()` 的分工：

- `reconcile()` —— 让实际持有对齐用户意图（内部一致性）
- `auditExternalState()` —— 让系统状态对齐我们的期望（对抗外部干扰）

### 断言不会被外部进程取消（实测）

`Assertion` 归创建它的进程所有，内核拒绝跨进程释放：

```
本进程 pid=57829 尝试释放 assertion id=35300（由另一个进程创建）
IOPMAssertionRelease 返回: kIOReturnNotPermitted（被拒绝）
```

释放尝试后系统侧断言完好。系统确认把它算作阻止睡眠的贡献者：

```
sleep        1 (sleep prevented by UURemote, powerd, Deep Sleep)
displaysleep 0 (display sleep prevented by Deep Sleep)
```

因此第 1、2 档保持状态不存在「被别人取消」的路径，唯一失效途径是本进程死亡。
真正需要对抗外部改动的是 `pmset` 那一类持久设置。

### 系统有权无视断言（Apple 官方文档）

`kIOPMAssertionTypePreventSystemSleep` 的 Discussion 原文：

> Assertions are just suggestions to the OS, and the OS can only honor them to
> the best of its ability. In the case of low power or a thermal emergency,
> the system may sleep anyway despite the assertion.

低电量与过热保护时断言会被忽略，这是任何软件都无法绕过的边界。

### IOKit 电源消息常量必须手动复现

`kIOMessageSystemWillSleep` 等在 `IOMessage.h` 里由 C 宏 `iokit_common_msg()` 定义，
Swift 无法导入宏。`PowerWatcher.swift` 里按同样的位运算规则复现，
message 参数取自 SDK 头文件，并已用 C 程序编译比对确认：

```
kIOMessageCanSystemSleep      = 0xE0000270
kIOMessageSystemWillSleep     = 0xE0000280
kIOMessageSystemHasPoweredOn  = 0xE0000300
```

### 对账频率的可验证性

「对账在跑」不能只靠读代码相信。`--status` 会输出 `audits=<n>` 计数：

```
$ "Deep Sleep" --hold idle-system --wait 10 --status
hold=idle-system count=1 fullControl=off ... powerWatcher=on audits=3 lastRestore=none
```

10 秒得到 `audits=3`，与 3 秒周期一致。

### 为什么不用 SMJobBless

SMJobBless 要求在 Apple Developer Program 中注册并与 Apple 建立信任关系的
代码签名证书，本地开发 / ad-hoc 签名场景无法使用。改用
「一次性授权写入 + launchd 常驻 + socket 通信」的自管方案，
好处是安装与卸载都完全可控、可回退，不依赖开发者账号。

### 为什么 assertion 名必须用 ASCII

首版使用了 `"Deep Sleep: 保持屏幕常亮"` 这样的中文名，
实测在 `pmset -g assertions` 中显示为空字符串：

```
pid 55022(Deep Sleep): [0x...] 00:00:03 PreventUserIdleSystemSleep named: ""
```

这会让排查「谁在阻止睡眠」时无法辨认来源。改为
`Deep Sleep - prevent idle system sleep` 后可正常显示。

### 为什么把安装脚本抽成独立文件

`install-helper.sh` / `uninstall-helper.sh` 会以 root 身份运行并改动 `/Library`，
是全项目风险最高的动作。抽成独立 `.sh` 文件后可以：

- 用 `sh -n` 做语法检查
- 用替身替换 `chown` / `launchctl` 后做 sandbox dry-run
- 直接审阅 diff，而不是读 Swift 字符串插值

### 命令行接口的已知限制

`--hold` / `--release` 只作用于启动它的实例。macOS 单实例机制下，
对已运行实例再次传参不会生效。若要做脚本化的持续控制，
应使用自动化规则，或在未运行实例时启动。

### 为什么菜单栏不用 MenuBarExtra

SwiftUI 的 `MenuBarExtra` 只提供「点击 → 弹出自己的面板」这一种交互，
**拿不到点击事件本身**，因此无法区分左右键。需求是左键打开主界面、右键做设置，
只能改用 AppKit 的 `NSStatusItem`：

```swift
button.sendAction(on: [.leftMouseUp, .rightMouseUp])
```

默认只有左键抬起会发出动作，右键会被直接丢掉 —— 不显式声明两种事件就收不到右键。

菜单弹出用 `menu.popUp(positioning:at:in:)` 而不是

```swift
statusItem.menu = menu          // 反例
statusItem.button?.performClick(nil)
statusItem.menu = nil
```

后者会把菜单挂到状态项上，收起时必须记得摘掉，否则下一次左键也会弹菜单。
`popUp` 没有这个状态要维护。

### 直接运行可执行文件时 SwiftUI 不会创建窗口

自检一开始报告「3 秒内没等到主窗口」，打印 `NSApp.windows` 却是 7 个窗口，
且全部 `titled=false` —— 主窗口根本没被创建。

原因不是代码有问题，而是**启动方式**：

```sh
# 不会创建主窗口：进程直接由终端拉起，没有经过 LaunchServices
"Deep Sleep.app/Contents/MacOS/Deep Sleep" --window-self-test

# 正常创建，1000x700
open -a "Deep Sleep.app"
```

直接执行 bundle 内的可执行文件时 SwiftUI 不会自动开窗。用户实际都是走
Finder / Spotlight / `open` 启动，所以这不影响使用；但**自动化测试必须用 `open` 启动**，
否则测的根本不是用户会走的路径。

用 `open` 又会丢掉 stdout，所以自检读取输出走这两个选项：

```sh
open -a "Deep Sleep.app" --stdout out.log --stderr err.log --args --window-self-test
```

### 为什么把点击判定和菜单构建拆出来

这两件事原本都埋在 `@objc` 的点击回调里，自动化测试碰不到：

- `isSecondaryClick(eventType:modifiers:)` 抽成静态纯函数，自检可以直接传入
  `.leftMouseUp` / `.rightMouseUp` / `[.control]` 验证判定，不必合成系统事件。
- `makeMenu()` 从 `presentMenu()` 抽出来，自检可以只构建不弹出。菜单弹出是**模态的**，
  自动化测试一旦触发就会卡死在那里，所以只能验证内容而不能验证弹出。

`NSStatusBar` 也没有查询接口，为了确认菜单栏图标真的建起来了，
控制器留了一个弱引用 `MenuBarController.current` 供自检核对 ——
否则只能「读代码觉得应该建了」。

### 为什么 Dock 图标的判断条件要处理三个例外

隐藏 Dock 图标的触发条件是「所有窗口都关了」，判据用 `NSApp.windows`，
但要处理三个例外：

- **popover 与菜单都是 `NSPanel`**，它们开合不代表用户关掉了应用界面，
  必须先排除，否则右键菜单一收起就可能误判。
- **最小化的窗口算「有窗口」**。若把它算作没有窗口而隐藏 Dock 图标，
  用户就失去把那个窗口找回来的唯一入口（Dock 上的缩略图）。
- 窗口关闭通知发出时，该窗口**还在 `NSApp.windows` 里**且 `isVisible` 仍为 true，
  立即判断会把最后一个窗口误算成可见窗口，Dock 图标永远不隐藏。
  所以要等一轮事件处理之后再判断。

### 为什么状态栏图标固定不随状态变化

菜单栏图标保持固定的月亮（`moon.zzz.fill`）。状态变化改用 menu 首行的文字摘要
（「正在保持清醒 · 2 项」/「允许正常睡眠」/「已完全禁止睡眠（含合盖）」）表达。
图标频繁变形在菜单栏里反而更难一眼认出是哪个应用。

## 后续可做

- 分发用的开发者签名与公证流程
- 跨零点时间段规则的边界测试（已有实现，缺自动化测试）
- 规则与 assertion 状态的持久化恢复（当前每次启动从空白开始）
- 菜单栏图标的可选样式（有人偏好用颜色区分「正在保持清醒」）
