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
       Shared/TerminationReport.swift scripts/test-process-guard.swift \
       -o /tmp/t4 && /tmp/t4
# 期望：四个都「测试结论: 全部通过」

# 端到端自检
open -a "build/Build/Products/Release/Deep Sleep.app" \
     --args --wait 8 --status --blockers --rivals --helper-version
```

### 第 4 步：提交并打 tag

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
   --notes-file /tmp/release-notes.md
```

- **`--notes-file` 推荐用文件**，命令行里塞多行说明很容易出错
- **不要加 `--prerelease`**（除非确实想这样）。虽然应用侧改成了拉列表、
  能识别预发布，但标成正式版能让 `/releases/latest` 这类标准接口也正常工作
- 资产名必须是 `DeepSleep.zip`。改名字会让所有已发布的旧版本找不到更新

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

> 这个表**每次发版都要加一行**。它是给未来的人判断「哪个版本引入了什么」用的，
> 不维护的话，排查老版本问题时就没有参照。
