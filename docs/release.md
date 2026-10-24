# 发布流程

从「代码改完」到「用户收到更新」的完整步骤，以及出问题怎么退回去。

---

## 一、先理解：发布之后会发生什么

这是决定「发布要做什么」的前提。

```
你发一个 Release（比用户当前版本高）
        │
        ▼
用户的应用在下次启动约 15 秒后检查到新版本
        │
        ├─ 校验通过 → 下载 → 退出自己 → 临时脚本替换 .app → 重开
        │
        ▼
新版本的应用启动
        │
        ├─ 发现「应用包内的助手」与「系统里装着的助手」内容摘要不同
        │
        ▼
应用通过 socket 发给助手 updateSelf
        │
        ├─ 四条校验（来源路径 / bundle id / 摘要 / 不与当前相同）
        │
        ▼
助手写出替换脚本 → 让脚本在它退出后替换自己的二进制 → launchd 重新拉起
        │
        ▼
完成。**全程不需要用户输任何密码。**
```

**所以正常情况下，发布时不需要做任何与助手相关的操作** ——
助手的更新是自动的。

---

## 二、版本号规则

版本号是**应用自身更新的唯一判据**（"只有严格更高才更新"），所以它必须认真写。

在 `project.yml` 里：

```yaml
MARKETING_VERSION: "1.2.1"        # 版本号 —— 用户可见，决定是否更新
CURRENT_PROJECT_VERSION: "4"      # 构建号 —— 仅展示用，不参与任何判断
```

| 规则 | 原因 |
| --- | --- |
| **必须比上一个 Release 高** | 否则用户永远收不到更新（判据是严格更高） |
| 用 `X.Y.Z` 三段数字 | 比较逻辑按数字段逐段比。`1.10.0 > 1.9.0` —— 字符串比较会判反 |
| **不要用带字母的版本号** | `1.2.1-beta` 之类解析不了，会被当作「无法判断」而**静默不更新** |
| 构建号随便，不用管 | 它不参与判断，改不改都一样 |

> 忘了改构建号没关系。忘了改**版本号**才是问题 —— 用户会收不到更新，
> 而且不会有任何错误提示（因为「没有更新」和「版本一样」是同一个结果）。

**助手没有版本号，也不需要。** 它的更新判据是两份二进制的内容摘要，
完全自动推导。你改没改版本号都不影响助手更新。

---

## 三、发布步骤

### 第 1 步：确认干净

```sh
cd ~/Documents/MyProjects/DeepSleep
git status --short          # 应该没有未提交的改动
python3 scripts/check-docs.py
python3 scripts/test-check-docs.py     # 确认校验器本身还能拦
```

### 第 2 步：改版本号

编辑 `project.yml` 的 `MARKETING_VERSION`。**这是这整套流程里唯一必须手动改的东西。**

### 第 3 步：跑全部验证

```sh
xcodegen generate

# Debug 与 Release 都要构建（Release 才会暴露某些警告）
xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Debug -derivedDataPath build build -quiet
xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Release -derivedDataPath build build -quiet
# 期望：零 error、零 warning

# 四个回归测试
swiftc Shared/Version.swift scripts/test-version-compare.swift -o /tmp/t1 && /tmp/t1
swiftc Shared/PMSetOutput.swift scripts/test-pmset-parse.swift -o /tmp/t2 && /tmp/t2
swiftc Shared/HelperProtocol.swift DeepSleepHelper/SelfUpdate.swift \
       scripts/test-selfupdate.swift -o /tmp/t3 && /tmp/t3
swiftc Shared/ProcessInventory.swift Shared/ProcessGuard.swift \
       Shared/ProcessPriority.swift Shared/TerminationReport.swift \
       scripts/test-process-guard.swift -o /tmp/t4 && /tmp/t4
# 期望：四个都「测试结论: 全部通过」

# 端到端自检
open -a "build/Build/Products/Release/Deep Sleep.app" \
     --args --wait 8 --status --blockers --rivals --helper-version
```

### 第 4 步：更新 `release-notes.md` 并提交打 tag

**先更新 `release-notes.md`** —— 仓库根目录这个文件就是 CI 创建 Release 时用的正文
（`body_path`）。打 tag 之前先把它改成这一版的发布说明：

```sh
$EDITOR release-notes.md
```

**这一步不能省。** CI 只在文件不存在时才写占位标题，文件存在就用文件里的内容 ——
忘了更新，Release 页面就会挂着上一版的说明。写法照第 8 步「发布说明怎么写」那几条。

然后提交并打 tag：

```sh
git add -A
git commit -m "……"                      # 中文，说清改了什么、为什么

git tag -a v1.2.2 -m "v1.2.2：<一句话摘要>"
```

**tag 名要与 `MARKETING_VERSION` 一致（带 `v` 前缀）。**
不一致不会立刻出问题（版本判断读的是 zip 里的 `Info.plist`，不是 tag），
但会让人困惑，而且 `versionMismatch` 校验会拒绝安装。

### 第 5 步：推送

```sh
git push origin main
git push origin v1.2.2
```

**从 v1.4.0 开始，第 6–8 步由 GitHub Actions 完成。** `.github/workflows/release.yml`
监听 push tag（`v*`），在 macos-14 runner 上跑 `scripts/build-release.sh`，
用 ditto 解压 + codesign 校验后用 `softprops/action-gh-release` 创建 Release。

**runner 建的 Release 一律是 pre-release。** 这是硬规则：版本发出去之前必须先有人
实测确认没有严重问题，确认之后再手动翻成正式版：

```sh
gh release edit v1.2.2 --prerelease=false
```

手动 `gh release create` 仍可用作兜底（例如 Actions 失败时），同样要标
`--prerelease`，实测之后再翻。

跑完后用 `gh release list` / `gh api repos/:owner/:repo/releases` 验证资产：

```sh
gh release view v1.4.0
shasum -a 256 build/release/DeepSleep.zip   # 与 .sha256 文件一致
```

### 第 6 步：打包发布资产

```sh
bash scripts/build-release.sh
```

它会构建 Release、打包成 `build/release/DeepSleep.zip`（**文件名固定，不能改** ——
自动更新按这个名字找资产），并生成 `DeepSleep.zip.sha256`。

### 第 7 步：验证资产内容

```sh
cd build/release
rm -rf /tmp/ziptest && mkdir -p /tmp/ziptest
ditto -x -k DeepSleep.zip /tmp/ziptest
ls -1 /tmp/ziptest
# 期望：顶层直接是 "Deep Sleep.app"（不是一堆散文件）

/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "/tmp/ziptest/Deep Sleep.app/Contents/Info.plist"        # 应与版本号一致
ls "/tmp/ziptest/Deep Sleep.app/Contents/Library/PrivilegedHelperTools/"
codesign --verify --deep --strict "/tmp/ziptest/Deep Sleep.app"
shasum -a 256 DeepSleep.zip                                # 应与 .sha256 文件一致
```

**这一步不能省。** zip 结构错了，所有用户的自动更新都会失败。

### 第 8 步：建 Release

```sh
gh release create v1.2.2 \
   'build/release/DeepSleep.zip' \
   'build/release/DeepSleep.zip.sha256' \
   --title 'v1.2.2 — <一句话>' \
   --notes-file /tmp/release-notes.md \
   --prerelease
```

- **`--notes-file` 推荐用文件**，命令行里塞多行说明很容易出错
- **必须加 `--prerelease`**。发出去的版本要先经过实测确认没有严重问题，
  确认之后再翻成正式版（见第 5 步）：
  `gh release edit v1.2.2 --prerelease=false`
- 资产名必须是 `DeepSleep.zip`。改名字会让所有已发布的旧版本找不到更新

**发布说明怎么写**（README 的文字同理）：

- 说人话，直接列条目，一条一行：改了什么地方、怎么用。能删的字都删掉
- 只写用户需要知道的。不写根因、排查过程、自证式的验证结果 —— 那些放
  [notes.md](notes.md) 与 [gotchas.md](gotchas.md)
- 不用长破折号堆叠，不写「不仅仅是……而是……」这类对偶句，不靠加粗撑语气，
  不写表格来展示自己测得多好
- 目标是让用户十秒看完，并知道该不该升级

### 第 9 步：确认远端

```sh
gh release list
gh api repos/Mofan2020/DeepSleep/releases/latest --jq '.tag_name'

# 下载回来核对摘要
gh release download v1.2.2 --pattern 'DeepSleep.zip*' --dir /tmp/ghdl --clobber
shasum -a 256 /tmp/ghdl/DeepSleep.zip
cat /tmp/ghdl/DeepSleep.zip.sha256
# 三个摘要（本地、远端下载、随附文件）必须完全一致
```

---

## 四、发布检查清单

- [ ] `git status` 干净、`check-docs.py` 通过
- [ ] `test-check-docs.py` 通过（校验器本身还能拦）
- [ ] `MARKETING_VERSION` 比上一个 Release **更高**，且是纯数字三段式
- [ ] Debug 与 Release 构建**零 warning**
- [ ] 四个回归测试全过；**改过助手更新路径**时再跑 `bash scripts/test-helper-update.sh`
- [ ] 端到端自检跑过（不是只看编译通过）
- [ ] commit + tag（tag 名与版本号一致）
- [ ] `git push origin main && git push origin "$TAG"`
- [ ] `build-release.sh` 打包
- [ ] zip 解压验证：顶层是 `.app`、版本正确、内嵌助手在、codesign 通过
      （**用 `ditto -x -k` 解压**；`unzip` 会丢扩展属性，让 codesign 假报「封条无效」，见 gotchas 23）
- [ ] `gh release create` 带 zip 与 sha256
- [ ] 远端验证：`releases/latest` 指向新 tag、下载回来的摘要一致

---

## 五、怎么测试自动更新

「已是最新」只能证明**读到**了 Release，证明不了版本比较方向正确。
想完整测一遍，需要两个版本：

```sh
# 临时把版本降到比最新 Release 低一级
python3 - <<'PY'
path = "project.yml"
text = open(path).read()
text = text.replace('MARKETING_VERSION: "1.2.2"', 'MARKETING_VERSION: "1.2.1"')
open(path, "w").write(text)
PY
xcodegen generate && xcodebuild ... -configuration Debug ... build

open -a "build/Build/Products/Debug/Deep Sleep.app" --args --wait 6 --update-check
# 期望：更新检查 —— 发现新版本 v1.2.2

# 测完必须改回来并重建
```

两条路径都要看：

| 应用版本 vs 最新 Release | 期望输出 |
| --- | --- |
| 相等 | `已是最新版本（x.y.z）` |
| 更低 | `发现新版本 vX.Y.Z` |
| 更高（本地开发中） | `已是最新版本` —— **不会降级** |

> 测完**一定记得改回版本号并重建**，否则下一次打包出来的 zip 会是错的版本。

---

## 六、如何更新助手

**一句话：正常发版不需要做任何事。**

分三种情况：

### 情况 A：正常发版（包括改了助手代码）

**不需要任何操作。** 流程是自动的：

1. 你的新 zip 里带着新的助手二进制
2. 用户的应用更新到新版
3. 新应用发现「包内助手」与「已装助手」内容摘要不同
4. 自动发 `updateSelf`，助手自己替换自己

用户全程不需要输密码。

### 情况 B：助手是「不认识 `updateSelf`」的旧版

**需要用户手动重装一次**，之后永久自动。

判断办法：

```sh
open -a "build/Build/Products/Release/Deep Sleep.app" --args --helper-version
# 输出「是旧版助手，不认识自动更新命令，需要重新授权安装一次」→ 属于这种情况
```

重装方式：应用 →「完全控制」页 → **停用** → 再**启用**（一次管理员授权）。

> **注意**：重装会**清掉助手的日志文件**。如果正在排查问题，
> 先把 `/var/log/com.skyc8266.deepsleep.helper.log` 备份出来再重装。

### 情况 C：换了签名证书之后

**也需要重装一次。** 换了证书，二进制内容变了，摘要判据会发现不同 ——
按理说会触发自动更新。但如果旧助手本身不支持 `updateSelf`，
或者签名变化导致系统拒绝了替换，就得手动重装一次。

### 助手相关的排查命令

```sh
# 它是不是在跑
launchctl print system/com.skyc8266.deepsleep.helper | head -20
pgrep -fl "com.skyc8266.deepsleep.helper"      # 注意是点号分隔的进程名

# 装在哪个版本
open -a ".../Deep Sleep.app" --args --helper-version

# 它的日志（注意每行可能出现两次，见 maintenance.md）
tail -50 /var/log/com.skyc8266.deepsleep.helper.log

# 直接跟它对话
python3 scripts/helper-probe.py status
```

---

## 七、出问题怎么退回去

### 应用更新出问题

**自动更新不会破坏用户原有的应用。** 更新器脚本的逻辑是
「挪走旧的 → 放入新的」，任一步失败都回滚，并且**不会**在回滚分支里删目标路径。
最坏情况是「停在旧版本」。

真要撤回一个坏 Release：

```sh
gh release delete v1.2.2 --yes
git push origin :refs/tags/v1.2.2      # 删远端 tag
git tag -d v1.2.2                       # 删本地 tag
```

**已经在用户机器上升级了的部分不会自动回退** —— 自动更新只升不降（这是刻意的，
降级逻辑会导致来回替换的循环）。要让用户退回去，得发一个版本号更高的修复版。

> 这也是「版本号只能往上走」的原因：**没有降级通道**，
> 所以宁可多发一个修复版，也不要去发一个更低的版本号。

### 助手更新出问题

助手替换自己的脚本会先备份，替换失败会把备份放回去，不会留下半残状态。

实在坏了就手动重装一次（情况 B 的办法）。

---

## 八、版本历史

| 版本 | 主要内容 |
| --- | --- |
| 1.0.0 | 首次发布：三层防护、断言管理、自动化规则、菜单栏、Touch ID、特权助手 |
| 1.1.0 | 修复 `disablesleep` 读取误判（TAB 分帧）；外部活动观测；日志自动清除 |
| 1.2.0 | 应用自动更新；助手版本检测与自我更新；电源控制竞争者检测 |
| 1.2.1 | 助手判据改为内容摘要（去掉人工维护的构建号）；Release 拉列表以识别预发布；冲突只呈现不解决 |
| 1.3.0 | Siri / 快捷指令（App Intents）；`deepsleep://` URL 接口；快速退出（全局快捷键强杀选定应用及其子进程，含硬名单保护与助手侧独立重算） |
| 1.3.1 | 助手更新路径补上反馈：手动点击先弹框确认再更新，不再被「本次运行只自动试一次」的闸门静默吞掉；`--helper-version` 先探测再显示；新增 `--helper-update` 与助手更新端到端验证脚本 |
| 1.4.0 | 开机自启（LaunchAgent plist，默认开）；系统监控：CPU/RAM 持续超阈告警 Top 3 占用者，可冻结或终结；内存泄漏检测（窗口内 RSS 单调增长 + 累计 ≥ 50MB，红字置顶 + 系统通知）；完全卸载（一键撤销所有副作用）。助手协议升至 v2，新增 `getProcessStats` / `suspendProcesses` / `killProcesses`；旧助手收到新命令会回 `unknown command`，新应用会提示一键更新助手 |
| 1.4.1 | 删除内存泄漏检测（绝对阈值对应用启动 / 游戏加载误报太多）；CPU% 改为 whole-CPU 口径（100% = 全机所有核都用上）；新增「单进程 RAM 超阈」告警（默认 4 GB，可调）；监控设置切页自动落盘，不依赖「保存设置」按钮；最近事件实时刷新；完全卸载加「清应用配置」步（Prefs / Caches / AppSupport / Logs / Saved State） |
| 1.5.0 | LLM Gateway：Token 监控（14 家 LLM 平台余额 / 5h 窗口 / 周限额 / 重置倒计时统一展示，按量/订阅自适应）+ 本地 LLM 网关（127.0.0.1:15999，OpenAI ↔ Anthropic 双向格式转换，转发到任意 Provider，支持流式 SSE + vision + function calling + 用量统计）；SideBar 新增 3 个标签（功能默认关闭，Token 监控开关在 LLMGatewayFeature.tokenMonitor / LLMGatewayFeature.gateway） |
| 1.6.0 | 服务器模式：系统永不睡眠 + 5 秒后自动关屏锁屏 + 解锁后空闲 10 分钟再重复；期间系统监控仅告警不弹处理对话框。进程优先级（nice）工具：查看任意进程 nice、改任何非系统进程的 nice（走助手），系统进程一律拒绝，极端值（≤ -10 或 ≥ +15）需二级确认。Shared 新增 `ProcessPriority` + `RunningProcess.nice` 字段；协议新增 `sleepDisplay` / `lockScreen` / `getProcessNice` / `setProcessNice`；侧边栏新增「服务器模式」「进程优先级」两个标签 |
| 1.6.1 | 服务器模式锁屏路径修正：移除 `open -a ScreenSaverEngine`（那是屏保动画，不是锁屏），改为仅 `pmset displaysleepnow`；UI 提示用户需在系统设置 → 锁屏 → 立即要求密码勾上，macOS 关屏即等同锁屏。空闲计时修正：用 `IORegistryEntryFromPath` 读 `IOHIDSystem.HIDIdleTime`（纳秒）替代 `NSEvent.addGlobalMonitorForEvents`（后者需要 Accessibility 授权才回调，否则永远不刷新倒计时）。Nice 页面修「调整…」按钮不弹窗 bug（v1.6.0 按钮直接调 applyNice，未设 `pendingPid`，导致 `.alert` 永不触发）+ 重写为后台 actor 异步加载 + 路径 / bundle id 懒加载，UI 不再卡顿。新增 `Shared/IdleTime.swift` + `scripts/test-idle-time.swift` 单测 |
| 1.6.2 | 服务器模式空闲计时根本性修正：v1.6.1 的 `HIDIdleTime` 路径在服务器模式下不可信（DeepSleep 助手 + 主进程持 noidle 断言时 powerd 停止累加该计数器，实测 30 秒不动机器值在 0~1.5 秒之间反复跳），导致「倒计时永远不动 / 到点也不息屏」。改用应用层时间戳 + `CGEvent.tapCreate(.listenOnly, .headInsertEventTap)` 全局监听键盘 / 鼠标事件，每次事件来时把 `lastActivityAt` 重置为 `Date()`。开启服务器模式前必须获得 Accessibility 授权（`AXIsProcessTrustedWithOptions(prompt: true)`），未授权直接拒绝开启（不允许「开了但倒计时不动」的退化态）。新增 `scripts/test-cgeventtap.swift` 测 API 调用链；`scripts/test-idle-time.swift` 改为测应用层时间戳语义，承认 `HIDIdleTime` 在持有 noidle 时不单调。app 退出时若服务器模式在跑，会释放 CGEvent tap + 恢复 disablesleep |
| 1.6.3 | 服务器模式修两个阻塞 bug + 双空闲检测模式。bug 1：`performSleepAndLock` 开头 `guard phase == .starting` 把「倒计时到点」这条路径整个挡回，表现为首次 5 秒关屏正常、归零后不熄屏不锁定 —— 现在首次与超时共用同一函数、按来源分别校验。bug 2：归零时把 tick timer 停掉，导致「用户回来」没人监听、界面永远停在 0 —— 现在 tick 从开启跑到关闭全程不停，`locked` 阶段保持归零且不重复关屏，idle 掉回阈值以下即重新计时。新增空闲检测双模式（默认「内核空闲计时」`HIDIdleTime`，不需要任何授权；「事件监听」`CGEvent tap` 作为实验选项保留），UI 可切换并持久化。判定逻辑抽到 `Shared/ServerModeIdlePolicy.swift` 纯函数 + 新增 `scripts/test-servermode-fsm.swift`（15 项断言，含完整生命周期模拟） |
| 1.7.0 | 工具区两个新页：「Hosts 编辑」（读 / 写 `/etc/hosts`，管理「谁能改 hosts」白名单）+「Quarantine 属性管理」（扫描 / 清除目录下的 `com.apple.quarantine`，不动 symlink）。Hosts 写权限走助手（必须 root），助手基于调用方 uid + `hosts.editors` 白名单裁决，空白名单默认放行；写入前备份原文到 `/etc/hosts.deepsleep.bak`，写后强制 `root:wheel` + `0644`。Quarantine 操作走本进程 xattr，无需 root。Shared 新增 `HostsAllowedEditors` + `NicePageSize`；协议新增 `readHosts` / `writeHosts` / `listHostsEditors` / `setHostsEditors`，仍跑在 v2 协议上（运行 `helper-probe.py read-hosts / list-hosts-editors` 端到端验证）。Nice 页改造：分页（默认 20，可调 10–30，MonitorConfig 持久化）+ LazyVStack（解决 ~300 个 cell 滚动卡顿）+ 副标题默认显示可执行文件路径。CLI 新增 `--hosts list/read/write/allow` 与 `--quarantine scan/clear`；URL 新增 `deepsleep://hosts-read/hosts-write/hosts-editors/quarantine-scan/quarantine-clear`。新增 `scripts/test-nice-page-size.swift`（15 项）+ `scripts/test-hosts-allowed-editors.swift`（19 项） |
| 1.7.1 | Nice 页修三个 UX bug：(1)「调整…」按钮点了没反应 —— v1.6.1/v1.7 用 `.alert(_:isPresented:actions:)` 弹窗，actions 闭包里塞了 `Stepper`，SwiftUI alert 的 actions 只接受 Button 系控件，放 Stepper 整个 alert 被静默丢弃。改用 `.sheet` 弹独立的 `NiceAdjustSheet`（原生支持任意 SwiftUI 视图）。(2) 进程名被截断 —— 旧 `ProcessRow` 把名字塞进 HStack，旁边 nice 数字（width 40）+ 两个按钮 + Spacer 挤掉可显示宽度。改三行布局：名字（`.lineLimit(nil)` + `.fixedSize` 自动撑开）/ 路径副标题 / nice + 按钮，长名字不再丢信息。(3) 分页副作用 —— 旧 `pagedEntries` 是 computed property 里直接写 `currentPage = 1` 做钳制，每次 body 求值都触发 setter。钳制逻辑移到 `refresh()` / `query.onChange` / `pageSize.onChange` 三个明确时机，computed property 退化为纯计算；`PageBar` 翻页通过 `onPageChange` 回调写状态，加 `if newValue != currentPage` 防抖。Sheet 内同步附文本框直接输入 nice 值（极客场景，避开 Stepper 一次一格点 39 次的痛苦） |
| 1.7.2 | 五大新功能 + 自动更新优化 + Quarantine 增强。**退出清理开关**：`SleepController.preservesStateOnExit`（默认 false，持久化 UserDefaults）让用户退出 Deep Sleep 时不释放 assertion 与 disablesleep，进程退出后 helper 持有的 assertion 仍生效直到停用「完全控制」或重启；disablesleep 也保持生效；UI 在「完全控制」页加 toggle + 橙色警告。**邮件告警渠道**：新增 `EmailChannel`（NWConnection 直发 SMTP，支持 465 implicit TLS，明文 base64 鉴权）；配置（host/port/username/from/to/TLS）→ UserDefaults JSON，密码 → Keychain（独立 service）；UI「完全控制」页加完整配置表单 + 「发送测试邮件」按钮；`MonitoringCoordinator.sendEmailIfEnabled` 监听监控事件（overload / singleRAM / cpuTemp），`EmailThrottleStore` 按 key（overload / singleRAM-<pid> / cpuTemp-<int阈值>）独立冷却（默认 5 分钟）；`AutomationRule` 加 `notifyOnSatisfied`，`AutomationEngine` 在「未满足 → 满足」边沿触发邮件。**自动化三件套**：`AppRestartWatcher`（NSWorkspace.didTerminate 通知 → 跑配置的 `/bin/sh -c` 重启命令；过滤掉 DeepSleep 自己；5 秒节流保护；UI 「自动化」页加「应用退出即重启」section，从当前运行应用选择 + 删除）；`WeeklyRestartManager` + helper 新增 `installWeeklyRestart` / `uninstallWeeklyRestart`（写 `~/Library/LaunchAgents/com.skyc8266.deepsleep.weeklyrestart.plist` + `/etc/sudoers.d/deepsleep-weeklyrestart` 给用户 NOPASSWD 跑 `shutdown -r now`，launchctl bootstrap；UI 加星期 + 时刻 Picker，启用前必须 helper 已就绪）；`ScheduledCommand`（自写 5 字段 cron 解析，支持 `*`/`*/N`/`a-b`/`a,b,c`；30 秒评估一次；`Process` 跑 `/bin/sh -c` 当前用户身份；UI 加编辑器带 6 个预设 + 醒目「写错 `rm -rf /` 真的会删」警告）。**自动更新优化**：`UpdateError.isRetryable` 分类（network / emptyDownload / malformedRelease 重试，其余永久失败）；退避表 `[5s, 30s, 5min]`，失败时 phase 显示「N 秒后重试」并自动重试；`URLSession.bytes(for:)` 下载带进度，phase 加 `progress` 字段，UI 显示 `ProgressView`；`skipPrereleaseUpdates` 选项（默认 true，只装正式版）。**Quarantine 优化**：`Entry.isAppBundle` / `appContentsQuarantined` / `valueSegments`；`walk()` 检测 `.app` 时折叠成 1 条记录，内部文件数显示「包内另有 N 个」；`clearAppBundle` 递归清包内所有 quarantine；`Entry.detailDescription` 把 4 段 flag/timestamp/agent/UUID 全展示；`repairDamagedApp` 多方案（清 quarantine → ad-hoc 重签 `codesign --force --deep --sign -` → 全清 xattr `xattr -cr` → 系统设置引导），按可靠性递增，前 90% 场景第一步就够 |
| 1.7.3 | 系统监控页加实时状态显示 + 服务器模式下禁用「自动冻结 Top 3」。**实时状态卡**：`SystemMonitor.liveSnapshot()`（RAM% / CPU% / CPU 温度 / Top 3 进程）跑在 SystemMonitor 已有 3 秒 tick + 5 tick 一次 SMC 的同一通道上；新增 `Shared/DiskUsage` 走 `URL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])` 读根卷；UI 顶部 SectionCard「系统状态」四列（CPU / 内存 / 温度 / 磁盘）+ Top 3 列表，每秒 Tick 同步重读，不反向触发 IO。**服务器模式禁用 autoSuspend**：`MonitoringView.autoSuspendToggle` 用 binding get 锁死 false + set 早退 + `.disabled(sleep.isServerModeActive)`；关闭服务器模式后自动恢复原值。与 `MonitoringCoordinator.handle` 里的 server-mode 跳过冻结逻辑形成双保险（运行时 + UI 层）。**SectionCard 迁移**：`MonitoringView` 整页从 GroupBox 迁到 SectionCard（v1.7 整体迁时漏掉，本次补完），与 ControlView / UpdateView / AutomationView 风格一致 |
| 1.7.4 | CPU 温度告警暂不可用，等下次重写放出。**现象**：macOS 27.2 / M2 本机监控页 CPU 温度项始终不显示数字。**根因**：helper 端 `SMCTemperature.swift` 走 `IOServiceMatching("AppleSMC")` + `IOConnectCallStructMethod(selector-as-methodId)` 姿势（90 字节 `SMCParamStruct`），与 AlDente legacy code 同源；`kr = KERN_SUCCESS`、`output.result = 0` 表示无错，但 `output.keyInfo.dataType = 0` / `dataSize = 0` —— firmware 没填回任何 key 信息。`scripts/dump-smc-keys.swift` 跨姿势探针都返回同样结论：老姿势（`selector=0x2` + `data8` 子命令）→ `kIOReturnUnsupported`；AlDente 姿势（`selector=2/5/8/9` 作为 methodId）→ 全部 by-index `kIOReturnNotFound`，直接读 `#KEY` 也 `kIOReturnNotFound`；`powermetrics --samplers smc` 在 macOS 26+ 已移除该 sampler。**决定**：「等用户重写完再放出」。**做了什么**：UI 把 CPU 温度 metric 改成「等待后续更新」，toggle 锁死关闭、slider 禁用；`SystemMonitor.checkCPUTemperature` 加 `sample.hasAnyReading` 早返回（helper 端拿到 sample 但三字段全 nil 时落盘 `cpuTempEnabled = false`，旧用户首次启动自动一致地走「关闭」分支，不再每 15 秒白耗一次 SMC read）；helper 端算法骨架保留（stride = 80 验证通过）未删，下次直接扩 helper 实现即可，UI 不需要再动；`Shared/CPUTemperatureSample.swift` 不动。**没动的与原因**：没换 helper 端算法（下次重写时只扩 helper）；没把 `cpuTempEnabled` 默认从 true 改 false（自动关闭逻辑足够，且保留 true 让升级后老用户配置不丢）；没删 MCP/Helper 的 `getCPUTemperature` 协议命令（当前仍能正确响应 `success=true`，应用走「无数据」分支，保留对将来恢复有好处）。**自测**：`scripts/test-cpu-temperature-decode.swift` 25/25 项解码断言 + round-trip 双项全过；端到端功能未回归 |
| 1.8.0 | 工具箱重构 + AI 保活 + AI 网关试验性开放。**工具箱**：侧边栏「工具」段收成单个「工具箱」入口，页内 `LazyVGrid(adaptive(minimum: 280, spacing: 14))` 排 5 张卡（进程优先级 / Hosts 编辑 / Quarantine / AI 保活 / AI 网关），卡片右上角 pin 按钮 + 右键菜单 + 「重置排序」三个入口置顶，排序持久化在 `toolbox.layout.v1`（`{pinned, rest}` 结构）。**进入方式走 selection 切换而非 NavigationLink 推栈** —— `NavigationSplitView` 的 detail 列没有 `NavigationStack`，推栈要把整列包起来，会影响应用里每一个页面的导航行为；副作用最小的做法是三个旧工具页一行都不用改（导航标题仍由 `selection.title` 提供）。工具箱页宽 980（`pageLayout(maxWidth:)` 加带默认值的参数，其他页面零改动），否则净宽 716 只能排 2 列。工具箱只读轻量状态（`helperState.isReady` / 网关运行状态 / 保活引擎状态），不触发进程快照（nice 的快照历史上要 4~5 秒，放这页会卡住整页）。**AI 保活**（新模块 `DeepSleep/AIKeepAlive/`）：定时向指定 AI 服务发一条超短请求，维持订阅制服务的滚动使用窗口。多任务，各自配 baseurl / 协议（openai / anthropic）/ 模型名 / API Key / 请求内容模板 / 发送间隔（分钟，1~1440，默认 240）/ 启用开关。API Key 存 Keychain（复用 `KeychainStore`，account 前缀 `keepalive.<uuid>` 隔离，**未新建 service** —— 改了 service 用户已有条目全部失效）；模型列表可从服务端 API 拉取；请求内容可自定义且内置默认模板可一键还原。**失败重试策略**：只有成功才推进 `lastRunAt` 锚点（失败时推进会让配 240 分钟的任务失败一次就变 480 分钟才重试），并加退避阶梯 1/5/15/30 分钟、冷却上限不超过用户自配间隔、成功即清零。**AI 网关**：补完 v1.5.0 留下的半成品 —— (1) `GatewayController.load()` 从未被调用，`providers` 永远空数组，Provider 列表页 / 模型切换页 / 配额页全是空的；改为幂等的 `ensureLoaded()`；(2) `gatewayConfig` 只在 `@Published` 内存里，改端口/鉴权重启就丢；新增 `GatewayConfigStore` 持久化到 `gateway.config.v1`（`GatewayConfig` 已是 Codable，仿 `MonitorConfig` 模式），写盘用 `.sortedKeys`（JSONEncoder 对 struct 的键序不固定，不加会导致「与默认值一样吗」的判断随机出错）；(3) `GatewaySettingsView` 写好了但无任何引用，设置页进不去；改为工具箱卡片入口，并加「Provider（N 个）」行；(4) `LLMGatewayFeature` 开关没有 UI 入口，等于把功能永久锁死；废弃该 gate，入口改为「工具箱卡片 + 已同意免责申明」。**免责申明门禁**：首次进入网关弹 `.sheet`（不用 `.alert` —— 正文四段，alert 的 message 放不下也不可滚动）列明「本机开端口、请求内容与 API Key 都经过这台电脑、API Key 在钥匙串、默认只监听 127.0.0.1、试验性功能随时可能改」；两个 UserDefaults key（`llm.gateway.disclaimerAccepted` + `llm.gateway.disclaimerVersion`）都满足才算已同意，「不同意」**不写任何持久化**（不同意 = 从未同意过，下次照旧弹）；不做二次确认（弹窗本身就是那一次确认，再叠一层只会训练用户闭眼点）；正文语义有实质变化时版本号 +1，老用户下次进入重新看到一次。**网关转发层未重写** —— `GatewayServer` 的路由 / 双鉴权 / 协议互转 / 记账 / 流式转发本就完整，缺的只是接线。**自测**：新增 4 个脚本（保活 URL 44 项 / 保活调度 58 项 / 退避时序 21 项 / 工具箱门禁 41 项），加 `scripts/run-all-tests.sh` 一次跑完全部 13 个脚本共 396 项断言，0 失败；`scripts/check-docs.py` 由基线 3 项不一致修到全部一致 |
| 1.8.1 | 修复 v1.8.0 带出的四个问题，并补齐文档校验。**AI 保活并发重复请求**：点「立即发送」不受正在进行的请求保护，连点或与定时发送撞上就会重复发出去（重复计费 / 触发服务端限流）。改为同一任务同时只允许一个请求在飞。**工具箱排序数据绕过归一化**：`ToolboxLayout` 的 JSON 解码走合成 `init(from:)`，不经过排序归一化，直接解码会拿到含未知工具或缺工具的数据。主路径已显式重建救回，但任何直接解码的路径会拿到脏数据 —— 改为解码后也走一遍归一化。**配置写盘键序不固定**：`KeepAliveStore` 与 `MonitorConfig` 写盘没加 `.sortedKeys`，JSONEncoder 对 struct 的键序不固定，导致「配置和默认值是否相同」的判断随机出错（实测 200 次比较 200 次误判，必然触发）。两处都加上 `.sortedKeys`，写盘字节稳定。**结构体归位**：`MonitorConfig` 的定义从 `SystemMonitor.swift` 搬到 `MonitorConfig.swift`，文件名与内容对上。**文档校验器的两个盲区**：README 拆成中英双语后，AI 味检查用的词表全是中文短语却去查英文 README，英文里的套话一条都拦不住（等效于空转）；CLI 参数表也只查英文版，中文版参数表少一个参数没人知道。改为两份 README 都查、各用对应语言的词表，并补一份英文词表。**三处失效的自测**：`test-check-docs.py` 的三条负向用例锚点指向英文 README 里的中文内容，是双语拆分前的假设，拆分后锚点没跟着移，从 2026-10-01 起就一直处于「原文没找到」状态 —— 负向测试失效等于校验器少了两道防线。锚点改到中文版，并新增两条英文用例锁住英文检查。**回归套件补全**：`run-all-tests.sh` 之前只收了 14 个脚本，漏掉 idle-time / selfupdate / auto-start-manager / cpu-temperature-decode / cgeventtap 五个既有功能的回归测试。补齐后共 20 个脚本、461 项断言、0 失败 |


> 这个表**每次发版都要加一行**。它是给未来的人判断「哪个版本引入了什么」用的，
> 不维护的话，排查老版本问题时就没有参照。
