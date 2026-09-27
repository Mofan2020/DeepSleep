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

## 后续可做

- 分发用的开发者签名与公证流程
- 跨零点时间段规则的边界测试（已有实现，缺自动化测试）
- 规则与 assertion 状态的持久化恢复（当前每次启动从空白开始）
