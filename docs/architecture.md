# 架构与运作逻辑

---

## 一、总览

```
                        ┌──────────────────────────────┐
                        │   Deep Sleep.app             │
                        │   （普通权限，登录用户运行） │
                        │                              │
   用户意图 ──────────► │  SleepController             │
   （开关 / 规则 /      │   意图集合 → 实际持有         │
     倒计时 / CLI）     │                              │
                        │  PowerWatcher  电源事件监听  │
                        │  PowerActivityMonitor 外部观测│
                        │  AutomationEngine 规则求值   │
                        │  UpdateManager 应用自更新    │
                        │  HelperVersionManager 助手自更新│
                        └───────────┬──────────────────┘
                                    │  UNIX socket
                                    │  /var/run/com.skyc8266.deepsleep.sock
                                    │  长度前缀 + JSON
                                    │  getpeereid 校验对端 uid
                        ┌───────────▼──────────────────┐
                        │   deepsleep-helper           │
                        │   （root，由 launchd 常驻）   │
                        │                              │
                        │   持有需要 root 的断言        │
                        │   写入 pmset 设置            │
                        │   排定唤醒 / 立即睡眠         │
                        │   自我更新（替换自己的二进制） │
                        └──────────────────────────────┘
```

两个 target 共用 `Shared/` 下的代码：协议定义、socket 封装、`pmset -g` 解析、版本比较。
**共用是刻意的** —— 曾出现同一段解析逻辑两边各写一份、同一个 bug 存在两处的情况。

---

### 协议命令一览

`HelperCommand` 枚举的全部取值。**加命令时必须同步这张表** ——
`scripts/check-docs.py` 会比对它与代码，不一致会直接报错（这也是保留这张表的主要理由）。

改已有命令的语义或删命令要同时升 `HelperConstants.protocolVersion`；
纯新增命令或新增响应字段则不必（旧助手遇到不认识的命令会返回解码错误而**不会崩溃**，
而旧应用不会发送新命令）。

| 命令 | 用途 |
| --- | --- |
| `ping` | 存活探测；回报协议版本与助手自身二进制的摘要 |
| `status` | 助手侧状态：持有的断言、`disablesleep` 当前值 |
| `acquireAssertion` | 申请一个需要 root 权限的电源断言 |
| `releaseAssertion` | 释放一个由本助手持有的断言 |
| `setSleepDisabled` | 写入 `pmset -a disablesleep` |
| `readPowerSettings` | 读取 `pmset` 电量管理设置 |
| `writePowerSetting` | 写入单个 `pmset` 设置（键走白名单、值必须为纯数字） |
| `scheduleWake` | 排定一次定时唤醒 |
| `cancelScheduledWake` | 取消已排定的唤醒 |
| `sleepNow` | 立即进入睡眠（会先释放本助手持有的全部断言） |
| `uninstall` | 卸载助手：停止任务并删除文件 |
| `updateSelf` | 用应用内置的新二进制替换助手自身（四条校验，见下文 3.6） |

## 二、权限模型：管理员密码只输一次

macOS 上真正彻底的睡眠控制都需要 root：

- `PreventSystemSleep` 断言（合盖也不睡）
- `pmset -a disablesleep 1`（完全禁止睡眠，重启仍生效）
- 修改电源设置、排定唤醒

如果每次操作都弹密码框，体验无法接受。所以：

1. 用户在「完全控制」页点**启用完全控制** → 弹**一次**管理员授权对话框
   （配了 Touch ID 的机器可以直接指纹确认）
2. 授权被用来执行 `Resources/install-helper.sh`，它做四件事：
   - 把助手二进制拷到 `/Library/PrivilegedHelperTools/`，`chown root:wheel`、`chmod 755`
   - 写出 LaunchDaemon plist 到 `/Library/LaunchDaemons/`，`RunAtLoad` + `KeepAlive`
   - `plutil -lint` 校验 plist（**不校验的话 launchd 会静默拒绝加载**）
   - `launchctl bootstrap system` 并等 socket 就绪（最多 5 秒）
3. 此后所有提权操作都经 socket 交给助手，只要求 **Touch ID / 登录密码**做本地确认，
   不再要管理员密码

**为什么不用 SMJobBless / SMAppService：** 它们要求开发者签名与更严格的 provisioning，
本项目用 ad-hoc 签名分发，走不通。`osascript` 方案在无签名场景下可直接工作，
代价是"一次性"，但这正好符合需求。

### 助手侧的防护

| 措施 | 作用 |
| --- | --- |
| socket 归当前登录用户所有，权限 `0600` | 其他用户连不上 |
| 每个连接用 `getpeereid()` 校验对端 uid | 即使路径可达也拒绝非登录用户 |
| 只接受固定的命令枚举 | 不执行任何外部传入的 shell 字符串 |
| `pmset` 可写键走白名单，取值必须是纯数字 | 杜绝参数注入 |
| 启动时校验自己以 root 运行，否则退出 | 防止被普通权限拉起后行为异常 |
| `updateSelf` 四条硬校验 | 见下文「助手自我更新」 |

### 完全可回退

「停用并卸载」执行 `Resources/uninstall-helper.sh`，移除 `/Library` 下全部文件与
launchd 任务，系统回到安装前状态。

---

## 三、核心机制

### 3.1 意图与状态分离

`SleepController` 里有两个独立集合：

- **用户意图** —— 手动开关 + 自动化规则 + 倒计时推导出的「要保持什么」
- **实际持有** —— 此刻真的申请了哪些断言

每一轮 `reconcile()` 取意图的**并集**，再与「实际持有」求差，只对差异部分申请/释放。

这样做的原因：如果直接把开关状态当实际状态用，就会出现
「关掉一条规则时把用户手动开的开关也关掉」这类问题；而且退出时无法保证干净释放。

### 3.2 三层防护（对抗外部干扰）

`pmset` 设置是系统级持久配置，任何 root 程序都能改。
用户打开「阻止睡眠」的语义是「我不希望它睡」，所以设置写进去之后还要持续纠偏：

| 层 | 机制 | 覆盖场景 |
| --- | --- | --- |
| 1 | **3 秒周期对账**（`auditExternalState`） | 空闲睡眠。idle timer 以分钟计，3 秒足够抢在到点前改回去 |
| 2 | **`PreventSystemSleep` 断言** | 合盖、菜单「睡眠」等**主动**请求。`disablesleep` 只在 powerd 评估空闲睡眠时生效，断言才能在决策阶段挡下来 |
| 3 | **睡前拦截**（`PowerWatcher`） | 已经走到睡眠等待路径时的最后机会。收到 `willSleep` 后系统会等 `IOAllowPowerChange`，这段窗口里重建防护，powerd 即会取消本次睡眠 |

第 3 层的安全边界：用户没有要求阻止睡眠时**立刻放行**，
并且始终有 5 秒兜底超时 —— 绝不允许出现「永远不放行」把系统吊死的状态。

**两个常见疑问的答案（都经过实测）：**

- **断言会被别的程序取消吗？** 不会。断言归创建它的进程所有，跨进程释放返回
  `kIOReturnNotPermitted`。唯一失效途径是自己进程死亡 —— 这正是对账要覆盖的场景。
- **能保证一定不睡吗？** 不能。Apple 文档明确写着断言只是「建议」，
  低电量或过热时系统可能无视它。任何软件都挡不住这两种情况。

### 3.3 对账纠正的范围（刻意收窄）

`auditExternalState()` 依次调用：

```
auditHelperProcess()     助手进程可能被重启（崩溃 / bootout / 系统更新），
                         新进程不持有任何断言，旧断言已随旧进程消失 → 重建
auditRemoteAssertions()  核对助手侧持有的断言
auditLocalAssertions()   核对应用自己持有的断言
auditSleepDisabled()     核对 disablesleep 是否还是用户要的值
```

**只纠正「阻止睡眠」所依赖的状态，不改其他电源设置：**

| 状态 | 是否纠正 | 原因 |
| --- | --- | --- |
| 断言 | 是 | 阻止睡眠的主力 |
| `disablesleep` | 是 | 用户开着「完全禁止睡眠」时被改掉等于功能失效 |
| `sleep` / `displaysleep` 等 | **否** | 那是用户与系统的正常配置，不该被应用单方面改回去 |

### 3.4 外部活动观测

「外部活动」页回答两个不同的问题，用的是两套机制。

**谁在阻止休眠** —— `IOPMCopyAssertionsByProcess()` 直接向内核取当前所有电源断言，
按进程分组，标出是「阻止系统睡眠」还是「仅阻止屏幕睡眠」，并显示断言原因字符串。
Deep Sleep 自己的断言也会列出并标记「本应用」，方便对照。

`UserIsActive` 这类不计入 —— 那是系统对「用户正在操作」的描述，不是程序在索要保持清醒。

进程名优先用 `NSRunningApplication` 取；取不到时（`powerd`、`coreaudiod`
这类系统守护进程）退回 `proc_pidpath` 读可执行文件路径末段。

**谁改了电源设置** —— 每 6 秒对 `pmset -g` 做快照比对，记录变化的键、旧值、新值、时间。

- **能确定的**：改了什么、从什么变成什么、什么时候，以及**是不是 Deep Sleep 自己改的**
  （我们跟踪自己的写入，所以能明确排除自己）。
- **不能确定的**：是哪个进程写进去的。macOS 没有公开 API 给出这个信息，
  所以不猜进程名，只给事实。（`pmset -g log` 只有睡眠/唤醒事件，
  不含设置变更记录，对这个问题没有帮助，已实测。）

**谁在抢控制权** —— 上面那套抓不到一类程序：它们**既不持有断言、也不阻止自己睡眠**，
而是直接去改系统电源设置。发现办法是看程序里有没有相关代码：
扫描当前运行的非 Apple 应用，在可执行文件里搜索 `disablesleep` / `SleepDisabled`
字符串常量，结果按包路径缓存。

读不到文件一律判为「不是」—— 这个列表**宁可漏报也不误报**，
一个总在冤枉别的程序的警示等于没有警示。

**检测到之后不做什么：** Deep Sleep 不去关掉别的程序，也不提示用户去关。
别的软件怎么配置系统是用户自己的事；应用的职责是让用户知道发生了什么，
然后继续保证自己那一份（断言 + `disablesleep`）。

### 3.5 应用自动更新

```
启动 15 秒后（以及此后按需）
   │
   ├─ GET /repos/{owner}/{repo}/releases?per_page=30
   │     丢掉 draft，保留 prerelease，按版本号比较取最高的一条
   │
   ├─ 只有在版本号「严格更高」时才继续
   │     ├─ 版本号解析不了 → 当作「无法判断」→ 不更新
   │     └─ 解析失败绝不能当作「有更新」，否则每次都重装
   │
   ├─ 下载资产里固定名为 DeepSleep.zip 的包
   │
   ├─ 逐项校验（任何一步不过就放弃）
   │     zip 可解 / bundle id 正确 / 版本与 Release 一致
   │     codesign --verify 通过 / 有 .sha256 则比对
   │
   ├─ 写一个更新器脚本到临时目录，启动它，然后自己退出
   │
   └─ 脚本：等本进程退出（≤30 秒）→ 挪走旧的 → 放入新的 → 重开
           任一步失败都回滚，且不回滚时删目标路径
```

**为什么用 `/releases?per_page=30` 而不是 `/releases/latest`：**
后者不返回预发布版本。本仓库的发布习惯是标 Pre-release，
用它的结果是「明明有 Release 却一直报 404」。这是个真实踩过的坑。

**为什么更新器必须是独立脚本：** 替换「正在运行的自己」要求先退出进程，
而进程一退出就没有代码能继续执行了 —— 这一步只能交给外部进程。
脚本住在临时目录而不是 `.app` 内部，因为 `.app` 正是要被替换的对象。

**为什么回滚分支里没有 `rm -rf "$TARGET"`：** 最初写的是「先清干净再放」，
看上去更稳妥。实际是：如果「挪走旧版本」那步失败（磁盘满、权限不足），
`rm -rf` 会把应用直接删掉，而回滚又会因为备份根本不存在而同样失败 —— 应用彻底没了。

**`--update-script` 存在的意义：** 它把脚本全文打印出来但不执行。
这不是调试残留 —— 上面那个回滚缺陷就是它暴露出来的。

### 3.6 助手自我更新

助手是 root 常驻的，所以能**自己替换自己**，这种更新不需要再输管理员密码。
代价是 `updateSelf` 成了全项目权限最高的路径（它能把一个 root 二进制写进 `/Library`），
因此四条硬校验缺一不可：

| # | 校验 | 挡住什么 |
| --- | --- | --- |
| 1 | 来源必须是 `Deep Sleep.app` 内部的固定相对路径 | 本地用户随便指一个二进制让它提权安装 |
| 2 | 那个 `.app` 的 `CFBundleIdentifier` 必须是 `com.skyc8266.deepsleep` | 伪造一个同名目录结构 |
| 3 | 文件的 SHA-256 必须与调用方给的一致 | 内容损坏或被掉包 |
| 4 | 内容摘要不能与当前这份完全相同 | 无意义的重装（换成一个一模一样的东西） |

**判据为什么是内容摘要，而不是版本号或构建号：**

| | 版本号 / 构建号 | 内容摘要 |
| --- | --- | --- |
| 需要人维护吗 | 要。忘改 = 「修好了却不更新」；改错 = 「每次启动都更新一遍」 | 不需要，程序自己算 |
| 只改了应用、没动助手 | 误判成要更新，白下载还白重启一次进程 | 摘要相同 → 不动 |
| 会不会循环 | 要靠「严格递增」等额外规则保证 | **天然收敛**：替换成功后两边必然一致 |

所以这个项目里**助手不需要任何版本号** —— 应用版本号只用于应用自己的更新判断，
以及给人看。两者各司其职。

**防循环三道防线：**

1. 判据是「内容不同」，而不是「版本不等」
2. 每次应用运行**最多尝试一次**自动更新，失败即停手，留给下次启动
3. 更新后必须**重新探测到新摘要**才算成功；确认不到就记失败，不重试

第 3 条容易被省掉，但省掉它的话，更新实际没成功时应用仍会宣称成功，
用户看到「更新了但版本没变」—— 这是最难排查的一类问题。

### 3.7 日志

两处日志，两套策略：

| 位置 | 存储 | 清理方式 |
| --- | --- | --- |
| 应用「运行日志」页 | 内存，不写磁盘 | 按**条数**（默认 500，可调 50–5000）+ 按**天数**（默认 7，可调 0–365）双重裁剪 |
| 助手日志 `HelperConstants.logPath` | 文件 | 按天归档为 `.log.YYYY-MM-DD`；单日超 512 KB 保留尾部；超过 7 天的归档自动删除 |

**两个维度都要**，因为失效方式不同：只限条数时，一台安静运行的机器会把几个月前的日志一直留着；
只限天数时，一个话痨循环能在几小时内把内存撑爆 —— 对账循环正是后者，
判断一错就是每 3 秒一条（历史上真实发生过）。

助手日志原本超过 1 MB 就整个删掉，那等于在出问题的时候把最该看的最近几行一起丢掉；
现在改成保留尾部、并在换行处切割，不留半行乱码。

---

## 四、模块职责

| 文件 | 职责 | 改动时注意 |
| --- | --- | --- |
| `Shared/HelperProtocol.swift` | 命令枚举、请求/响应结构、路径与协议常量 | 加命令要同步文档；协议版本不一致时双方会拒绝通信 |
| `Shared/UnixSocket.swift` | socket 读写、长度前缀分帧、超时、对端 uid 校验 | 分帧格式两边共用，改格式必须同时改两端 |
| `Shared/PMSetOutput.swift` | `pmset -g` 解析 | **app 与助手共用一份**，不要再各写一份 |
| `Shared/Version.swift` | 版本号解析与逐段比较 | 解析失败返回 nil，调用方必须当作「无法判断」 |
| `DeepSleep/Core/SleepController.swift` | 核心状态机：意图合并、对账、日志、CLI 状态输出 | 全项目最核心的文件，改动前先读本节 3.1–3.3 |
| `DeepSleep/Core/PowerWatcher.swift` | 电源事件监听（睡前拦截 + 唤醒后对账） | 拦截窗口里有兜底超时，别去掉 |
| `DeepSleep/Core/PowerActivityMonitor.swift` | 外部活动：断言持有者、设置改动、抢控制权程序 | 抢控制权检测宁可漏报不误报 |
| `DeepSleep/Core/AutomationRule.swift` / `AutomationEngine.swift` | 自动化规则模型与求值 | 规则只表达意图，不直接操作断言 |
| `DeepSleep/Core/UpdateManager.swift` | 应用自更新：检查、校验、替换 | 回滚分支不要删目标路径 |
| `DeepSleep/Core/HelperVersionManager.swift` | 助手版本状态与触发自我更新 | 判据是内容摘要 |
| `DeepSleep/Privileged/HelperClient.swift` | socket 客户端、`probe()` | `Probe` 是结构体，加字段比改元组便宜 |
| `DeepSleep/Privileged/HelperInstaller.swift` | 一次性安装 / 卸载 | 路径常量在 `HelperConstants`，脚本从环境变量取 |
| `DeepSleep/Auth/BiometricAuth.swift` | Touch ID 授权封装 | — |
| `DeepSleep/Windows/` | 菜单栏图标、窗口与 Dock 图标策略 | 菜单栏用 AppKit 手搭，原因见下 |
| `DeepSleep/Views/` | SwiftUI 界面 | 不在用户可见 UI 里写开发笔记 |
| `DeepSleep/AppDelegate.swift` | 生命周期 + 命令行接口 | 加 CLI 参数要同步 `README.md` 与本文档 |
| `DeepSleep/Resources/install-helper.sh` / `uninstall-helper.sh` | 以 root 运行的脚本 | 单独成文件以便 `sh -n` 检查；路径全靠环境变量传入 |
| `DeepSleepHelper/main.swift` | 助手主循环与命令分发 | 只接受固定命令枚举 |
| `DeepSleepHelper/SelfUpdate.swift` | 助手替换自己 | 四条校验，去掉任何一条都是提权漏洞 |

**菜单栏为什么不用 SwiftUI 的 `MenuBarExtra`：** 它的点击一律弹出自己的面板，
**无法区分左右键**，做不到「左键打开界面、右键弹设置」。所以用 AppKit 的
`NSStatusItem` 手动搭。菜单每次弹出都重新构建，因此勾选状态永远是当下的真实状态。

---

## 五、关键常量

都在 `HelperConstants` 与 `project.yml` 里，这里只列出来便于建立印象
（**具体值以代码为准，本文档不复制**）：

| 名称 | 含义 |
| --- | --- |
| `label` | launchd 标签，同时也是 plist 文件名主体 |
| `socketPath` | 助手监听的 UNIX socket |
| `installedHelperPath` | 助手在系统内的安装路径 |
| `launchDaemonPath` | LaunchDaemon plist 路径 |
| `logPath` | 助手日志路径 |
| `protocolVersion` | 协议版本，双方不一致时拒绝通信 |

进程名是 `com.skyc8266.deepsleep.helper`（**点号分隔**，`pgrep` 时别写成
`deepsleep-helper`，那是文件名的形式）。

Bundle ID：`com.skyc8266.deepsleep`。

---

## 六、启动与退出时序

**启动：**

```
应用启动
  ├─ 读 UserDefaults 恢复用户设置
  ├─ 创建菜单栏图标、决定 Dock 图标策略
  ├─ SleepController.bootstrap()
  │     ├─ 连接 socket，probe() 助手
  │     ├─ 启动 3 秒对账循环
  │     └─ 接入 HelperVersionManager（此后每约 1 分钟检查一次助手）
  ├─ PowerWatcher 注册电源事件
  └─ 15 秒后触发一次应用更新检查
```

**退出：**

```
退出
  ├─ 释放本进程持有的全部断言
  ├─ 若本应用开过 disablesleep → 恢复系统默认
  ├─ 保存（助手侧）最后进度
  └─ 走正常 AppKit 退出路径
```

**助手被重启时**（崩溃、`launchctl kickstart`、系统更新）：
新进程不持有任何断言，而旧断言已随旧进程消失。`auditHelperProcess()`
会在下一轮对账中发现这件事并重建断言。

---

## 七、相关文档

- 改动时要同步什么 → [README.md](README.md) 的两张表
- 具体怎么改 → [maintenance.md](maintenance.md)
- 怎么发版 → [release.md](release.md)
- 为什么某段代码不能写简单些 → [gotchas.md](gotchas.md)
