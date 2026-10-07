# 维护手册

面向「要动手改这个项目」的人。每个任务给出：**改哪些文件 → 步骤 → 怎么验证**。

改完别忘了 [README.md](README.md) 里那两张同步表，以及跑一次
`python3 scripts/check-docs.py`。

---

## 一、环境

| 需要 | 版本 | 说明 |
| --- | --- | --- |
| Xcode | 26 以上（含 macOS 26 SDK） | 部署目标 macOS 26 |
| XcodeGen | 任意近期版本 | `brew install xcodegen`，工程文件由 `project.yml` 生成 |
| Python 3 | 系统自带即可 | 跑 `scripts/` 下的辅助脚本 |

**`DeepSleep.xcodeproj` 是生成物，但被纳入了版本控制。**
改工程配置请改 `project.yml` 然后 `xcodegen generate`；
直接改 `.xcodeproj` 的改动会在下次 generate 时被覆盖。

**签名是 ad-hoc（`CODE_SIGN_IDENTITY = "-"`）**，本机可直接运行。
要分发给别人需要换成自己的开发者证书，并且注意：换了签名之后，
已安装的助手需要重装一次（二进制内容变了，摘要判据会发现）。

---

## 二、常用命令

```sh
# 构建
xcodegen generate
xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Debug -derivedDataPath build build

# 跑起来
open -a "build/Build/Products/Debug/Deep Sleep.app"

# 自检（不需要管理员权限的部分）
APP="build/Build/Products/Debug/Deep Sleep.app"
open -a "$APP" --args --status --blockers --rivals --helper-version

# 全部回归测试
swiftc Shared/Version.swift scripts/test-version-compare.swift -o /tmp/t1 && /tmp/t1
swiftc Shared/PMSetOutput.swift scripts/test-pmset-parse.swift -o /tmp/t2 && /tmp/t2
swiftc Shared/HelperProtocol.swift DeepSleepHelper/SelfUpdate.swift \
       scripts/test-selfupdate.swift -o /tmp/t3 && /tmp/t3
swiftc Shared/ProcessInventory.swift Shared/ProcessGuard.swift \
       Shared/TerminationReport.swift scripts/test-process-guard.swift \
       -o /tmp/t4 && /tmp/t4

# 文档一致性
python3 scripts/check-docs.py
```

---

## 三、常见改动怎么做

### 3.1 加一个命令行参数

1. `DeepSleep/AppDelegate.swift` —— 在 `handleLaunchArguments()` 的 switch 里加
   `case "--你的参数":`，并调用一个 `emitXxx()` 静态方法；
   同时在文件顶部那段 `///   --xxx   说明` 注释里加一行
2. `README.md` —— 参数表加一行（**用户可见文档**）
3. `docs/architecture.md` —— 如果它改变了程序行为，在对应机制那节提一句
4. 验证：`open -a "$APP" --args --你的参数`，看输出
5. `python3 scripts/check-docs.py` 会检查参数表是否同步

**注意**：CLI 输出统一走 `emit()`。它会把多行文本的**每一行**都加上 `deepsleep: `
前缀 —— 这是刻意的，只给首行加前缀的话，解析方就得靠猜来切分正文和日志噪音
（`--update-script` 打印脚本全文时踩过）。

### 3.2 加一个协议命令

**先想清楚这是不是破坏性改动。** 协议没有版本协商之外的兼容层：
`HelperConstants.protocolVersion` 不一致时双方直接拒绝通信。

1. `Shared/HelperProtocol.swift` —— `HelperCommand` 加 case（**带注释说明用途**）
2. `DeepSleepHelper/main.swift` —— `handle(_:)` 的 switch 加分支
3. `DeepSleep/Privileged/HelperClient.swift` —— 如果响应有新字段，
   加到 `Probe` 结构体或对应的返回类型里
4. **兼容性**：不需要升级 `protocolVersion` 的加法（新增命令、新增响应字段）
   是安全的 —— 旧助手遇到不认识的命令会返回解码错误而不是崩溃（**已实测**），
   而旧应用不会发送新命令
5. `docs/architecture.md` —— 命令表与相关机制
6. 验证：见下面「四、怎么验证」

**改已有命令的语义或删命令就要升 `protocolVersion`** —— 否则会出现
「应用以为助手会做 A，助手做的是 B」这种最难查的问题。

### 3.3 加一个界面页面

1. `DeepSleep/Views/` 下加 `XxxView.swift`
2. `DeepSleep/Views/ContentView.swift` —— 加 `case xxx` 到标签枚举
3. 沿用 `Views/Components.swift` 里的 `SectionCard` 等组件，别自己造一套样式
4. **用户可见的 UI 里不要写开发笔记** —— 不写 `(A5.2)`、不写「按您说的…」、
   不写「TODO」。要解释设计写进这份文档或代码注释

### 3.4 加一个自动化触发条件

1. `DeepSleep/Core/AutomationRule.swift` —— 规则模型的枚举
2. `DeepSleep/Core/AutomationEngine.swift` —— 求值逻辑
3. `DeepSleep/Views/AutomationView.swift` —— 编辑界面
4. 记住：**规则只表达意图**，不直接申请断言。申请与释放统一由
   `SleepController` 收敛，否则手动开关和规则会互相打架

### 3.5 改断言或对账行为

这是全项目最敏感的地方，动手前先读
[architecture.md](architecture.md) 的 3.1–3.3。

- 断言的申请/释放**只能**通过 `SleepController`，不要在别处直接调 `HelperClient`
- 睡前拦截（`PowerWatcher`）**必须保留兜底超时**。去掉它可能出现
  「永远不放行」把系统吊死的状态 —— 这比睡眠失败严重得多
- 对账纠正的范围**不要扩大**。用户期望的是「阻止睡眠」，不是
  「所有电源设置都听应用的」。范围表在 architecture.md 的 3.3
- 改完必须实测：`--wait 10 --status` 看 `audits=` 是否按周期递增

### 3.6 改安装 / 卸载脚本

1. 脚本在 `DeepSleep/Resources/`，**单独成文件而不是内联进 Swift 字符串** ——
   这样可以被 `sh -n` 静态检查和 dry-run 验证，请保持这个性质
2. 路径全部通过环境变量传入（`HELPER_SRC` / `HELPER_DEST` / `DAEMON_PLIST` /
   `DAEMON_LABEL` / `SOCKET_PATH` / `LOG_PATH`），脚本里**不要硬编码路径**
3. 每个变量都要有 `: "${VAR:?缺少 VAR}"` 形式的检查
4. 必须保留 `plutil -lint` —— 不校验的话 launchd 会**静默拒绝加载**，
   排查起来非常费劲
5. 验证：
   ```sh
   sh -n DeepSleep/Resources/install-helper.sh          # 语法
   # dry-run：脚本读取的环境变量齐全性、plist 生成结果
   ```
   真正的端到端安装需要管理员授权，只能人工确认

### 3.7 改更新机制

- 应用侧：`DeepSleep/Core/UpdateManager.swift`
- 助手侧：`DeepSleepHelper/SelfUpdate.swift`

**动这两处之前先看 [gotchas.md](gotchas.md) 里关于回滚和摘要的两条。**

硬性要求：

- 应用更新的判据必须是**严格更高**的版本，解析失败必须当作「无法判断」
- 助手更新的判据是**内容摘要不同**
- 自我更新的四条校验**一条都不能去**
- 任何「替换自己」的逻辑都要保证：任一步失败后，用户原来那份东西还在

验证方法：`--update-script` 打印脚本、`--update-check` 检查更新、
`scripts/test-selfupdate.swift` 跑校验用例。

**助手的手动更新路径**（`refresh()` / `updateNow()`）与自动路径共用一个探测实现，
但**不共用次数限制** —— 给自动重试用的闸门不能套在用户明确发起的手动动作上，
否则就是「点了没反应、也不解释」（曾经真的这样，见 gotchas 22）。
改这块时把每个分支的话补齐：界面用对话框、命令行用 `emit`。

端到端验证：`bash scripts/test-helper-update.sh`
（用 Debug 与 Release 两个产物互为「不同的一份」，真的替换系统里的助手，再换回来）。

### 3.8 加一个回归测试

`scripts/` 下的测试都是 **`swiftc` 直接编译真实源码 + 一个 `@main` 测试文件**，
不引入测试框架，也不复制一份逻辑来测。新测试请沿用这个形式：

```sh
swiftc <被依赖的真实源文件...> scripts/test-xxx.swift -o /tmp/t && /tmp/t
```

输出格式沿用现有的 `[通过]` / `[失败]` + 末尾 `测试结论: ...`，
失败时 `exit(1)`。

**为什么不复制逻辑**：项目里曾出现「同一段解析 app 和助手各写一份、
同一个 bug 存在两处」。复制到测试里等于再存一份可能过期的副本。

### 3.9 加一条 URL 命令 / 一个 Siri 短语

**URL 命令**：在 `DeepSleep/Core/URLCommands.swift` 的 `commands` 表里加一条，
再在 `handle(_:)` 的 switch 里加分支。那张表是界面说明、`--automation` 输出、
`docs/architecture.md` 的「URL 命令一览」三处的**单一来源** ——
加完同步文档，`check-docs.py` 会把两边对一遍。

**Siri 短语 / 快捷指令动作**（App Intents）：

1. `DeepSleep/Intents/DeepSleepIntents.swift` 加 `AppIntent`：先
   `await SleepController.shared.ensureReady()`，再**复用应用内的方法** ——
   不要在 intent 里自己调 `HelperClient`，那会绕过「完全控制」与确认逻辑
2. `DeepSleep/Intents/DeepSleepAppShortcuts.swift` **两处都要加**：
   编译期的 `AppShortcut(...)`（短语**必须**含 `\(.applicationName)`，否则编译不过）
   与展示用的 `DeepSleepShortcutCatalog.entries`（短语里用 `{应用名}` 占位）
3. `Views/AutomationView.swift` 的说明区块会自动列出，不用手改
4. `xcodegen generate` 后构建，确认 `Metadata.appintents` 产物里出现了新 intent
5. `check-docs.py` 会逐条比对两份短语 —— 漏一处就失败

**验证**：`--automation` 打印的清单就是「系统里实际能说的话」。
真的对 Siri 说话、在快捷指令里点击动作，只能人工确认。

### 3.10 改快速退出的保护名单

名单在 `Shared/ProcessGuard.swift`（`protectedNames` / `protectedBundleIDs`），
**app 与助手编译同一份**。

1. 改代码
2. 同步 `docs/architecture.md` 第六节的名单表（`check-docs.py` 会逐条比对）
3. 在 `scripts/test-process-guard.swift` 里给新增项补一条断言
4. 跑 `python3 scripts/check-docs.py` 与第四个回归测试

红线：

- **不要**给名单加「开关」或「从外部传入」的入口 —— 它是安全边界，不是配置项
- **不要**只挡根进程而放行它的子树（`plan()` 里命中即 `blockSubtree()`）
- 名单之外不该被顺带拦住：「不能杀系统进程」不等于「什么都不敢杀」

### 3.11 改快速退出的执行路径

- 目标解析、双路执行、演练：`DeepSleep/Core/QuickQuit.swift`
- 助手侧：`DeepSleepHelper/main.swift` 的 `terminateProcesses` 分支
- **助手只接受 pid**，裁决必须自己算 —— 不要为了「省一次枚举」把应用算好的列表接过来
- 进程数上限 `ProcessGuard.maximumTargetCount` 是两侧共用常量，改它要同时想清两边行为
- 验证顺序：`--dry-run`（不动手）→ 单测 → 真实杀探针（探针怎么造见 gotchas 17）→
  看助手日志的 `terminate 根进程=N 目标=M 已退出=X 受保护=Y 失败=Z`

---

## 四、怎么验证

**这个项目最大的教训是：不要只看代码就说「应该是对的」。**
已经出现过好几次「代码看起来对、实际不对」，甚至「推断合理、实测被推翻」。
验证手段按可信度排序：

### 4.1 端到端跑一遍（首选）

```sh
APP="build/Build/Products/Debug/Deep Sleep.app"
pkill -f "Deep Sleep.app/Contents/MacOS/Deep Sleep" 2>/dev/null
open -a "$APP" --stdout /tmp/out.log --stderr /tmp/err.log \
     --args --wait 8 --status --blockers --rivals --helper-version
sleep 20
pkill -f "Deep Sleep.app/Contents/MacOS/Deep Sleep" 2>/dev/null
grep 'deepsleep:' /tmp/out.log
```

**必须用 `open`，不能直接跑 `Contents/MacOS/Deep Sleep`。**
直接跑没有经过 LaunchServices，窗口和激活策略的行为会和真实启动不同
（`--window-self-test` 就是依赖这一点来对比的）。

### 4.2 向内核/系统要事实

```sh
pmset -g assertions            # 断言是否真的创建了、谁持有
pmset -g | grep -i sleepdisabled
launchctl print system/com.skyc8266.deepsleep.helper
```

系统说成立了才算成立。应用自己的日志是**自述**，不是证据。

### 4.3 看助手日志

```sh
tail -50 /var/log/com.skyc8266.deepsleep.helper.log
```

**注意**：LaunchDaemon 的 `StandardOutPath` 与 `StandardErrorPath` 指向同一个文件，
所以每行可能出现两次。统计调用次数时**必须把这个算进去** ——
历史上曾把 1406 行 `setSleepDisabled` 当成 1406 次调用，实际是 703 次，
而 703 次恰好对应「35 分钟 ÷ 3 秒」，这个巧合才对上账。

### 4.4 回归测试

纯逻辑部分（解析、比较、校验、进程裁决）都有回归测试，改动后立刻跑一遍：

```sh
swiftc Shared/Version.swift scripts/test-version-compare.swift -o /tmp/t1 && /tmp/t1
swiftc Shared/PMSetOutput.swift scripts/test-pmset-parse.swift -o /tmp/t2 && /tmp/t2
swiftc Shared/HelperProtocol.swift DeepSleepHelper/SelfUpdate.swift \
       scripts/test-selfupdate.swift -o /tmp/t3 && /tmp/t3
swiftc Shared/ProcessInventory.swift Shared/ProcessGuard.swift \
       Shared/TerminationReport.swift scripts/test-process-guard.swift \
       -o /tmp/t4 && /tmp/t4
```

第四个（`test-process-guard.swift`）是快速退出的裁决层：保护名单、进程树、
结果编解码，外加**真实结束一棵进程树**并由内核确认目标已消失。
它第一次跑就抓出两个真 bug（见 [notes.md](notes.md)），所以别跳过它。

助手更新这条路要真实 socket 与 `/Library` 里那个 root 助手，塞不进单测，
所以单独固化成端到端脚本（**它会真的替换已安装的助手，结束时换回 Release 那份**）：

```sh
bash scripts/test-helper-update.sh
```

它用 Debug 与 Release 两个产物内置的助手互为「不同的一份」，
要求每次都报出差异、报出成功，并且用 `shasum` 确认 `/Library` 那份**真的**变了 ——
不信自述，只信文件系统。改过助手更新路径后务必跑一遍。

### 4.5 静态检查

危险动作（以 root 运行的脚本、替换自己的更新器）尽量做 dry-run 或打印出来审。
项目里 `install-helper.sh` / `uninstall-helper.sh` 单独成文件、
`--update-script` 这个出口，都是为此存在的。

`check-docs.py` 还兼职扫一类「编译器不会报错但用户看得见」的错误：
Swift 源码里被转义掉的插值 `\\(`（会在界面上原样显示）。
另外它还查 `README.md` 的文案有没有 AI 味 —— 套话词表、「不是……而是……」对偶句、
长破折号数量（上限 2）。用户打开项目第一眼看到的就是 README 与发布说明，
那种腔调会把人劝走。只查 README，`docs/` 是给开发者看的，不受这条约束。

改过文档之后，除了跑 `check-docs.py`，也值得跑一次它的负向测试
`python3 scripts/test-check-docs.py` —— 确认校验器本身还能拦住不一致，
而不是变成一个永远打印「✓」的摆设。

### 4.6 人工确认（无法自动化）

这些只能由人做，别假装验证过：

- 管理员的安装授权对话框（`sudo` 无法在无交互环境完成）
- Touch ID 指纹确认
- 真实鼠标点击菜单栏（系统级事件合成需要「辅助功能」权限）
- 真的按一次快速退出快捷键（`--hotkey-status` 只证明注册成功）
- 真的对 Siri 说话、在「快捷指令」App 里点击 Deep Sleep 动作
- UI 截图（`screencapture` 需要「屏幕录制」、`System Events` 需要「辅助功能」）

### 4.7 监控的日志在哪

- **应用侧** 监控异常 / 弹窗 / 通知 走的是 `SleepController.appendLog`，
  在应用内「运行日志」页可见；不写文件。
- **助手侧** v2 协议命令的进出都走 `logLine("…")`，日志在
  `/var/log/com.skyc8266.deepsleep.helper.log`。看 `getProcessStats` /
  `suspendProcesses` / `killProcesses` 的请求与结果：
  ```bash
  tail -50 /var/log/com.skyc8266.deepsleep.helper.log
  ```
- **系统通知** 「过载 / 泄漏」走标准 `UNUserNotificationCenter`，
  取消与历史在「系统设置 → 通知 → Deep Sleep」。

---

## 五、调试工具（`scripts/`）

| 脚本 | 用途 |
| --- | --- |
| `make-icon.py` | 生成应用图标（Python + Pillow，无第三方素材） |
| `helper-probe.py` | 直接与助手 socket 对话，排查与端到端测试 |
| `probe-unknown-command.py` | 给助手发它不认识的命令，验证它优雅拒绝而不是崩溃 |
| `dump-power-assertions.swift` | 从外部 dump 当前电源断言（含进程名补全） |
| `dump-windows.swift` | 从进程外部查看窗口是否真的出现 |
| `try-release-assertion.swift` | 验证跨进程释放断言会被内核拒绝 |
| `test-pmset-parse.swift` | `pmset -g` 解析回归（喂真实输出） |
| `test-version-compare.swift` | 版本比较回归（含防循环用例） |
| `test-selfupdate.swift` | 助手自我更新四条校验 |
| `test-process-guard.swift` | 快速退出裁决回归（保护名单 / 进程树 / 结果编解码 / 真杀一棵树） |
| `test-process-stats.swift` | 进程快照编解码 round-trip + 特殊字符处理 |
| `test-process-snapshot.swift` | 真实进程快照（验证 RSS / 启动时间 / CPU% 范围） |
| `test-leak-detector.swift` | 内存泄漏启发式（稳定 / 锯齿 / 短尖峰 / 单调增长 / 阈值下限） |
| `test-auto-start-manager.swift` | LaunchAgent plist 内容生成（无 KeepAlive=true） |
| `build-release.sh` | 构建 Release 并打包 `DeepSleep.zip` + sha256 |
| `check-docs.py` | 文档与代码一致性检查（兼扫转义插值） |
| `test-check-docs.py` | 前者的负向测试：逐条把文档改坏，确认它真的会拦 |
| `test-helper-update.sh` | 助手更新端到端：真的替换已安装的助手，再换回来 |

---

## 六、提交约定

- **commit message 用中文**，说清「改了什么」和「为什么」
- **改动即提交**，但**默认不 push** —— push 与发版由项目所有者决定
  （发版时按 [release.md](release.md) 走，那一步才 push）
- 文档与代码在同一个 commit 里更新，不要分开
- 提交身份用全局配置（`Panmofan <panmofan@icloud.com>`），
  不要手动 `-c user.name=...` 指定别的身份 —— 那样不会关联到 GitHub 账号

---

## 七、改动前的检查清单

动手之前过一遍，能省很多返工：

- [ ] 读 [architecture.md](architecture.md) 里对应的机制那节
- [ ] 如果要动断言/对账/睡前拦截 —— 确认理解了「三层防护」为什么是三层
- [ ] 如果要动快速退出或保护名单 —— 先读 architecture.md 第六节与 gotchas 19
- [ ] 如果要动更新机制 —— 读 [gotchas.md](gotchas.md) 的两条相关记录
- [ ] 如果要加协议命令 —— 想清楚要不要升 `protocolVersion`
- [ ] 想好**怎么验证**：能不能端到端跑出来？系统层面看得到什么？

改完之后：

- [ ] 端到端跑一遍（不是只看编译通过）
- [ ] 四个回归测试全过
- [ ] `python3 scripts/check-docs.py` 通过
- [ ] 同步了文档（[README.md](README.md) 的两张表）
- [ ] 如果踩到新坑 → 记进 [gotchas.md](gotchas.md)
