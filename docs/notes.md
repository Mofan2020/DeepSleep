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

### `pmset -g` 的分隔符不统一

解析这份输出最容易踩的坑：分隔符是混用的。

```
System-wide power settings:
 SleepDisabled\t\t1        ← TAB 分隔
Currently in use:
 standby              0    ← 空格对齐
```

只按空格 `split(separator: " ")` 切的话，`SleepDisabled\t\t1` 切不出两段，
会被 `guard parts.count == 2` 整行跳过 —— 而这个键正是「完全禁止睡眠」
是否生效的唯一判据。

后果不是报错，而是**静默的错误判断**：每轮对账都读不到值 → 判定「被外部改回」→
重写一遍（其实本来就是 1）→ 下一轮重复。系统状态全程是对的，
只有日志在每 3 秒刷一条，看起来像有程序在跟我们抢控制权。

修法是先把 TAB 归一成空格再切：

```swift
let normalized = line.replacingOccurrences(of: "\t", with: " ")
let parts = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
```

### 同一段解析为什么必须共享

上面那个 bug 在 app 与特权助手里**各存在一份**：两处独立实现了几乎相同的解析。
于是要修两次，而且极容易只修一处 —— 实际就是这样：应用侧修好后界面立刻正常了，
但助手返回的读数仍然是错的，`--status` 里的 `sleepDisabled` 依旧是 0。

现在统一到 `Shared/PMSetOutput.swift`，两个 target 都引它。
另加 `scripts/test-pmset-parse.swift`：直接编译真实源码做断言，
并且拿真实 `pmset -g` 输出再验一遍。只测手写样本不够 ——
这次的问题恰恰是「样本里没有 TAB」才没被测试发现。

配套防御：助手返回的字典里**缺少** `SleepDisabled` 时不当作「值为 0」，
而是回退本地读取。缺键和值为 0 是两件不同的事，混为一谈会让
「完全禁止睡眠」看起来根本没生效。

### 日志为什么要按两个维度清理

条数与天数缺一不可，因为失效方式不同：

- 只限条数：一台安静运行的机器会把几个月前的日志一直留在内存里。
- 只限天数：一个话痨循环能在几小时内把内存撑爆。

后者不是假设 —— 对账循环每 3 秒跑一次，上面那个解析 bug 就是每 3 秒一条日志。
所以裁剪必须挂在日志产生的路径上（`appendLog` → `trimLog`），而不是靠定时任务。

助手日志是另一套（它要落盘），真正的保证是**磁盘占用上限**：
按天归档 + 单日截尾 + 删除超期归档。原来是超过 1 MB 直接删掉整个文件 ——
那等于在最需要看日志的时候把它清空，现在改为保留尾部并在换行处切割。

### 日志为什么每条都重复两次

排查上面那个 bug 时，助手日志里每条记录都出现两次，很容易误判成
「每个命令被执行了两遍」。实际原因是两条通路写了同一个文件：

- `install-helper.sh` 生成的 LaunchDaemon plist 把 `StandardOutPath` 和
  `StandardErrorPath` 都指向 `LOG_PATH`；
- 代码里的 `logLine` 又显式往 `LOG_PATH` 写了一次。

于是同一行写了两遍。**统计调用次数时要把这个系数算进去** ——
改动前看到的 1406 条 `setSleepDisabled`，实际是 703 次调用，
与「19:15 到 19:50 共 35 分钟 ÷ 3 秒」对得上，这正是读取 bug 的频率指纹。

现在 `logLine` 只写文件，写失败时才退回 stderr。

### 外部改动检测的能力边界

「谁改了 pmset」这件事，能做到什么、做不到什么必须分清：

- **能确定**：改了什么键、从什么值变成什么值、什么时候、**是不是自己改的**。
  「是不是自己」是确定的 —— 我们跟踪自己的每一次写入。
- **不能确定**：是哪个进程写进去的。macOS 没有公开 API 提供这个信息，
  `pmset -g log` 里也只有睡眠/唤醒事件、没有设置变更记录（已实测）。

所以界面上只呈现事实，不列「嫌疑进程」凑数。要真正定位写入者需要
EndpointSecurity 框架，那要求额外的系统授权，不适合这个工具的定位。

### 为什么外部活动扫描是 6 秒

枚举断言（`IOPMCopyAssertionsByProcess`）是纯内核调用，很便宜；
但读一次 `pmset -g` 要 spawn 一个进程。所以扫描挂在 3 秒的对账循环上，
但每两轮才跑一次 —— 断言变化本来也不需要 3 秒级的发现速度。

## 更新机制的设计决策（1.2.0）

### 版本比较为什么不直接用字符串

`"1.10.0" < "1.9.0"` 在字符串比较下是 `true` —— 方向一错，行为就是
「有新版本却认为没有」，或者更糟的「认为有更新但装不上，每次启动重装一遍」。
所以提取成 `Shared/Version.swift` 按数字段逐段比较，并配了回归测试
`scripts/test-version-compare.swift`。

一条同样重要的约定：**解析失败返回 nil，调用方必须当作「无法判断」，
绝不能当作「有更新」**。宁可漏更新一次，也不能陷入循环。

### 「不相等」是个危险的判据

两处版本判断都刻意用**严格**比较，而不是「不相等」：

- 应用更新：`候选 > 当前` 才装
- 助手更新：`已安装 < 内置` 才更

如果用「不相等」，那么当应用版本比已安装的组件旧时（回退安装、或用户手动换了
历史版本），就会反复降级再升级，永远停不下来。相等也不该重装 —— 没有意义，
而且一旦把「相等」也算作需要更新，就成了每次都重装一遍。

### 防循环的三道防线（助手更新）

1. 判据用**内容摘要是否相同**，不是版本号、也不是构建号
2. 每次应用运行**最多尝试一次**自动更新，失败即停手，留给下次启动
3. 更新后必须**重新探测到新摘要**才算成功；确认不到就记失败，不重试

第 3 条容易被省掉，但省掉它的话，更新实际没成功时应用仍会宣称成功，
用户看到「更新了但版本没变」—— 这是最难排查的一类问题。

### 为什么判据是摘要而不是版本号

最初用的是「应用侧维护一个构建序号，改助手代码就 +1」。它有两个问题：

1. **依赖人记得改。** 忘改就是「明明修好了却不更新」；改错（跳号后又引用旧值）
   就是「每次启动都更新一遍」。任何需要人手动维护的判据都有这个毛病。
2. **不精确。** 只改了应用代码、没动助手时，版本号判据会认为助手要更新 ——
   白下载一次、重启一次进程，什么都没变。

改成比对**两份二进制的内容摘要**后两个问题一起消失：不需要维护任何数字，
而且「助手代码有没有变」正是真正要问的问题。它同时天然收敛 ——
替换成功后两边摘要必然一致，下一次不会再触发，不存在来回替换的循环。

### 拉 Release 不能只用 /releases/latest

那个接口**不返回预发布版本**。本仓库的发布习惯是标 Pre-release，
于是第一次实测时得到的是 `HTTP 404` —— 而仓库里明明有 Release。

教训是「404 不等于资源不存在」：接口语义（只返回正式版）与使用场景
（自己的仓库全是预发布）不匹配时，同样会 404。

现在改成拉 `releases?per_page=30`，丢掉草稿、保留预发布，
再用版本号比较自己挑最高的一条。

### 为什么让助手自己替换自己

更新助手需要 root。如果每次都走 `osascript ... with administrator privileges`，
用户每升一版就要输一次管理员密码 —— 而助手本来就以 root 常驻，
让它自己替换自己、再由 launchd 拉起，这一步就能彻底免掉。

代价是 `updateSelf` 成了全项目权限最高的路径（它能把一个 root 二进制写进
`/Library`），因此加了四条硬校验，逐条有测试覆盖：

1. 来源必须是 `Deep Sleep.app` 内部的助手路径（固定相对路径）
2. 那个 `.app` 的 `CFBundleIdentifier` 必须是 `com.skyc8266.deepsleep`
3. SHA-256 必须与调用方给的一致
4. 内容摘要不能与当前这份完全相同

第 1、2 条是为了挡住「本地用户随便指一个二进制让它提权安装」。
socket 只对登录用户开放，但这不代表可以放开任意路径。

### 检测到冲突之后：不解决，只呈现

「外部活动」页会点名其他会改电源设置的程序，但**Deep Sleep 不会去动它们**。
别的软件怎么配置系统是用户自己的事；应用的职责是让用户知道发生了什么，
然后继续保证自己那一份。

对账（`auditExternalState`）纠正的范围也是刻意收窄的：

| 状态 | 是否纠正 | 原因 |
| --- | --- | --- |
| 本地 / 远程断言 | 是 | 阻止睡眠的主力；助手重启会丢，必须重建 |
| `disablesleep` | 是 | 用户开着「完全禁止睡眠」时，被改掉等于功能失效 |
| `sleep` / `displaysleep` 等其他键 | 否 | 用户与系统的正常配置范围，不该被单方面改回去 |

### 应用替换为什么需要一个独立脚本

替换「正在运行的自己」必须先退出自己，而进程一退出就没有代码能继续执行了，
所以这一步只能交给外部进程。脚本写在临时目录而不是 `.app` 内部 ——
`.app` 正是要被替换的对象。

脚本的回滚分支里**刻意没有 `rm -rf "$TARGET"`**。最初的写法是「清干净再放」，
看上去更稳妥，实际是：如果「挪走旧版本」那一步失败（磁盘满、权限不足），
`rm -rf` 会把用户的应用直接删掉，而回滚又因为备份根本不存在而同样失败 ——
应用就彻底没了。是 `--update-script` 这个 dry-run 出口在开发期把它暴露出来的，
所以这个出口保留了下来，不是调试残留。

### 关于「谁改了 disablesleep」的最终结论

排查中一度把它归因成「plist 被外部程序改写」，这个推断是**错的** ——
实测发现 `disablesleep` 变化时 `/Library/Preferences/com.apple.PowerManagement.plist`
的 mtime 可以完全不动，说明它并不存在那个 plist 里。

用「20 分钟每 10 秒采样」的观察脚本才抓到真实变化：

```
[20:00:36] SleepDisabled -> 1
[20:06:09] SleepDisabled -> 0     ← 此刻 plist mtime 仍是 20:00:13
```

对应时刻助手日志里**只有心跳查询**，历史上 `enabled: 0` 出现次数为 **0** ——
确认不是 Deep Sleep 改的。同期系统日志给出线索：

```
2026-09-27 20:05:30 AlDente[1834] ... name=com.apple.iokit.powerdxpc   ← 每 2 秒一次
2026-09-27 20:06:07 powerd: [com.apple.powerd:pmSettings] Energy Saver Prefs have changed
```

而 AlDente 的二进制里直接含 `completelyDisableSleep` / `isSleepDisabled` /
`Failed to execute pmset command:`，并调用 `pmset`。

**结论**：这个冲突是真实的，不是 Deep Sleep 的错觉。但要区分两件事 ——
「日志每 3 秒报一次被改回」是**自身 bug**（TAB 解析，见 README 的修复记录），
而「系统值确实被改过」是**外部干预**（AlDente）。前者已修，
后者靠对账纠正，并且现在能在「外部活动」页与 `--rivals` 看到检测结果。

归因的诚实边界：仍无法指名「是谁写进去的那个值」——
macOS 没有公开 API 提供这个信息。`--rivals` 给的是
「这个程序具备改电源设置的能力，且当前在运行」，而不是「就是它改的」。
这两句话不能混为一谈。

## 自动化接入与快速退出（1.3.0）

### 为什么是 App Intents + URL 两条通道，而不是二选一

| 通道 | 覆盖 | 为什么不能只用它 |
| --- | --- | --- |
| App Intents | Siri、快捷指令、聚焦、控制中心 | 在 macOS 上让 Siri 认得一个应用**只有这一条**原生路径，但它在「自动操作」与脚本里不好用 |
| `deepsleep://` URL | 自动操作、AppleScript `open location`、任何 shell | 语音入口给不了；URL 也拿不到返回值 |

`open -a … --args …` 看起来最省事，但**只在首次启动生效**（macOS 单实例机制），
重复调用会被静默忽略 —— 这一点在 gotchas 第 9 条里已经记过。
URL 每次都能送到正在运行的那个实例，所以「脚本化持续控制」只能靠它。

### 设计决策

1. **保护名单与裁决放 `Shared/`，两侧独立调用。** 同一份实现编译进应用和助手，
   但助手**只接受 pid**，自己重算一遍。理由：「应用算错了」与「有人伪造了一个应用」
   是同一类风险，信任调用方的结论等于把安全边界交给调用方。
2. **直接 `SIGKILL`，不假装优雅。** macOS 上的 Cocoa 应用收到 `SIGTERM` 不会走保存流程
   （系统自己「退出应用程序」用的是 AppleEvent `quit`）。「先 TERM 再 KILL」在这里
   买不到任何东西，只多等几秒 —— 与其做个假的优雅，不如把「强制」写在功能名里。
3. **保护命中要连整棵子树一起跳过。** 名单里的都是会话/系统关键进程，
   「杀掉系统关键进程的子进程」不是任何人想要的语义。
4. **进程数上限两侧共用同一个常量。** 否则会出现「助手因为超限整体拒绝、
   应用却退回本地照样执行」的分裂行为 —— 一个安全限制被另一条路径绕过。
5. **全局快捷键用 Carbon `RegisterEventHotKey`。** 不要「输入监控」权限，
   代价是写法老派（详见 gotchas 20）。
6. **「读不到」要当成一种结果上报。** 普通权限读不到 root 的进程，
   若当成「进程不存在」静默跳过，用户看到的是「按了没反应、也没有原因」（gotchas 19）。
7. **目标按 bundle id 解析出该应用的全部实例**，不是只取一个 pid ——
   多开的应用（比如两个浏览器窗口进程组）要一起结束。
8. **受保护的应用不出现在候选列表里。** 让人先选中、按键时才被拒是更差的体验。
9. **每个 intent 先 `ensureReady()`。** 系统可能先把应用拉起来再执行 intent，
   没有闸门就会读到中间状态，表现是「说了但没生效」。

### 实测记录（含被测试抓出来的 bug）

**回归测试第一次跑就抓出两个真 bug**（这正是「不要只看代码」的价值）：

| bug | 现象 | 根因 |
| --- | --- | --- |
| 受保护进程的**子进程**仍会被杀 | 计划里出现 pid 103（受保护进程 102 的子进程） | 递归函数把「跳过数量」当返回值，但子树里的节点仍被塞进了 `kept`；现在改为命中即调用 `blockSubtree()` 只标记不收集 |
| 快照里找不到的 pid 被**静默忽略** | 结果里既不杀也不解释 | 把「读不到」当成了「已退出」。现在记为拒绝项并说明原因 |

修完后 60 余条断言全绿（含真实进程快照、真实结束一棵进程树并由内核确认已消失）。

**端到端（经特权助手，root）**：探针应用 + 3 个子进程 → 全部结束；
客户端把两个根 pid 一起交给助手时，助手独立重算并**拒绝了那个伪装成 `Finder` 的进程**：

```
[helper] ← terminateProcesses ["pids": "98567,98563"]
[helper] terminate 根进程=2 目标=4 已退出=4 受保护=1 失败=0
```

被拒绝的那份进程**在事后仍然存活**（`ps` 确认）—— 这才叫「保护生效」，
而不是「代码里写了名单」。

**其它实测**：

- `--dry-run` 只列计划：`快速退出演练 —— 已退出 0 个进程，受保护跳过 1 个`，没有进程消失
- `deepsleep://release` / `deepsleep://status` 生效；`deepsleep://hold?kind=everything`
  因 `everything` 不是合法的 `kind` 被拒绝并给出可用值（`all` / `lid` 才是「连合盖也不睡」）
- App Intents 元数据：`Metadata.appintents/extract.actionsdata` 里 8 个 intent、8 组短语
- 快捷键注册：不需要辅助功能权限即可注册成功
- **信息性观测**：非 root 的进程快照 351 项里 uid=0 的有 0 项 —— 这条写进回归测试的输出，
  用来提醒后来的人「应用侧看不到 root 进程」是**预期**，不是 bug

**开发期踩到的坑**（都已写进 [gotchas.md](gotchas.md)）：
同时跑两份实例会导致助手断言被来回抢（第 16 条）；造探针不能用 `cp /bin/sleep`
或脚本（第 17 条）；App Shortcuts 的两条编译期规则与 macOS 上不存在的 API（第 18 条）；
界面文案里的 `\\(` 会原样显示（第 21 条，被用户当场发现后修掉，并加了机器检查）。

### 没动的与原因

- **没做「优雅退出」（先 `SIGTERM` 再 `SIGKILL`）**：见上面第 2 条决策。
- **没做按路径的保护规则**：用户明确「保护规则只用硬名单」。
- **保护名单不给用户编辑**：这不是偏好设置，而是安全边界 ——
  配置错误等于把系统赔进去。要改就改代码，并同步文档与测试。
- **没做「冲突解决」（发现别的程序在抢电源设置就去关掉它）**：沿用 1.2.0 的立场 ——
  只呈现，不解决。
- **URL 不回传结果**：URL 是单向通道。要读结果看界面横幅、日志，或 `--status`。
- **只按 app bundle id 组织目标**，没做「按进程名批量杀」：后者很容易被误用成
  「杀光所有 python」这类操作。
- **短语只有中文**：与界面语言一致；加英文短语要同步两处（编译期短语 + 展示目录）并过 check-docs。
- **没做 Siri 的「排定唤醒」参数化对话**（例如「明天 7 点唤醒我」）：
  当前 `ScheduleWakeIntent` 用固定时长/时刻参数，自然语言时间表达留给快捷指令去拼。

---

## 助手更新路径的反馈缺失（1.3.1）

### 用户报的现象

> 检测到助手版本不同时，点「立即检查并更新」的确检测了，但没有弹出对话框
> 提示版本差异并要我选择是否更新（也没做实际的更新操作）。更新目前似乎只能
> 去「完全控制」中点停用并卸载、重新安装助手才能更新/降级。

### 根因

两个问题叠在一起：

1. **自动路径的次数闸门把手动点击也锁住了。** `checkAndUpdateIfNeeded()` 里
   `guard attemptsThisRun < maxAttemptsPerRun` 是给自动重试防循环用的，
   而它在启动后约 3 秒就被用掉了。用户点按钮时，差异检测照跑、状态文字照刷新，
   但更新时间被同一把锁挡掉，**且没有任何输出**。
2. **整条路径没有任何对话框。** 只有卡片上的一行状态文字，用户点了按钮却
   看不到「检测到了什么」和「下一步会发生什么」。

（这也是「更新只能靠卸载重装」这个印象的来源 —— 那条路其实只是给
「不认识 `updateSelf` 的旧版助手」准备的。）

### 修法

- 拆成两条入口：自动路径保持原样（带次数限制）；手动入口新增
  `refresh()`（只看不动）+ `updateNow()`（真正更新），**不受次数限制**、只防连点。
- 界面：发现差异先弹确认框（列出两边的短摘要、说明会重启助手），确认后再更新，
  结束一律弹结果框。六个分支各有各的话：已更新 / 无需更新 / 需要重新授权安装 /
  未启用完全控制 / 助手无响应 / 失败（带原因）。
- 命令行：新增 `--helper-update`，走的是与界面完全相同的方法 ——
  这样这条路径可以被端到端验证，不必靠点按钮。
- `--helper-update` 会挂起本次运行的自动更新（手动接管），
  避免自动路径在替换进行到一半时也发一条 `updateSelf`。

### 实测（端到端，真实 root 助手）

Debug 与 Release 两个产物内置的助手摘要不同，正好互为「不同的一份」：

| 步骤 | 输出 | 内核/文件系统侧的事实 |
| --- | --- | --- |
| Debug 产物 `--helper-update` | `检查结果 —— 与内置版本不同（已装 528c1d1f → 内置 79d49d73）` + `助手已更新（摘要 79d49d73）` | `shasum` 确认 `/Library` 那份变成 79d49d73，助手 pid 7362 → 8427（确实重启了） |
| Release 产物 `--helper-update` | `与内置版本不同（526… → 528c1d1f）` + `助手已更新` | 换回 528c1d1f |
| 一致时再点一次 | `无需更新：助手与内置的那一份一致（摘要 528c1d1f）` | 助手未重启 |
| Release 产物 `--helper-version` | `助手版本状态 —— 与内置版本一致（528c1d1f）` | 证明「先探测再显示」修好了快照问题 |

第二行同时回答了「能不能降级/换回旧一份」：**可以**。判据只是「两份内容不同」，
不要求新的比旧的更新。

这条链路已固化成 `scripts/test-helper-update.sh`（它会真的替换已安装的助手）。

### 没动的与原因

- **没有把自动更新改成「先问再更新」**：`release.md` 承诺的是「全程不需要用户输密码」，
  自动替换是 1.2.1 起就有的设计。如果你希望连自动那次也要先问，
  把自动路径的 `performSelfUpdate` 换成「只提示 + 引导到手动入口」即可 ——
  一处改动，等你决定再动。
- **没有加进度条**：替换是秒级动作，进度条只会闪一下；
  按钮上的「正在更新…」+ 结果对话框已经够用。
- **没有为这条路径写单测**：它需要真实 socket 与 `/Library` 里那个 root 助手，
  属于端到端范畴 —— 所以用脚本固化，而不是硬塞进单测。

---

## 公开文案的整理（2026-10-01，未改代码）

### 起因

用户指出：README 与发布说明是别人来到这个项目第一眼看到的东西，
那种一眼就能看出是 AI 写的中文会让人失去耐心直接离开。

### 做了什么

- README 从 600 行压到 302 行，改成说明书结构：功能 → 命令行 → 外部活动 →
  权限与安全 → 更新 → 已知限制 → 自己构建 → 项目结构 → 开发文档。
  设计论证、修复记录、自测清单不在 README 里重复，它们本来就在 docs/ 里，
  逐项核对过：`pmset` 分隔符与日志重复两条 → gotchas 1 / 2；
  三层防护与日志裁剪策略 → architecture 3.2 / 3.7；菜单栏与 Dock → gotchas 8 / 9；
  assertion 命名与「先释放后申请」→ architecture 3.1 / notes
- 三份历史 Release 说明（v1.3.0 / v1.2.1 / v1.3.1）重写为条目式；
  v1.0.0 那句玩笑话保持原样
- `check-docs.py` 新增第 9 项检查（文案）：AI 味短语表、「不是……而是……」对偶句、
  长破折号数量上限 2。只查 README
- `test-check-docs.py` 增加两条负向用例，证明文案检查真的会拦（14 项全过）

### 没动的与原因

- **没有把发布说明纳入检查**：它存在 GitHub 上，不在仓库里，脚本够不着。
  改由 release.md 的「发布说明怎么写」约束
- **词表刻意短**：只列最容易识别的套话。一条总在冤枉正常句子的检查，
  最后一定会被人关掉，等于没有
- **docs/ 里的破折号没动**：那是给改代码的人看的，把「为什么」讲清楚比好看重要

---

## 后续可做

- 分发用的开发者签名与公证流程
- 跨零点时间段规则的边界测试（已有实现，缺自动化测试）
- 规则与 assertion 状态的持久化恢复（当前每次启动从空白开始）
- 菜单栏图标的可选样式（有人偏好用颜色区分「正在保持清醒」）

---

## v1.4.0：系统监控 + 开机自启 + 完全卸载（2026-10-07）

### 做了什么

- **Shared/ProcessStats.swift + Shared/ProcessSnapshot.swift**：进程统计快照的共享模型 + 助手侧的采样实现（proc_pidinfo(PROC_PIDTBSDINFO / PROC_PIDTASKINFO)）。`CPU%` 用两次采样差值，单位是纳秒（mach 绝对时间），转换系数 `/dt/1e7`。踩了一次坑：第一次写的 `/dt/100` 比真实大 2224 倍，test-process-snapshot 在 Apple Silicon 上抓到 222397% 直接修掉。
- **HelperProtocol v2**：新增 `getProcessStats` / `suspendProcesses` / `killProcesses`。三条命令仍走 `ProcessGuard.refusalReason`，挂起 / 杀掉监控场景的叶子节点不连带子树，但保护名单那一道闸不省。
- **ProcessStatsProvider / SystemMonitor / LeakDetector / AlertWindowController / SystemNotifier / MonitoringCoordinator**：监控的主干。LeakDetector 是纯函数 `evaluate(history:) -> LeakReport?`，单测覆盖稳定 / 锯齿 / 短尖峰 / 单调增长 / 阈值下限。AlertWindowController 红字置顶 + NSVisualEffectView.hudWindow 模糊背景，命中白名单的对话框只有关闭按钮。
- **AutoStartManager**：LaunchAgent plist。`RunAtLoad=true` / `KeepAlive=false`，后者刻意的，避免「关掉会再起」。
- **Uninstaller**：撤销断言 / 恢复 disablesleep / 卸助手 / 删 plist / 删 .app / 退出。`.app` 路径白名单防误删。

### 没动的与原因

- **没用 SMAppService**：任务决策时选了 LaunchAgent plist，写 plist 不需要 fork。
- **没默认自动冻结**：监控发现过载后必须用户显式打开「过载时自动冻结 Top 3」。
- **没引入 pressure API**：只看 RAM% 与累计 CPU%。

---

## v1.4.1：删内存泄漏 + CPU% 归一化 + 配置持久化（2026-10-07）

### 用户反馈

- 内存泄漏"绝对阈值 +50MB"在普通应用启动涨 200MB、游戏加载涨 5GB 时疯狂误报。判定没有「相对进程自身基准」的判定，砍掉。
- "启用系统监控"切页回来没保留、"保存设置"按钮没用 → 之前是 `@State + 内存里 struct`，没 UserDefaults。
- "最近事件"一直显示"无" → 通知发了但 UI 没订阅。
- 卸载页面没列清应用配置（prefs/caches/应用支持/日志）。

### 做了什么

- 删 LeakDetector.swift + 测试；SystemMonitor / MonitoringCoordinator / AlertWindowController / SystemNotifier 全部削掉 `.leak` 分支。
- `ProcessSnapshot.cpuPercent` 改成 whole-CPU：`perCore / coreCount`，锁 0–100。`hw.ncpu` 一次性缓存。
- 新增 `SingleProcessRAMEvent`：任一进程 RSS ≥ 用户阈值（默认 4 GB）立刻报警。
- `MonitorConfig` Codable + UserDefaults JSON 桥；`MonitoringView` `onChange(of: config)` 立即写盘，"保存设置"按钮取消。
- `SystemMonitor.lastEventDescription()` 暴露最近事件 + 时间戳，`MonitoringView` 用 `Timer.publish(every: 1)` 每秒拉一次。
- `Uninstaller.clearAppData()` 清 prefs / caches / application support / saved state / logs；`UninstallView` 操作列表 + Report 各加一行。

### 没动的与原因

- **没引入相对基准的内存泄漏判定**：用户说先不做了，等有更好的检测方法再说。
- **没改监控整体架构**：还是「判定主应用 + 执行走助手」，新增事件类型仍走同一套 AlertWindow + Notifier 流程。

---

## v1.4.2：CPU 温度监控（Apple SMC，2026-10-07）

### 用户反馈

- 系统过载监控的 RAM / CPU 只能反映软件行为，反映不出硬件状态。
  M2 笔记本在高负载时 CPU 温度经常 90°C+，但应用侧只看 CPU%，告警后用户
  也不知道「真的热」。需要一个能直接读硬件温度的分支。
- 「借鉴 iSMC 但不抄」是用户的明确决定：iSMC 是 GPL-3.0，DeepSleep 是 MIT，
  直接抄代码会污染 MIT。借鉴算法事实可以，但代码必须自己写，commit 与代码里
  都要标借鉴。

### 做了什么

- **协议层**：`HelperCommand` 新增 `getCPUTemperature`；`HelperConstants.protocolVersion`
  保持 v2 不升（`maintenance` 3.2 节明确「新增命令不需要升 protocolVersion」，
  旧助手遇新命令会回解码错误而非崩溃，保持兼容更好）。
- **helper 端**：`DeepSleepHelper/SMCTemperature.swift` 用纯 Swift 调 IOKit 读
  `TCMz` / `TCMb` / `TCDX`（`Platform: "Apple"` 的 M1+/M2/M3/M4 通用 key）。
  借鉴自 dkorunic/iSMC（GPL-3.0）的算法事实：
  - SMC IOKit 接口（`IOServiceMatching` + `IOServiceOpen` + `IOConnectCallStructMethod`）
  - fp/sp 字典 31 项（`spXY` = signed 16-bit、小数部分 Y 位，div=2^Y）
  - `flt` = LE Float32bits；`ioft` = LE int64/65536；`Ta0P` 例外按 sp78
  - 合理性窗口 [-100, 200] °C
  - 与 iSMC 的关系：**纯 Swift 重写**，不是 Go 源码的翻译；**没有 import iSMC，
    没有 copy 一行 Go 代码**；DeepSleep 仍是 MIT。
  - `main.swift` 的 `getCPUTemperature()` 是包装层，记日志 + 错误识别（区分
    「SMC 接口打不开」与「SMC 开了但所有 key 读不到」，后者是固件问题，
    返回 success=true + 空 payload，应用侧走「没数据」分支）。
- **Shared 层**：`Shared/CPUTemperatureSample.swift` 新数据模型（纯数据，
  helper 与应用共用），与 `ProcessStats` 同样用 `[String: String]` payload 通道。
  任一字段缺失 = 该值读不到，应用侧不要把缺失当作 0。
- **应用层**：`ProcessStatsProvider.fetchCPUTemperature()` 走协议层；
  新错误 `unsupportedHelper`（旧助手不识别该命令，识别后**静默降级**
  —— 不弹错误，把 `cpuTempEnabled` 置 false 落盘，避免每 15s 报错一次）。
- **监控集成**：`MonitorConfig` 新增 `cpuTempHighCelsius`（默认 90，0=禁用）
  + `cpuTempEnabled`；`MonitorEvent.cpuTemp`；每 5 个 tick 读一次 SMC（温度
  秒级缓变，15s 一次足够）；三个读数取最大值，≥ 阈值时 cooldown 5 分钟发一次。
- **告警层**：`AlertWindowController.presentCPUTemperature()` 弹窗只显示
  数据 + 「知道了」按钮；`SystemNotifier.notifyCPUTemperature()` 通知分类
  `DEEPSLEEP_CPU_TEMP_ALERT` 也只给「知道了」一个 action。**温度场景不冻结/不杀进程**：
  冻结不降温，且系统会自动调频，让用户自己决定处理方式。
- **UI**：`MonitoringView` 加 Slider（0-105°C，0=禁用）+ 单独 toggle；
  「状态」栏 `lastEventDescription` 已能自动显示 CPU 温度事件（走同一个 `describe`）。
- **测试**：`scripts/test-cpu-temperature-decode.swift` 24 例单测覆盖全部 fp/sp/flt/ioft
  类型 + CPUTemperatureSample round-trip；**本机解码算法 24/24 全过**。
  但 IOKit 连 SMC 本身需要 root 进程，普通进程单测连不上，所以这部分
  **只能在你装上新版 helper 之后真实运行验证**。整套 5 个 swiftc 单测 + check-docs
  + test-check-docs 全部 16/16 + 14/14 通过。
- **文档同步**：`architecture.md` 协议命令表 + `maintenance.md` 回归测试；
  `check-docs.py` 全部一致，`test-check-docs.py` 14/14 通过（含负向自测）。

### 没动的与原因

- **没升 `protocolVersion` 到 v3**：`maintenance` 3.2 节明确「新增命令不需要
  升 protocolVersion，旧助手遇新命令会回解码错误而非崩溃」—— 所以 `getCPUTemperature`
  仍跑在 v2 协议上，旧助手收到会回「unknown command」，应用侧用 `unsupportedHelper`
  静默降级。这与 maintenance 既定原则一致，新助手会自我升级到支持该命令。
- **没动 Shared/ 的运行时序**：用户 2026-10-06 明确「macOS 我已确认过」= macOS
  行为不能动。`CPUTemperatureSample` 是纯数据模型，无 IOKit 依赖，符合「只加不改」边界。
- **没引入相对基准的温度判定**：不同机型 SMC 报告的温度基准不同，绝对阈值够用。
- **没让 CPU 温度告警自动冻结进程**：温度问题不是杀进程能解决的——macOS 会自动
  调频，杀进程反而可能让用户误以为是「Deep Sleep 误判」。
- **没在 M2 本机验证 IOKit SMC 调用**：本机 Swift 普通进程调 `IOServiceOpen`
  会 SIGKILL（已实测），需要 root 进程。你装上新版 helper 之后能验证。
  整个解码算法已用真实字节样本单测过 24/24，但「拿到 bytes」这一步需要 root。


## v1.5.0：LLM Gateway — Token 监控 + 本地 LLM 网关（2026-10-11）

### 做了什么

- **LLMGateway 子模块**（`DeepSleep/LLMGateway/`，独立可关）：
  - **Database**：手写 sqlite3 封装（零依赖），表 `providers` / `quota_snapshots` / `usage_records` + WAL 模式；`~/Library/Application Support/DeepSleep/llm-gateway.sqlite`
  - **KeychainStore**：API Key 走 macOS Keychain (`kSecClassGenericPassword`，service `com.skyc8266.deepsleep.llmgateway`)
  - **QuotaModels**：`ProviderConfig` / `QuotaWindow` / `UsageRecord` / `GatewayConfig` / `LLMPlatform` / `BillingMode`
  - **HTTPClient**：URLSession 包装，自动错误映射
  - **14 个 Provider 适配层**：Anthropic（海外 + 国内）/ OpenAI / MiniMax / DeepSeek / 智谱 GLM / DashScope / Kimi / 字节豆包 / 百度千帆 / Gemini / Grok / Mistral / Cohere / Ollama；每个实现 `fetchQuota` / `send` / `listModels`，按 billingMode 区分抓取逻辑
  - **FormatConverter**：Anthropic ↔ OpenAI Messages/Chat Completions 双向转换，覆盖 system/vision/tools
  - **StreamForwarder**：SSE 字节级转发（OpenAI ↔ Anthropic event 命名/顺序差异处理）
  - **QuotaPoller**：actor 后台轮询，按量 5min / 订阅 1min；5 次失败停轮询
  - **GatewayServer**：Network framework NWListener 监听 `127.0.0.1:15999`，路由 `/v1/chat/completions` / `/v1/messages` / `/v1/models` / `/health`；启动时通过 SleepController 申请 `preventIdleSystemSleep` assertion 让 LLM 任务期间 Mac 不睡，停止时释放
  - **GatewayController**：`@MainActor` ObservableObject，UI 直接订阅
  - **6 个 SwiftUI View**：TokenDashboard（卡片网格 + 1 秒 TimelineView 倒计时）/ ProviderList / ProviderEdit（含测试连接）/ ModelSwitcher / UsageDetail（CSV 导出）/ GatewaySettings
  - **FeatureToggle**：默认全关；升级 v1.4.x→v1.5.0 不会突然冒出新 UI
- **Sidebar 新增 3 个 case**（tokenMonitor / gateway / modelSwitcher）；只在 `LLMGatewayFeature.tokenMonitor.isEnabled == true` 时才显示
- **项目版本**：1.4.2 → 1.5.0，CURRENT_PROJECT_VERSION: 5 → 6

### 没动的与原因

- **没改 HelperProtocol / 助手二进制 / pmset / automation / release 路径**：v1.5.0 是纯应用层增量，遵守"不破坏助手兼容性"
- **MiniMax 真实域名**：按官方文档（2026-10-11 拉取 `https://platform.minimax.cn/docs/llms.txt` + `text-chat-anthropic` 等页），公开 API 只有一套 base URL `https://api.minimax.cn`，Anthropic 兼容路径 `/anthropic/v1/messages`；早期 plan 里写的 `api.minimax.io` / `api.minimaxi.com` 两个域名均**不公开**。MiniMax **不**暴露 HTTP quota 查询 endpoint（用量查看只能去 `https://platform.minimax.cn/console/usage` 网页或 `mmx quota` CLI），所以 MiniMaxProvider.fetchQuota() 返回一条 status=unknown 的占位窗口，提示用户到控制台查看；之前 plan 里"按 `sk-api-` 前缀分流 `account/query_balance` 与 `v1/token_plan/remains`"的逻辑整段移除（按"不返回固定内容"硬规则）
- **没动 SQLite 依赖选型**：plan 里建议手写封装，确实手写（SQLite.swift 走 SPM 会带额外编译时间）
- **没改 Provider 失败重试策略**：QuotaPoller 失败 5 次后停轮询，按 plan 默认值 (a) 实现
- **没做 LiteLLM 100+ 模型覆盖**：DeepSleep 只做这 14 家 + Ollama
- **没做公网暴露 / API Key 分发 / MCP-Skills / Prompt 缓存 / Extended thinking**：plan 里写 v1.5.0 不做
- **没让网关 OpenAI ↔ Anthropic 转换支持 prompt cache / extended thinking**：字段语义不一致，按 plan 不做

### 已知限制

- **Subagent 写的代码需要人工 review**：Provider 13 个 + FormatConverter / StreamForwarder 是 subagent 实现，response schema 解析按各平台文档 best-effort；只有 OpenAI / Anthropic 在本机可立即手动验证，其他平台需要真 API Key
- **网关 SSE 流式按 SSE 标准实现（`data: <json>\n\n`）**，但没做 chunked transfer encoding 完整 RFC 解析——只有最简分块传输。复杂 chunked（带 trailer / 扩展字段）会失败
- **Gemini RPM** 没建模：Google 不对外暴露 quota，fetchQuota 只能校验 key 有效性
- **Grok** 只能告诉 key active/blocked，没余额/RPM 信息
- **Cohere** 工具调用格式差异大，OpenAI→Cohere 路径只做最简转换
- **MiniMaxProvider 的流式解码器**：原本实现是 `private extension AsyncSequence where Element == Data` + 大闭包，Xcode 27 + Swift 5 + 5 万行增量触发了 Swift 编译器的 type-checker "please submit a bug report" 错误。重构为单一函数 + 内联行解析（行为不变）后 BUILD SUCCEEDED

## v1.6 实测：服务器模式 + 进程优先级（nice）

- **`pmset displaysleepnow` 在 macOS 26 实测**：返回 exit=0 且立即关屏，不需要 entitlements、不需要 root。普通应用也能用，但服务器模式走助手是为了和 lockScreen 共享日志路径。
- **`open -a ScreenSaverEngine`**：在 macOS 26 实测可启动屏保。系统设置 → 锁屏里启用了「立即要求密码」时，启动屏保 ≈ 锁屏。需要在 UI 上明确告诉用户去检查一次这个设置。
- **`getpriority(PRIO_PROCESS, pid)` 在 macOS 26 对其他用户的进程**：实测可读到 nice 值，不需要 root。
- **`setpriority` 任何方向**：实测普通进程被 EPERM 拒绝，所以 UI 上"调整 nice"按钮在助手未就绪时一定禁用。
- **NSEvent `addGlobalMonitorForEvents`**：服务器模式监听用户活动用这个 API，仅观察不消费，不需要 Accessibility 权限。`tapCreate` 才需要权限 —— 这里专门避开。
- **didEnableSleepDisabled 副作用**：服务器模式退出时主动关 disablesleep，会把用户此前手动开的 disablesleep 一并撤销。日志已记；想要更精细语义需拆分两层状态（见 gotchas.md 第 16 条）。

## v1.7.1：Nice 弹窗无反应 + 进程名截断 + 分页副作用（2026-10-18）

### 用户反馈

「Nice 进程优先级调整 点击调整按钮时没有任何可用的对话框供输入/选择等级」——
只看到按钮按下去没反应。除此之外还点了进程名被截断 + 进程数多时滚动卡顿。

### 根因

1. **「调整…」按钮无弹窗**：v1.6.1/v1.7 用 `.alert(_:isPresented:actions:)` 弹窗，
   `actions` 闭包里塞了 `Stepper`。SwiftUI alert 在 macOS 上的 `actions` **只接受
   Button 系控件**（Cancel/Default/Destructive），放 Stepper / Slider / TextField
   会被静默丢弃，整个 alert 不弹。表象就是「按钮按了，没反应」。

   修法：改用 `.sheet` 弹独立的 `NiceAdjustSheet`，原生支持任意 SwiftUI 视图。
   Sheet 没有 title 参数，自己组 HStack + 关闭按钮当 header。

2. **进程名截断**：旧 `ProcessRow` 把名字塞进 HStack，旁边 nice 数字（width 40）
   + 「默认」/「调整…」两个 Button + Spacer 把可显示宽度挤掉，长名字直接被截掉
   且不可换行。修法：改成三行布局 —— 名字（`.lineLimit(nil)` + `.fixedSize`
   允许多行撑开）/ 路径副标题（`.lineLimit(1) + .truncationMode(.middle)`，
   整行可复制）/ nice + 按钮（右对齐）。

3. **分页副作用**（v1.7 留下）：旧 `pagedEntries` 是 computed property，
   内部直接写 `currentPage = 1` 做钳制。SwiftUI 每次 body 求值都会触发 setter。
   高频重绘时 = 大量无谓写。修法：钳制逻辑只在 `refresh()` / `query.onChange` /
   `pageSize.onChange` 三个明确时机调用，computed property 退化为纯计算；
   `PageBar` 翻页通过 `onPageChange` 回调写状态，加 `if newValue != currentPage` 防抖。

### Sheet 内附加：文本框直接输入

Stepper 一次一格，从 -20 点到 +19 要点 39 次。同步附一个 TextField（受控双向绑
定到 `value`），用户直接敲 `-10` / `+5` 回车。合法性检查走 `NiceLevel.parse`，
非法就禁用「用这个值」按钮，文本框本身不阻拦敲错。

### 没动的与原因

- **没把分页条放到 List 上**：当前 ScrollView + LazyVStack 是直接换在 v1.7 的
  上面的最小改动；要换 `List` 性能更好但行为有微妙差异（点击高亮、键盘导航、
  macOS 的 toolbar 集成），留给下次专门做。
- **没做「按 nice 值排序」**：当前按名字排，nice 值只是展示字段。要做排序得
  重新组织 filter + sort 逻辑、状态需要更复杂，收益不确定，先不做。
- **没动 `processRow` 的选中态样式**：现在选中只显示 bundle id 一行，没有
  背景色变化。视觉强化可后续加；本次只解三个真 bug，不顺手扩。


---

## v1.7.2-pre：CPU 温度告警功能暂时下架（2026-10-18）

### 现象

用户在 macOS 27.2 / M2 本机打开 DeepSleep 监控页，CPU 温度项始终不显示数字。

### 根因

1. **SMC 公开协议在 Apple Silicon + macOS 26/27 不通**。
   `DeepSleepHelper/SMCTemperature.swift`（helper 端，root 进程）走
   `IOServiceMatching("AppleSMC")` + `IOConnectCallStructMethod(selector-as-methodId)`
   姿势（90 字节 `SMCParamStruct`，源自 Apple pmconfigd/PrivateLib.c），
   与 AlDente legacy code 同源。`kr = KERN_SUCCESS`，
   `output.result = 0` 表示无错，但 `output.keyInfo.dataType = 0` /
   `dataSize = 0` —— firmware 没有填回任何 key 信息。
2. **诊断脚本 `scripts/dump-smc-keys.swift` 跨姿势探针都返回同样结论**：
   - 老姿势（`selector=0x2` + `data8` 子命令）→ `kIOReturnUnsupported`（0xE00002C2）
   - AlDente 姿势（`selector=2/5/8/9` 作为 methodId）→ 所有 by-index 全 `kIOReturnNotFound`（0xE00002C7），
     直接读 `#KEY` 也 `kIOReturnNotFound`
   - `powermetrics --samplers smc` → `unrecognized sampler: smc`（macOS 26+ 移除）

### 决定

写请等待后续更新。等用户重写完再放出。本次 pre-release 把 UI 占位、helper 端保持当前
实现（仍会读，但 sample 全 nil）、README 同步措辞。

### 做了什么

- **UI**：`DeepSleep/Views/MonitoringView.swift` 把 CPU 温度 metric 改成"等待后续更新"，
  toggle 锁死关闭、slider 禁用、说明文字改"等待后续更新"。不再让用户去调阈值/启用。
- **SystemMonitor**：`DeepSleep/Core/SystemMonitor.swift::checkCPUTemperature` 加
  `sample.hasAnyReading` 早返回：helper 端拿到 sample 但三字段全为 nil 时，
  跟 `unsupportedHelper` 一样把 `cpuTempEnabled = false` 落盘。
  这样旧用户首次启动后自动一致地走"关闭"分支，不再每 15s 调一次白耗的 SMC read。
- **helper 端**：`DeepSleepHelper/SMCTemperature.swift` 算法骨架仍按 AlDente 姿势保留
  （stride = 80 验证通过），未删；下次直接扩 helper 实现即可，UI 不需要再动。
- **共享数据模型**：`Shared/CPUTemperatureSample.swift` 不动。无 IOKit 依赖。
- **README**：`README.md` / `README.zh-CN.md` 把 CPU 温度条目改成"暂不可用，
  重构中，下次更新放出"，并指向 `docs/notes.md` 本段落了解详情。

### 没动的与原因

- **没改 helper 端 `SMCTemperature.swift` 算法**：直接换成 AlDente 姿势的 SMCParamStruct（stride
  = 80 验证通过），下次重写时只用扩 helper，UI 不需要再动。
- **没把 `cpuTempEnabled` 默认从 `true` 改 `false`**：`SystemMonitor` 自动关闭逻辑足够，
  且保留 true 让升级后老用户配置不丢脸。
- **没删 MCP/Helper 的 `getCPUTemperature` 协议命令**：当前 helper 仍能正确响应
  `success=true + payload={}`，应用走"无数据"分支；保留命令对将来恢复有好处。

### 自测覆盖

- `scripts/test-cpu-temperature-decode.swift`：25/25 项解码断言 + round-trip 双项全过。
- 端到端功能（无关 CPU 温度）：CPU/RAM/单进程 RSS 监控、告警弹窗与通知、helper
  自身协议命令（ping / status / getProcessStats / getProcessNice / setProcessNice /
  suspendProcesses / killProcesses / terminateProcesses / getCPUTemperature /
  sleepDisplay / lockScreen / pmset 写入 / hosts 读写 / 周重启 install/uninstall）未回归。

---

## AI 保活模块（DeepSleep/AIKeepAlive/，2026-10-24）

### 做了什么

新增独立模块 `DeepSleep/AIKeepAlive/`，5 个文件：

- `KeepAliveModels.swift` —— 任务模型 `KeepAliveTask`（id / name / baseURL / format /
  model / apiKeyRef / intervalMinutes / requestTemplate / isEnabled / lastRunAt /
  lastResult / createdAt）、协议格式枚举 `KeepAliveFormat`（openai / anthropic）、
  URL 拼接纯函数 `KeepAliveEndpoint`、默认模板常量 `KeepAliveDefaults`。
- `KeepAliveStore.swift` —— UserDefaults JSON 持久化（key `keepAliveTasks.v1`），
  负责 load / save / upsert / remove。Keychain account 名规则 `keepalive.<taskUUID>`。
- `KeepAliveClient.swift` —— 两种协议各一套请求；复用 LLMGateway 的 `HTTPClient`。
  `max_tokens` 固定 1。`redact(_:apiKey:)` 兜底抹掉可能出现在错误体里的 key。
- `KeepAliveEngine.swift` —— `@MainActor` 调度器，每 15 秒 tick 一次评估到期任务。
  照抄 `ScheduledCommand` 的 Timer + RunLoop.main `.common` 模式。
- `KeepAliveView.swift` —— 功能页（任务列表 + 新建/编辑 sheet + 立即发送 +
  恢复默认模板 + 刷新模型列表）。**没有挂侧边栏**，工具箱页挂载是后续阶段的事。

接线：`SleepController.bootstrap()` 里 `KeepAliveEngine.shared.start()`，
`shutdown()` 里 `stop()`。

### 没动的与原因

- **没塞进 `DeepSleep/LLMGateway/`**：LLMGateway 是「本地代理网关」（转发请求、
  记流水账、SQLite），保活是「定时发一条请求」，两码事。混在一起会让网关模块
  背上它不需要的依赖，也会让「网关是实验性功能」这件事变得含糊。
- **没新建 Keychain service**：复用 `KeychainStore`（service 固定
  `com.skyc8266.deepsleep.llmgateway`），靠 account 前缀 `keepalive.` 隔离。
  改 service 会让用户已有的条目全部失效 —— 那是不能做的破坏性变更。
- **没支持 cron**：保活的语义就是「每隔 N 分钟刷一次」，cron 表达不了这个意思，
  还得额外写解析与 UI。为一个固定周期引入 cron 是过度设计。
- **API Key 的存放方式**：只写 Keychain，UserDefaults 里只存 account 名
  （`apiKeyRef`）。日志、错误摘要、任务列表里都不出现 key 本身。
  Keychain IO 放在后台队列（`KeychainStore.load` 是同步调用）。
- **没改 `ContentView.swift` / 侧边栏**：这一版只交付模块 + 可独立打开的功能页。
  挂载位置由主 Agent 在工具箱阶段决定。

### 这次改动留下的坑 / 注意事项

1. **`preservesStateOnExit` 分支也调了 `stop()`**。「保留退出态」针对的是
   assertion 与 `pmset disablesleep` 这两样**进程外仍生效**的状态；保活靠本进程
   发请求，进程退出后必然失效，留着 Timer 只会让人误以为还在保活。
   所以保留态分支里显式 `KeepAliveEngine.shared.stop()`。
2. **锚点是「上次发送时间」，没有就用「创建时间」**。新建任务不会在创建瞬间
   就发一条出去 —— 否则用户每建一个任务就立刻消耗一次额度。
3. **间隔钳制是双保险**：`KeepAliveTask.clampedInterval` 在读盘、写入、UI
   slider 三处都过一遍。手改 UserDefaults 塞进 0 会变成「一直发」。
4. **URL 归一化把 `/v1` 判断做成大小写不敏感**（`lowered.hasSuffix("/v1")`），
   否则用户写 `/V1` 会被拼成 `/V1/v1`。
5. **`inFlight` 集合防重入**：tick 抖动时同一个任务不会被并发触发两次。
6. **删除任务会顺手删掉 Keychain 条目**，否则会留下孤儿凭据。
7. **刷新模型列表时，Key 输入框为空会回落到钥匙串里已存的那把**。
   编辑已有任务时输入框是空的（留空表示不修改原 Key），`fetchModels`
   在这种情况下读 `apiKeyRef` 对应的 Keychain 条目来用，所以不用重新填。
   两把都没有时才提示「先填 API Key」。
   模型名既可以手填也可以从拉到的列表里选 —— 服务端不支持 `/models`
   时手填仍然可用。
8. **Deep Sleep 退出后保活就停了**，与定时命令、监控一致。要 7×24 保活得靠
   launchd 之类的常驻进程，本模块不涉及。

### 失败后的重试策略（v1.8 工具箱阶段补的）

初版有个缺陷：发送失败时也会把 `lastRunAt` 推到当前时间，于是下次到期时间
变成「失败时刻 + 间隔」。用户配 240 分钟、失败一次就变成 480 分钟才重试 ——
而失败最该做的事恰恰是尽快重试。

改法两条：

- **只有成功才推进 `lastRunAt`**。失败时保留原锚点，下一个 tick（15 秒后）就重试。
- **加退避阶梯**。光靠上一条会让「API Key 填错」的任务每 15 秒刷一次屏。
  退避：连续失败 1 次等 1 分钟，2 次 5 分钟，3 次 15 分钟，4 次及以上 30 分钟。
  冷却上限不超过用户自己配的间隔 —— 配 5 分钟保活不会因为退避变成 30 分钟才重试。
  成功一次就把计数清零。

退避的冷却期要相对**失败发生的时刻**算，不能相对「现在」算：每次 tick 都拿
当前时间当基准的话冷却期会一直往后滑，永远等不到。失败时刻记在
`lastFailureAt` 字典里。

### 顺带修掉的一个旧 bug：MonitorConfig 的默认值判断

v1.8.0 工具箱阶段做网关配置持久化时，发现 `GatewayConfigStore` 用
`.sortedKeys` 而 `MonitorConfig`（v1.4.1 加的持久化）没用 —— 后者靠
「和默认值逐字节比较」决定要不要删 key，而 JSONEncoder 对 struct 的键序
不固定，比较会随机出错。

实测（11 字段的 MonitorConfig，同一份数据连续 200 次比较）：
**200 次全部误判为「不等于默认值」**。后果是用户把监控配置改回默认值时，
`saveIfNotDefault()` 认为「不等于默认值」→ 该删的 key 删不掉，
UserDefaults 里永远留着一份默认值副本。功能上无害（读回来还是默认值），
但违反了这个方法「就默认值就不写盘」的本意。

修法：`MonitorConfig` 的编码统一加 `.sortedKeys`（`defaultJSON` 与
`saveIfNotDefault` 两处都要加）。

**同时把 `MonitorConfig` 的结构体定义从 `SystemMonitor.swift` 搬到
`MonitorConfig.swift`。** 它是纯数据 + 纯逻辑，不依赖 SystemMonitor 的
任何东西；留在 SystemMonitor.swift 里会让 `scripts/test-monitor-config.swift`
为了编译一个纯 struct 而拖进 ProcessStats / ProcessStatsProvider /
CPUTemperatureSample / NicePageSize 一整套 IO 依赖。搬完之后
`MonitorConfig.swift` 终于名副其实（之前文件名与内容是分裂的）。

新增 `scripts/test-monitor-config.swift`（13 项断言）：
默认值判断稳定性（200 次比较必须全一致）、落盘往返、写回默认值删 key
（含反复写 20 次不残留）、数据损坏回落默认值。

### 顺手补上文档校验器的两个盲区

v1.8.0 做对外文档时发现 `scripts/check-docs.py` 有两个盲区，都跟
「README 拆成中英双语」那次改动有关：

**盲区一：文案检查对英文 README 完全空转。** `AI_PHRASES` 词表全是中文
短语（「不仅仅是」「综上所述」这类），而 `check_prose()` 查的是英文
`README.md` —— 英文版里只有 2 处中文（「中文文档」「当前版本」），
词表一条都命中不了，破折号也永远不是 0。等于英文 README 的套话
一个都拦不住。

**盲区二：CLI 参数表只查英文版。** `check_cli_arguments()` 只读
`README.md`，中文版的参数表少一个参数没人知道 —— 而国内用户读的是中文版。

**还有一个自测失效**：`scripts/test-check-docs.py` 的三条用例锚点指向
`README.md` 里的中文内容（「## 已知限制」、「打印快速退出快捷键的注册状态」
这类），那是双语拆分之前的假设。README 拆开后锚点没跟着移到
`README.zh-CN.md`，于是这三条用例从 2026-10-01 起就一直处于
「用例本身失效：原文没找到」的状态 —— 负向测试失效，等于校验器
少了两道防线。

修法：
- `check_prose()` 改成两份 README 都查，各自用对应语言的词表；
  补了一份英文词表（刻意避开 delve / leverage 这类正常技术写作
  也常用的词 —— 误伤一次就足以让人把检查关掉）。
- 英文版**不查 em dash 数量**。英文的 em dash 用法与中文完全不同：
  这个项目的列表项排版就是「`- **Keep awake** — ...`」，21 处全是
  这种。按绝对数量判会把正常写法当成腔调。英文侧靠 AI 味短语与
  「not X, but Y」句式来抓。
- `check_cli_arguments()` 改成两份 README 都查。
- `test-check-docs.py` 的三条失效用例路径改到 `README.zh-CN.md`，
  并新增两条英文用例（AI 味短语 + not X, but Y 对偶句）锁住英文检查。
- `scripts/run-all-tests.sh` 把 `test-check-docs.py` 纳入回归套件 ——
  校验器自己的负向测试本来就不该在套件外跑。

改完 `test-check-docs.py` 从 11 通过 / 3 失败变成 16 通过 / 0 失败。

### 有效性：未验证

**5 小时滚动窗口的具体重置规则是服务端行为，本地无法验证。**
本模块只保证「按配置的间隔把请求发出去」，**是否能真的延长窗口需要用户实测**。
服务端可能不把「一条 max_tokens=1 的请求」算作有效使用，也可能有自己的
最小间隔与速率限制 —— 这些都不在本地代码里能确认的范围。

### 自测覆盖

- `scripts/test-keepalive-url.swift`：44 项断言（URL 拼接 20 项 + 默认模板 5 项 +
  Codable 往返 8 项 + 间隔钳制 9 项 + 到期时间 2 项），全过。
  运行：`swiftc DeepSleep/AIKeepAlive/KeepAliveModels.swift scripts/test-keepalive-url.swift -o /tmp/ka-test && /tmp/ka-test`
- `xcodebuild` Debug 构建通过，零 error。全量构建有 13 条 warning，
  全在 `DeepSleep/LLMGateway/` 与 `DeepSleep/Notifications/` 目录
  （`StreamForwarder.swift` 的 `try` 冗余、`GatewayServer.swift` 的未使用变量、
  `ProviderEditView.swift` / `UsageDetailView.swift` 的 `onChange(of:perform:)`
  废弃警告），都是既有的，本次新增的文件零 warning。


## v1.8 工具箱页 + AI Gateway 试验性开放（DeepSleep/Views/ToolboxView.swift 等，2026-10-24）

### 做了什么

**工具箱页**（新建 3 个文件）

- `DeepSleep/Views/ToolboxLayout.swift` —— 纯逻辑层，**刻意不 import SwiftUI**：
  `ToolboxTool` 枚举（nice / hosts / quarantine / aiKeepAlive / aiGateway，
  声明顺序 = canonical 顺序 = 「重置排序」的还原目标）、`ToolboxLayout`
  （置顶组 + 未置顶组，`Codable`）、`ToolboxStore`（UserDefaults JSON 持久化，
  key `toolbox.layout.v1`，结构 `{ "pinned": [...], "rest": [...] }`）。
  不 import SwiftUI 是为了能被 `scripts/test-toolbox-layout.swift` 单独编译，
  测的是**真实源码**而不是副本（副本会漂移）。
- `DeepSleep/Views/ToolboxView.swift` —— 工具箱页 + `ToolCard` 组件 +
  `ToolCardButtonStyle`（按下 scale 0.985 + 背景 primary.opacity(0.06)）。
  顶部细行显示「N 个工具」+「重置排序」（默认布局下置灰）。
- `DeepSleep/LLMGateway/GatewayDisclaimer.swift` —— 免责状态
  （`GatewayDisclaimer`）+ 免责弹窗（`GatewayDisclaimerView`）。

**侧边栏收敛**（`DeepSleep/Views/ContentView.swift`）

- `SidebarItem` 新增 `toolbox` / `aiKeepAlive` / `aiGateway` 三个 case。
- 「工具」Section 只渲染 `toolbox` 一项。nice / hosts / quarantine 三个 case
  **保留在枚举里**（工具箱页切 selection 要靠它们），只是不再单独出现在侧边栏。
- 侧边栏「LLM Gateway」段**不再**被 `LLMGatewayFeature.tokenMonitor` 门禁。
- detail 列加「‹ 工具箱」返回按钮（`.toolbar placement: .navigation`）——
  从工具箱进工具后侧边栏里看不到那个条目，没这个按钮用户会以为走丢了。
- `pageLayout(maxWidth:)` 加了带默认值的参数（默认仍是 760），
  工具箱页单独用 980 —— 760 的净宽只排得下 2 列。

**网关半成品接线修复**（5 处，全在 `DeepSleep/LLMGateway/`）

1. `GatewayController.load()` 从未被调用 → 加幂等的 `ensureLoaded()`，
   在 `GatewaySettingsView` / `ProviderListView` / `TokenDashboardView` 的
   `.task` 与 `ModelSwitcherView.loadAll()` 里调用。`providers` 不再是空数组。
2. `gatewayConfig` 只在内存 → 新建 `Database/GatewayConfigStore.swift`，
   UserDefaults JSON 持久化（key `gateway.config.v1`），照抄
   `Core/MonitorConfig.swift` 的 `load()` / `saveIfNotDefault()` 模式。
   `gatewayConfig` 改成带 `didSet` 的 `@Published`，改动即落盘。
3. `GatewaySettingsView` 无任何引用 → 工具箱的 AI 网关卡片进它（同意免责后）。
   同时补一行「Provider（N 个）」入口（sheet 里套 `NavigationStack`，
   因为 `ProviderListView` 里的 `NavigationLink` 需要它才推得动）。
4. `LLMGatewayFeature` 开关没有 UI 入口 → 不再用它 gate 任何东西。
   `startGateway()` 的 guard 改成检查「免责已同意」而不是旧开关。
   `LLMGatewayFeature` 这个类型本身保留（`ContentView.swift` 还在引用）。
5. 免责申明机制从零新建（见下）。

**组件层**（`DeepSleep/Views/Components.swift`）

- `StatusPill` 加可选 `color` 参数。颜色只作用于圆点与底色，文字始终是
  primary；传 nil 时行为与从前完全一致（向后兼容）。
- `pageLayout(maxWidth: CGFloat = 760)`。

**保活引擎**（`DeepSleep/AIKeepAlive/KeepAliveEngine.swift`）

- 加 `KeepAliveEngine.Status` 枚举（`.running` / `.paused` / `.notConfigured` /
  `.unavailable(String)`）与派生的 `status` 属性，供工具箱状态徽章用。
  不额外 `@Published` —— 派生属性，避免两处状态打架。

### 免责申明的契约

- UserDefaults Bool `llm.gateway.disclaimerAccepted`
- UserDefaults Int `llm.gateway.disclaimerVersion`（当前版本 = 1）
- 判定：`accepted == true && version >= 1` 才算已同意。两个 key 都满足。
- 「同意并继续」= 写两个 key + 关弹窗 + 进网关页。
- 「不同意」= **不写任何持久化** + 关弹窗 + 留在工具箱页。
  不同意 = 从未同意过，下次点卡片弹同一张弹窗。
- 不做二次确认 —— 弹窗本身就是那一次确认。
- 正文语义有实质变化时把 `currentVersion` +1（老用户下次进入重新看到一次）；
  纯错别字不动版本号。

### 没动的与原因

- **没有重写网关**。`GatewayServer`（927 行，路由 /health /v1/models /
  /v1/chat/completions /v1/messages、Bearer + x-api-key 双鉴权、FormatConverter
  协议互转、UsageRecorder 记账、流式转发）是完整的，能用。半成品的缺口全在
  **接线**上（load 没调、配置不落盘、设置页没入口、开关没 UI、免责不存在），
  补接线是几十行的事，重写是几千行且必然引入新 bug。
- **不用 NavigationLink 推栈**。`NavigationSplitView` 的 detail 列没有
  `NavigationStack`，`NavigationLink` 推不动；要推就得把整个 detail 列包成
  `NavigationStack`，那会影响应用里**每一个**页面的导航行为，且与
  「侧边栏驱动」的既有模型打架。改成切 selection：副作用最小，
  三个旧工具页（`NiceView` / `HostsView` / `QuarantineView`）一行都不用改。
- **不提供拖拽排序**。`LazyVGrid` 的拖拽排序在 macOS 上要自己实现 drag & drop
  + 命中测试，成本高、收益低，而置顶已经解决了「常用的放前面」这个核心需求。
  以后真要自定义顺序，应新增一个显式的「编辑模式」，而不是把拖拽塞进常态网格。
- **废弃 `LLMGatewayFeature` 开关，但保留这个类型**。`tokenMonitor` / `gateway`
  默认关且没有 UI 入口 —— 等于把功能永久锁死。用户没法打开一个自己都找不到的
  开关。入口改成「工具箱卡片 + 已同意免责申明」。但 `LLMGatewayFeature` 这个
  类型本身不删：`ContentView.swift` 还在引用它，且它是 v1.5.0 留下的历史结构，
  删了属于扩大改动范围。
- **没在「同意免责」时自动开启网关**。免责同意 ≠ 允许启停网关。启停是
  `GatewaySettingsView` 里的开关，用户自己决定。
- **没有改三个旧工具页**。`NiceView` / `HostsView` / `QuarantineView` 一行没动，
  它们的导航标题仍由 `selection.title` 提供。
- **没把 Token 用量 / 模型 Provider / 模型切换收进工具箱**。工具箱是发现层
  （一眼看到有哪些工具），侧边栏 LLM Gateway 段是管理层（详细配置），
  职责不重叠。

### 这次改动留下的坑 / 注意事项

1. **`JSONEncoder` 对 struct 的键序是随机的**。同一个值两次编码出来的字节
   可能不同 —— `MonitorConfig.saveIfNotDefault()` 那种「和默认值比字节」的写法
   会随机给出错误答案。`GatewayConfigStore` 用了
   `encoder.outputFormatting = [.sortedKeys]`。`scripts/test-toolbox-layout.swift`
   里有 50 次重复编码的断言专门盯这个。**`MonitorConfig` 也有同样的隐患**，
   这次没动它（不在改动范围）。
2. **`PrimitiveButtonStyle.Configuration` 没有 `isPressed`** —— 它的
   `Configuration` 只有 `trigger`。要做按压反馈必须用普通 `ButtonStyle`
   （`configuration.label` + `configuration.isPressed`）。第一版写成
   `PrimitiveButtonStyle` 直接编译不过。
3. **sheet 还在开着的时候不要换 selection**。会让 `ToolboxView` 从视图树里
   被摘掉，sheet 的 `onDismiss` 拿不到状态。改成：免责弹窗同意后只记
   `pendingSelection`，真正的跳转放在 `.sheet(onDismiss:)` 里做。
4. **`GatewaySettingsView` 里弹 `ProviderListView` 要套 `NavigationStack`**。
   `ProviderListView` 里有 `NavigationLink`（进 `ProviderEditView`），
   没有 `NavigationStack` 的话那个 link 推不动。
5. **工具箱页不做重 IO**。「共 N 个进程」用的是裸 `proc_listpids`
   （0.1 毫秒级，本机实测 633 个进程耗时 0.0000–0.0001 秒），
   **不是** `ProcessInventory.snapshot()` —— 后者要对每个进程跑 proc_pidinfo +
   proc_pidpath + 读 nice，历史要 4~5 秒，放在这一页会卡住整页。
6. **置顶组的顺序 = 操作顺序**。取消置顶的卡片落到未置顶组**末尾**（不是原位），
   规则简单可预测。副作用：置顶→取消置顶之后顺序不再是 canonical 顺序，
   「重置排序」按钮仍然可用（`isDefault` 为 false）。
7. **`ToolCard` 永不使用 `.disabled`**。「助手未就绪」只改状态徽章
   （橙色）+ 降级图标，进了页面还能看、只是按钮不可用（`NiceView` /
   `HostsView` 的既有约定）。网关那张卡更不能 disabled ——
   「点了弹免责」正是它的入口。
8. **pin 按钮不能放进卡片 Button 的 label 里**。SwiftUI 里嵌套 Button 行为
   未定义，VoiceOver 也会把两者合成一个元素。`ZStack` 的子视图顺序必须是
   [卡片 Button, pin Button]：后画的在上层 → pin 抢鼠标命中；
   VoiceOver 焦点按视图树顺序 → 卡片先、pin 后。
9. **未置顶时 pin 按钮 `opacity(0)` 但仍占位**，且加了
   `.accessibilityHidden(true)` —— 看不见的按钮不该出现在 VoiceOver 焦点序列里。
   `.opacity` 不影响命中测试，所以鼠标仍能悬停显示。
10. **网关的 `authToken` 存在 UserDefaults 里**。它是网关自己的访问令牌，
    不是厂商 API Key（那些在 Keychain）。如果把监听地址改成 0.0.0.0，
    这个 token 就是唯一的防线 —— 所以它不应该复用厂商 key 的存储位置，
    但也不能当 API Key 那样看待。
11. **`GatewayConfig.load()` 在 `GatewayController.init` 里调用**。`init` 是
    `private` 且不能抛错，所以配置加载失败时静默回落到 `.default`，
    不影响单例创建。

### 有效性：免责申明的「同意」不代表网关功能已验证可用

**免责弹窗里的「同意」只是一次法律 / 风险告知行为，不是功能验收。**
它确认的是「用户知道网关会在本机开端口、请求与 API Key 会经过这台电脑」，
**不代表网关的转发链路已经跑通、不代表各厂商的协议互转正确、
不代表流式转发稳定**。

**网关本身是实验性功能**，随时可能调整或移除，升级之后的行为也可能变化。
入口挂出来是为了让用户能用，不是因为它已经可靠。

本阶段只做了**接线**层面的修复（load 会调、配置会落盘、页面进得去、
免责拦得住）。转发层的正确性、各厂商 API 的实际连通性、
流式转发的边界情况，都**没有**被这次改动验证过。

### 自测覆盖

- `scripts/test-toolbox-layout.swift`：49 项断言（默认布局 4 + 置顶 5 +
  取消置顶 6 + 置顶顺序 2 + 全部置顶 4 + 读入归一化 5 + 空存储 2 +
  Codable 往返 2 + 布局持久化 4 + 免责状态 4 + 网关配置持久化 9 +
  JSON 键序稳定性 1 + 清理 1），全过。
  运行：
  ```
  swiftc DeepSleep/Views/ToolboxLayout.swift \
         DeepSleep/LLMGateway/Database/QuotaModels.swift \
         DeepSleep/LLMGateway/Database/GatewayConfigStore.swift \
         scripts/test-toolbox-layout.swift -o /tmp/tb-test && /tmp/tb-test
  ```
  测的是**真实源码**（`ToolboxLayout.swift` 不 import SwiftUI 就是为此）。
- `scripts/test-keepalive-url.swift`：44 项断言，全过（未受本次改动影响）。
- `xcodebuild -configuration Debug`：BUILD SUCCEEDED，零 error。
  本次新增 / 修改的文件零 warning。全量构建有 13 条 warning，
  全在 `DeepSleep/LLMGateway/` 与 `DeepSleep/Notifications/` 目录，是既有的
  （`StreamForwarder.swift` 的
  `no calls to throwing functions occur within 'try' expression`、
  `GatewayServer.swift` 的未使用变量、`ProviderEditView.swift` 与
  `UsageDetailView.swift` 的 `onChange(of:perform:)` 废弃警告），
  不在本次改动范围，没有去动。
- `python3 scripts/check-docs.py`：仍是基线那 3 项不一致，没有新增第 4 项。
- SF Symbol 存在性：17 个实际用到的 symbol 在本机 macOS 26 全部存在
  （`NSImage(systemSymbolName:)` 逐个验证）；`toolbox.fill` 与 `beaker.fill`
  确认不存在，确实避开了。

### 没做的：GUI 手测

按约定，工具箱页的界面渲染、置顶交互、免责弹窗的实际观感**没有**做
GUI 手测（不启动应用、不截图、不点按钮）。上面的结论来自编译、
纯逻辑自测与符号存在性验证。实际观感由用户本人手测。

---

## 保活改成每日定时 + 网关整块隐藏（2026-10-24，v1.8.2）

三件事一起做的：保活的调度模型从「固定间隔」改成「每天固定时刻 + 每周选几天」；
默认请求模板换成人话；LLM Gateway 整块从构建里摘掉，界面完全看不见。

### 保活：为什么不是「每隔 N 小时」

原来的模型是「锚点 = 上次实际发送时刻，间隔 N 分钟」。用户要的是另一回事：

- 订阅制的滚动窗口从「你上一次使用」起算。间隔模型下窗口边界跟着**实际
  发送时刻**往后漂 —— 早上 9 点第一次用，边界就卡在你想工作的时段中间。
- 「每天定时」把边界钉死在墙上：配了 09:00，窗口就从 09:00 整点起算，
  在下一个时刻之前你一直待在同一个窗口里。
- 「每周哪几天」用来表达「周末不用管」：那几天不发，窗口自然重置。

数据结构变了：

- `KeepAliveTask.intervalMinutes`（Int）→ `KeepAliveTask.schedule`
  （`KeepAliveSchedule`：`times: [KeepAliveTime]` + `weekdays: Set<Int>`）。
- `KeepAliveTime` 只精确到分钟，`Comparable`，`display` 给出 `HH:mm`。
- 星期用 `Calendar` 的编号（1 = 周日 … 7 = 周六），不另造一套。
- 默认：09:00 与 14:00，周一到周五。

### 旧数据迁移

v1.8.1 的任务存的是 `intervalMinutes`。不迁移的话解码直接失败、用户的任务
会全部消失。`KeepAliveStore.load()` 走 `LegacyAwareTask`（一个 `Decodable`
的影子结构），两个字段都 `decodeIfPresent`：

- 有 `schedule` → 新格式，直接用。
- 只有 `intervalMinutes` → 按「一天的步长」从 00:00 铺开。
  间隔 240 分钟 → 00:00 / 04:00 / 08:00 / 12:00 / 16:00 / 20:00，每天 6 次，
  与旧版的次数一致，只是边界从「跟着上次发送漂移」变成对齐整点。
- 间隔小于 1 小时时按小时铺：不然 1 分钟间隔会铺出 1440 个时刻。

`CodingKeys` 要**显式写出来**：一旦提供了自定义的 `init(from:)`，
编译器就不再合成 `CodingKeys` 了（编译期报错 `cannot find 'CodingKeys' in scope`）。

### 到点判定：三个坑

`pendingSlot` 的语义最终定成这样 —— 只看**当天**、只看**运行日**里的时刻：

1. **锚点是 `max(上次成功发送, 任务创建时间)`**。只看「上次发送」的话，
   新建一条任务会立刻去补发「三天前的 20:00」—— 那不是用户要的。
   任务存在之前的时刻一律不算欠账。
2. **不补发**（用户明确要求）。应用关了好几天再打开，那期间的时刻已经作废，
   等下一个整点再说。回看 8 天的实现会把「非运行日的时刻」和「几天前就作废的
   时刻」错当成待发，所以改成只看当天。
3. **非运行日一律不发**。任务只配周一 09:00，周日打开应用不该发。

`nextSlot`（找下一个**未来**时刻）仍然回看 8 天 —— 那是必要的：
只配周一时，今天的时刻过了，下一次要等到下周同一天。

### 退避的上限跟着改了

原来「冷却上限 = 用户配的间隔」。现在没有「间隔」了，上限改成
「到下一个计划时刻的距离」：只配了早上 9 点的话，下一个时刻是明天 9 点，
距离约 24 小时 → 退避阶梯（1/5/15/30 分钟）完全生效。

### 默认请求模板

原来只有一个 `ping`。模型不知道要做什么 —— 有的回一段解释，有的反问，
消耗和延迟都不可控。改成「测试消息，直接回复'ping'即可」。

### 网关整块隐藏

用户要求「完全隐藏，用户完全不知道有的状态」。做法：

- `ToolboxTool` 删掉 `aiGateway` case；`SidebarItem` 删掉 `tokenMonitor` /
  `gateway` / `modelSwitcher` / `aiGateway`；侧边栏的「LLM Gateway」段整段移除。
- `project.yml` 里 `DeepSleep/LLMGateway` 加进 `excludes` —— **不参与编译**。
  源码仍在仓库里（36 个 swift 文件），将来决定了去留再处理。
- `ToolboxView` 里免责弹窗那一整套（`GatewayDisclaimerView`、
  `pendingSelection` 延迟跳转、`isInactive` 降级）跟着删掉 —— 没有入口了，
  那条链路走不到。

验证：`nm` 查产物 dylib，`Gateway` 相关符号 **0 个**，`KeepAlive` 1990 个。
界面文案（本地 AI 网关 / LLM 网关 / Token 用量 / 模型 Provider）也查不到。

### 保活不再依赖网关

用户明确要求：网关后续可能随时关停或彻底移除，保活不能被它绑架。

原先保活借了网关三样东西，现在全部自带：

| 原来借的 | 现在 |
| --- | --- |
| `LLMGateway/Proxy/HTTPClient.swift` | `KeepAliveHTTP.swift`（`KeepAliveHTTPClient`） |
| `LLMGateway/KeychainStore.swift` | `KeepAliveKeychain.swift`（service `com.skyc8266.deepsleep.keepalive`） |
| `LLMGateway/Database/QuotaModels.swift` 的 `LLMGatewayError` | `KeepAliveError.swift`（`KeepAliveError`） |

Keychain service 也分开了 —— 之前保活复用网关的 service
（`com.skyc8266.deepsleep.llmgateway`），网关被移除时保活的凭据会跟着失效。
分开之后互不影响。

**新增 `scripts/check-keepalive-isolation.py`** 作为这条约束的守卫：

- 扫 `DeepSleep/AIKeepAlive/` 下所有 swift 文件，出现网关类型名就失败
  （`KeepAliveHTTPClient` 里的 `HTTPClient` 用负向 lookbehind 排除）；
- 检查保活自带的那几个文件都在；
- 检查 `project.yml` 里 `LLMGateway` 在 excludes 中；
- 检查网关源码仍在仓库里（现在是「隐藏」不是「删除」）。

负向自测：把 `KeepAliveError.swift` 里的 `enum KeepAliveError` 改成
`enum LLMGatewayError`，检查器退出码 1 并指到 `KeepAliveError.swift:17`；
还原后通过。

### 自测

- `scripts/test-keepalive-schedule.swift`：85 项断言，全过。
  重写过 —— 旧的那套全是间隔语义（`clampedInterval`、`nextDueDate`），
  现在测时刻归一化、星期归一化、星期文案、到点判定、星期过滤、
  「不补发」语义、旧格式迁移。
- `scripts/test-keepalive-url.swift`：URL 拼接照旧，新增归一化与解码的断言。
- `scripts/test-keepalive-backoff-timing.swift`：18 项断言，全过。
  场景按「时刻」重写 —— 原来靠「间隔配 1 分钟把冷却上限压平」来测退避，
  那个手法在新模型下不成立了。
- `scripts/test-toolbox-layout.swift`：去掉了网关的断言，工具数从 5 变 4。
  新增一条：旧存储里的 `aiGateway` 会被归一化丢掉。
- `scripts/test-toolbox-gate.swift`：原本测「网关免责」链路，网关不可见后
  那个链路走不到了，改成测「网关确实不可见」+ 保活的持久化性质。
- `xcodebuild -configuration Debug`：BUILD SUCCEEDED，零 error。
- `python3 scripts/check-keepalive-isolation.py`：全过。

## 应用图标换成月相表盘（2026-10-27）

### 做了什么

`scripts/make-icon.py` 整个重写，构图从「月牙 + 星星」换成「月相表盘」：

- 深蓝夜空圆角方形做底，蓝色玻璃表盘偏左下，一枚金色月牙从盘后探出、压住盘缘。
- 12 根小时刻度，时针指向 10 点、分针指向 2 分。
- 配色：夜空 `#0B1132`→`#261C50`，盘面 `#94BEFF`→`#2A4294`，
  月牙 `#FFFBE9`→`#F3C66A`，指针 `#FFEAA8`。
- `docs/images/icon.png`（README 顶部那张）改由同一个脚本产出，
  与 `AppIcon.appiconset/icon_512x512.png` 逐字节一致（sha256 相同）。

### 为什么是指针指向 10:10 而不是具体时刻

最初的设计是时针指 11 点（入睡）、分针指 7 点（唤醒），想让图标本身
说出「睡眠时段由我调度」。实测下来这个想法在小尺寸下不成立：

- 两针都朝左时，32px 下读起来是一个箭头，不像钟。
- 换成 11:00 两针重叠，16px 下糊成一团。
- 10:10 的展开姿态在 16px 下两针仍分得开，一眼读成「钟」。

具体时刻交给 App 里的功能说明，图标只负责让人认出这是个管睡眠的时钟。

### 没动的与原因

- **菜单栏图标没换**，仍是 SF Symbol `moon.zzz.fill`。菜单栏按钮是
  模板图（单色，随明暗主题反色），与应用图标是两套渲染路径，
  强行统一会把菜单栏那一点位置塞进复杂图形。
- **没有单独的 Release**。这次只换图标，没有功能变化，单独发一版
  只会在更新日志里留下一条「换了张图」。图标随下一个版本一起走。

### 这次改动留下的坑 / 注意事项

- **月牙必须整体画在 824x824 圆角方形内**。第一版把月牙放在框外，
  alpha bbox 是 `(0, 0, 1024, 1024)`，导出后被系统裁掉一角。
  现在所有图层最后都与圆角方形遮罩求交，bbox 稳定在 `(47, 47, 465, 465)`。
- **发光的 alpha 必须取自挖洞之后的月牙**。直接模糊一个完整的圆，
  会在月牙缺口处残留一个灰色圆盘（深色背景上非常明显）。
  这条在旧版脚本的注释里就有，重写时保留。
- **构建产物要带 `-derivedDataPath build`**。不带这个参数时
  xcodebuild 会把产物写到别处，`build/Build/Products/` 下的
  `AppIcon.icns` 会保持旧版本，看不出图标有没有生效。

### 自测覆盖

- `python3 scripts/make-icon.py`：生成 10 张 PNG + `docs/images/icon.png`。
- 一致性：`sha256(icon_512x512.png) == sha256(docs/images/icon.png)`，
  实测均为 `fe510afe89934f46…`（前 16 位）。
- 尺寸：10 张 PNG 的实际像素与 `Contents.json` 声明逐条对上
  （16/32/32/64/128/256/256/512/512/1024）。
- alpha bbox `(47, 47, 465, 465)`，落在 824 圆角方形内。
- `xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep
  -configuration Debug -derivedDataPath build build`：BUILD SUCCEEDED。
  产物 `AppIcon.icns` 67537 字节，`iconutil -c iconset` 解出 4 张，
  尺寸 16/32/128/256，内容为新图标。
- `python3 scripts/check-docs.py`：全部一致。
- `python3 scripts/test-check-docs.py`：19 项通过，0 项失败。

### 未验证

- 没有在真实 Dock 与访达里看过。macOS 26 起系统会给应用图标叠一层
  液态玻璃材质，实际观感可能与生成图有出入，需要装到本机肉眼确认。
- 没有做深色/浅色/单色（tinted）appearance 变体。
  当前 Asset Catalog 只有默认一套，深色模式下由系统自动处理。


## 温度监控 + 风扇控制 + 自定义告警规则 + 外部磁盘防休眠 + 排定唤醒增强（2026-10-27，v1.9.0）

### 做了什么

- **温度监控页**（`DeepSleep/Views/ThermalView.swift`）。温度走 IOHID 私有温度事件通道
  （`PrimaryUsagePage 0xFF00` / `PrimaryUsage 5`），**普通用户进程就能读**，不需要特权助手。
  实测本机命中 132 个 HID 服务，其中 38 条是有效温度读数，去重后 33 个传感器名。
- **风扇控制页**（`DeepSleep/Views/FanControlView.swift`）。三种模式：交给系统 / 固定转速 /
  按规则调速。规则三要素就是用户提的三个字段：目标风扇、最低温度、最高温度
  （`FanMode.rule(targetFan:minTempC:maxTempC:)`），中间线性插值到该风扇的
  `[minRPM, maxRPM]`。
- **告警规则页**（`DeepSleep/Views/AlertRulesView.swift`）。指标覆盖 CPU 使用率、
  内存使用率、单进程内存、CPU 温度、磁盘使用率；条件连续满足设定时长才触发。
- **外部磁盘防休眠**。`AssertionKind.preventDiskIdle` → `kIOPMAssertPreventDiskIdle`。
  与其它 assertion 不同，它**不需要 root**（实测普通进程创建成功，`pmset -g assertions`
  里能看到 `PreventDiskIdle`，释放后消失）。
- **排定唤醒增强**（`DeepSleep/Core/ScheduledWakeManager.swift`）。多条一次性 + 循环排定，
  按条精确取消，不再用 `pmset schedule cancelall`。
- **90°C 强制最大转速**（用户硬要求）。应用侧与助手侧**各自独立判定**。
- **免责声明门禁**（用户硬要求）。助手侧独立持久化并拒绝一切写 SMC 的命令。

### 为什么温度不走助手

IOHID 的温度事件通道不需要 root。第一版实现走 SMC 读温度，普通进程直接
`IOServiceOpen("AppleSMC")` 会 **Bus error: 10**（实测退出码 138）——
所以 SMC 只能留在特权助手里，而温度没必要。温度留在应用侧带来两个好处：
这一页在助手没装、没启动、没授权时**完全可用**，也不会因为助手版本不匹配而没有数据。

### 为什么免责声明要在助手侧也存一份

应用侧的同意状态存 UserDefaults，拦不住「绕过界面直接构造协议包打助手」——
socket 就在 `/var/run`。风扇写入是本项目风险最高的功能（写错可能让风扇停转），
所以门禁必须落在**执行点**：助手自己持久化一份同意状态
（`/var/db/deepsleep/fan-disclaimer.json`，目录 0700、文件 0600、owner root），
每次真正写 SMC 之前自己查一遍。两条链路各存一份，互不信任。

### 90°C 兜底为什么两侧都要有

助手侧独立执行、不依赖应用是否还活着：应用崩了、被强杀、租约断了，
helper 依然能自己读温度、自己判断、自己写 maxRPM。紧急状态下**任何降速意图一律拒绝**
——包括「交回系统」「按规则调速」「更低的目标转速」。等值或更高放行
（应用可能也在按同一条规则拉满）。

温度回落到阈值以下后仍保持 60 秒再恢复原模式。冷却是为了避免温度在阈值附近
抖动导致风扇反复启停 —— 听起来像在喘气，实际也增加噪音和机械磨损。

### 没动的与原因

- **SMC 风扇写入的真实写入路径没有在真机上跑过**。`docs/SMC.md` 自己就写了
  此前从未完成过一次真实写入。本版把读写实现补齐并做了编译期与纯逻辑层验证，
  但「写下去风扇真的转」这件事仍然没有端到端验证过 —— 需要装上新版助手后手测。
- **没有把风扇规则持久化到磁盘**。`FanMode.rule` 目前只存在于运行期状态里，
  重启后规则消失。用户明确要求的三要素都在模型里，但持久化没做 ——
  这是有意留下的缺口，不是不小心。
- **没有做深色模式与 VoiceOver 的逐项核对**。界面用了语义字体与系统色，
  理论上自适应，但没有逐个控件在深色下截图确认。
- **`docs/SMC.md` 没有改动**。它是逆向分析报告，不是本项目的实现文档。

### 这次改动留下的坑 / 注意事项

- **`IOHIDEventGetFloatValue` 在 arm64 上必须按 `c_double` 读**。用 `c_float`
  会只取到 FPR 的低 32 位，所有读数变成 0 —— 表现像「传感器没数据」，
  实际是类型错。上一版 CPU 温度一直读不到就是这个原因。
- **IOHID 一次会返回 132 个服务，其中 94 条读数恒为 0**。那些是电压/电流/角度/
  加速度通道，不是温度。过滤规则是「读数 > 0.5 才算温度」，负值同理无效。
  过滤放在 `ThermalMonitor` 一处，界面不重复实现。
- **`pmset schedule cancelall` 不能用**。排定是系统共享资源，闹钟、备份工具
  都在用，取消全部会误伤别的程序。改成按「类型 + 时间」精确定位单条。
- **普通进程读 SMC 会 Bus error**。所有 SMC 读写必须留在 root 助手里。
- **`Result<T, String>` 编译不过**。`Result` 的失败类型必须满足 `Error`，
  裸 `String` 不行。排定管理器改用 `ScheduledWakeError`。
- **`AlertRule.init` 的参数叫 `comparison` 不是 `operator`** —— `operator`
  是 Swift 关键字，属性名要用反引号声明，初始化参数名则换成了 `comparison`。
- **`AlertRuleEngine.onTrigger` 只能有一个消费者**。监控协调器用它派发通知，
  告警规则页用它记历史会互相顶掉。现在引擎有独立的观察者列表
  （`addTriggerObserver` / `removeTriggerObserver`），界面走观察者。
- **`scripts/test-idle-time.swift` 的空闲阈值原来定错对象**。`idleSeconds()` 测的是
  全系统空闲，循环里一共睡了 0.5 秒，原来的 100ms 阈值会被系统噪声打中
  （实测 0.11~0.12 秒，机器一忙就红）。改成 300ms —— 仍是累加量（0.5 秒以上）的一半，
  重置坏掉照样被抓。变异测试确认过：把 `fireEvent` 改成空操作后断言报 1.2 秒，红。

### 自测覆盖

- `bash scripts/run-all-tests.sh`：**642 项断言通过，0 脚本失败**（26 个脚本）。
  其中新增：`fan-models`(35) / `fan-control`(67) / `alert-rules`(64) /
  `disk-idle-assertion`(7)。
- `scripts/test-fan-control.swift` 67 项：温度→转速线性映射、滞回、下发节流、
  90°C 兜底状态机（触发 / 冷却 / 解除 / 解除后恢复原模式）、免责声明门禁、传感器分组。
- `scripts/test-alert-rules.swift` 64 项：持续时间判定、条件中断重新计时、
  5 分钟冷却、指标缺失处理、持久化往返、契约字段名、观察者与 `onTrigger` 并存。
- `scripts/test-disk-idle-assertion.sh` 7 项：创建 → `pmset -g assertions` 确认系统登记
  → 释放 → 确认消失。
- `scripts/test-fan-models.sh` 35 项：编解码往返（含中文、`|`、`,`、`%` 转义）、
  可写风扇判定、90°C 判定边界。
- 变异测试两处：观察者派发去掉 → 告警规则测试红 2 项；
  `fireEvent` 改成空操作 → 空闲测试报 1.2 秒、红。
- `xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep -configuration Debug
  -derivedDataPath build build`：BUILD SUCCEEDED，0 error。
- `python3 scripts/check-docs.py`：全部一致。

### 未验证

- **风扇转速没有在真机上写入过**。编译通过、纯逻辑测试通过，但 SMC 写入路径
  没有端到端跑过一次。需要装上新版助手后手动验证。
- **90°C 兜底没有在真机上触发过**。触发路径是纯逻辑测的（状态机 + 写入调用），
  真机上的温度读数与写入的配合没有验过。
- **界面没有在真实窗口里逐页看过**。三个新页面是按 `docs/ui-spec-thermal-fan.md`
  写的规格实现的，规格本身没经过渲染验证。

## 应用图标重画：月相表盘 → 单体月牙（2026-10-28，v1.9.1）

### 做了什么

`scripts/make-icon.py` 整个重写，构图从「月相表盘」换成「单体月牙」：

- 深蓝紫夜空做底（`#08112C` → `#101B48` → `#26144C`），一枚冷蓝→淡紫渐变的月牙
  （`#EEF6FF` → `#9AC0FF` → `#CE92FF`）偏右居中。
- 月牙外缘一道白色亮边（`mask - 腐蚀` 求出边界环，再与「外圆减挖洞圆」求交，
  只保留外缘那一侧），月牙下方一层很淡的投影（`#050718`，模糊 26、偏移 20）。
- 背景撒三颗星，仅此而已。

### 为什么上一版「很丑」

不是配色的问题，是**放了两个主体**：

- 钟是白天的符号，月亮是夜晚的符号，语义互斥；两个大圆叠在一起没有主次。
- 月亮被钟盘的边缘啃掉一块，缺口的暗色和盘缘的蓝挨在一起，糊成一坨脏色。
- 金色指针是月亮的配色，却压在蓝色盘面上。
- 12 根刻度 + 8 颗星 + 辉光，细节太多。图标在 Dock 里只有 32~64px 可看，
  刻度会变成毛刺、指针会糊成黄斑。

图标在 Dock 尺寸下只有一个主体能活下来，所以这一版只留月牙。

### 为什么去掉光环

试过给月牙外面加一圈很淡的环。512px 下好看，32px 下糊成一圈灰边 —— 比没有更脏。
macOS 图标的体积感靠**边缘反光 + 投影**撑，不靠装饰圈。所以最后是「亮边 + 投影」。

### 试过但弃掉的方案

- **昼夜过渡圆**：上半白昼下半夜色，中间一条正弦晨昏线。渲出来像个发橙的桃子，
  完全读不出昼夜，弃。
- **暖色版**（同一构图，月牙改奶油金 `#FFFCF0` → `#FFE9BA` → `#F7C580`）：
  保留在 `make-icon.py` 的 `PALETTES["warm"]` 里，换配色只改 `DEFAULT_PALETTE` 一个常量。

### 没动的与原因

- **菜单栏图标没换**，仍是 SF Symbol `moon.zzz.fill`。菜单栏按钮是模板图
  （单色、随明暗主题反色），与应用图标是两套渲染路径。
- **`AppIcon.appiconset` 的 `Contents.json` 没动**。文件尺寸声明本来就对，
  变的只是 PNG 内容。

### 这次改动留下的坑 / 注意事项

- **月牙的 alpha 必须先挖洞再参与运算**。直接模糊一个完整的圆，会在月牙缺口处
  残留一个灰色圆盘，深色背景上非常明显。这条上一版脚本的注释里就有，保留。
- **亮边只取外缘**。`mask - 腐蚀` 得到的是整圈边界环，直接用会让挖洞那一侧
  也亮起一条边，月牙看起来像被描了双线。要再与「外圆减挖洞圆」求交。
- **`Image.load()` 的类型标注是 Optional**，Pyright 会报「Object of type None is not
  subscriptable」。加一行 `assert px is not None`。
- **构建产物要带 `-derivedDataPath build`**。不带这个参数时 xcodebuild 会把产物写到
  别处，`build/Build/Products/` 下的 `AppIcon.icns` 会保持旧版本，看不出图标有没有生效。
- **`iconutil -c iconset` 解出来只有 4 张**（16 / 32 / 128 / 256）。这是这个工程的
  正常产物形状，不是漏图 —— 上一版的 notes 里记的也是 4 张。

### 自测覆盖

- `python3 scripts/make-icon.py`：生成 10 张 PNG + `docs/images/icon.png`。
- 一致性：`sha256(docs/images/icon.png) == sha256(icon_512x512.png)`，
  实测均为 `fcea55e1aeb505dc…`（前 16 位）。
- 尺寸：10 张 PNG 的实际像素与 `Contents.json` 声明逐条对上
  （16/32/32/64/128/256/256/512/512/1024），不一致的文件数 0。
- alpha bbox `(100, 100, 925, 925)`（1024 画布），正好落在 824 内容框内；
  四个角的 alpha 为 0，中心为 255。右边多 1px 是 PIL `rounded_rectangle`
  的端点包含行为，与上一版一致。
- `xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep
  -configuration Debug -derivedDataPath build build`：BUILD SUCCEEDED。
  产物 `AppIcon.icns` 43070 字节，`iconutil -c iconset` 解出 4 张，
  逐张与 Asset Catalog 的源 PNG 比对：平均通道差 0.02、最大 3
  （PNG 重编码的舍入），与旧版图标的平均通道差是 102.93 —— 确认产物是新图标。

### 未验证

- 没有在真实 Dock 里看过。macOS 26 起系统会给应用图标叠一层液态玻璃材质，
  实际观感可能与生成图有出入，需要装到本机肉眼确认。
- 没有做深色/浅色/单色（tinted）appearance 变体。Asset Catalog 只有默认一套，
  深色模式下由系统自动处理。
