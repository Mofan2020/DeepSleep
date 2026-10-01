# Deep Sleep 维护文档

这套文档面向**后续维护者** —— 包括下一个接手的人，也包括下一个 AI 助手。

它的目标不是复述代码（代码自己会说话），而是回答两个代码回答不了的问题：

- **为什么是这样？**（当初为什么不那样做）
- **改动时要注意什么？**（改这里会牵动哪里）

---

## 五分钟跑起来

```sh
brew install xcodegen          # 只需一次

cd DeepSleep
xcodegen generate              # 由 project.yml 生成 DeepSleep.xcodeproj
xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Debug -derivedDataPath build build

open "build/Build/Products/Debug/Deep Sleep.app"
```

自检（不需要管理员权限的那部分）：

```sh
APP="build/Build/Products/Debug/Deep Sleep.app"
open -a "$APP" --args --status --blockers --rivals --helper-version
```

想验证某个功能真的成立，**不要只看代码** —— 这个项目里已经出现过好几次
「代码看起来对、实际不对」和「推断看起来合理、实测被推翻」的情况，
详见 [gotchas.md](gotchas.md)。

---

## 文档地图

| 文档 | 什么时候读 |
| --- | --- |
| [architecture.md](architecture.md) | 想理解程序怎么运转、各个模块负责什么 |
| [maintenance.md](maintenance.md) | 要改代码、加功能、加协议命令 |
| [release.md](release.md) | 要发一个新版本 |
| [gotchas.md](gotchas.md) | 看到某段代码很奇怪，想知道为什么不能改简单些 |
| [notes.md](notes.md) | 查历史实测数据与调查过程（含被推翻的推断） |
| `../README.md` | 面向**用户**的功能说明，不是维护文档 |

---

## 文档不会自己保持正确

**过期的文档比没有文档更糟** —— 它不只是没帮上忙，而是会主动把人引到错的方向。
所以这里不靠「记得更新」，靠两条机制。

### 机制一：机器能查的，不让它靠人记

```sh
python3 scripts/check-docs.py
```

它把文档和代码对一遍，检查：

| 检查 | 依据 |
| --- | --- |
| 文档里的 CLI 参数表 ↔ 代码里实际接受的参数 | `DeepSleep/AppDelegate.swift` |
| 文档里的协议命令表 ↔ 协议枚举 | `Shared/HelperProtocol.swift` |
| 文档里的 URL 命令表 ↔ `DeepSleepURL.commands` | `DeepSleep/Core/URLCommands.swift` |
| 文档里的保护名单表 ↔ 硬编码名单 | `Shared/ProcessGuard.swift` |
| Siri 短语的两份写法 ↔ 彼此（编译期 / 展示目录） | `DeepSleep/Intents/DeepSleepAppShortcuts.swift` |
| 文档里的版本号 ↔ 工程配置 | `project.yml` |
| 文档里引用的文件路径是否都存在 | 文件系统 |
| 用户可见文案里有没有被转义的插值 `\\(`（会原样显示） | 全部 Swift 源码 |
| `README.md` 里有没有 AI 味的句式（套话、对偶句、破折号堆叠） | `README.md` |

不一致会打印出具体差异并以非 0 退出。

### 机制一之补：校验器自己也要能被否定

```sh
python3 scripts/test-check-docs.py
```

它把仓库复制到临时目录，**逐条把文档/代码改坏**，要求上面的检查每次都拦下来；
最后再跑一次未改动的副本，要求退出码为 0（证明没有假阳性）。
一个永远打印「✓ 一致」的检查脚本比没有检查更危险 —— 它会让人以为文档同步了。

### 机制二：机器查不了的，定好触发条件

| 改了什么 | 必须同步 |
| --- | --- |
| 新增 / 删除 CLI 参数 | `README.md` 的参数表 + `docs/architecture.md` |
| 新增 / 删除协议命令 | `docs/architecture.md` + `HelperProtocol.swift` 里的注释 |
| 新增 / 删除 URL 命令 | `docs/architecture.md` 的 URL 命令表 + `README.md` 的 URL 一节 |
| 新增 / 删除 Siri 短语或快捷指令动作 | `DeepSleepAppShortcuts.swift` 里的**两处**（编译期短语 + 展示目录） |
| 改快速退出的保护名单 | `docs/architecture.md` 第六节的名单表 + `scripts/test-process-guard.swift` |
| 改了断言语义或对账范围 | `docs/architecture.md` |
| 改了发布流程 | `docs/release.md` |
| 改了安装 / 卸载脚本的行为 | `docs/architecture.md` 的权限模型一节 |
| 用户可见的文案 | 不要写 `\\(`（会被原样显示）；不要写 AI 味的句式；写完跑一次 `check-docs.py` |
| 踩到新坑 | `docs/gotchas.md`（**当场记**，别攒着 —— 攒着就忘了） |

### 一条贯穿全项目的原则：少写会变的数字

文档里**不要写行号**（行号天天变），**尽量少写具体数值**。
需要引用时写符号名（`HelperConstants.socketPath`）而不是它的值。

这条原则不只适用于文档，也适用于代码 —— 项目里有两处刻意这么设计：

- 助手是否需要更新，看**两份二进制的内容摘要**，而不是需要人维护的构建号；
- 应用是否需要更新，看**版本号**（本来每次发布就会改），而不是额外的发布序号。

判据能自动推导，就不会因为人忘了维护而失效。文档同理：
能被 `check-docs.py` 检查的东西，就不会因为人忘了更新而误导。

---

## 这个项目的几条硬约定

**给用户看的文字要写得像人话**：README、更新日志、Release 说明要简洁、自然、能直接扫读，
列功能与用法，或者列这次改了什么。根因分析、排查过程、验证细节都放开发文档里，
不往用户面前搬。具体要求见 [release.md](release.md) 的「发布说明怎么写」。

写代码前先知道这些，能省很多返工：

1. **注释解释「为什么」，不解释「是什么」。**
   `// 把值设为 1` 这种注释是噪音；`// 必须用 TAB 切分，见 gotchas.md` 才是资产。
2. **不用 SMJobBless。** 用 `osascript ... with administrator privileges` 装一次，
   之后靠常驻助手免密。原因见 [architecture.md](architecture.md)。
3. **归因要诚实。** 查不到「是谁改了设置」就说查不到，不给一个猜的进程名。
4. **危险动作要能静态检查。** 以 root 运行的脚本放在 `Resources/` 下单独成文件
   （而不是内联进 Swift 字符串），以便 `sh -n` 和 dry-run 检查。
   替换应用的更新器脚本也能用 `--update-script` 打印出来审。
5. **改了行为就同步文档。** 上面两张表是清单。
