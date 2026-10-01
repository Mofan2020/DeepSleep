#!/usr/bin/env python3
"""负向测试：把文档/代码故意改坏，确认 `scripts/check-docs.py` 真的会拦下来。

存在的理由（项目的一条原则）：**不能被否定的校验等于没有校验**。
一个永远打印「✓ 一致」的检查脚本，比没有检查更危险 ——
它会让人以为文档是同步的，从而不再人工过一眼。

做法：把仓库复制到临时目录，在副本上逐条制造「文档与代码不一致」，
每次都要求 check-docs.py 以非 0 退出并打印出对应的差异；最后再跑一次
未改动的副本，要求退出码为 0（证明没有假阳性）。

用法：
    python3 scripts/test-check-docs.py

输出沿用项目里其它测试的格式：`[通过]` / `[失败]` + 末尾 `测试结论: ...`。
"""

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 每条用例：说明 / 文件 / 原文 / 改成 / 期望出现在输出里的关键词
CASES = [
    ("保护名单：文档里漏掉一个进程名",
     "docs/architecture.md",
     "`dock`、`finder`、`systemuiserver`", "`dock`、`systemuiserver`",
     "finder"),

    ("保护名单：文档里多写一个不存在的进程名",
     "docs/architecture.md",
     "`launchd`、`kernel_task`、`watchdogd`",
     "`launchd`、`kernel_task`、`watchdogd`、`not-a-real-process`",
     "not-a-real-process"),

    ("URL 命令：文档里的命令名与代码不一致",
     "docs/architecture.md",
     "| `quick-quit` |", "| `quick-quit-typo` |",
     "quick-quit"),

    ("Siri 短语：目录里改掉一句短语",
     "DeepSleep/Intents/DeepSleepAppShortcuts.swift",
     '"用 {应用名} 快速退出"', '"用 {应用名} 赶紧退出"',
     "短语不一致"),

    ("Siri 短语：只改了编译期那份的标题",
     "DeepSleep/Intents/DeepSleepAppShortcuts.swift",
     'shortTitle: "允许睡眠",', 'shortTitle: "允许睡眠（改了）",',
     "允许睡眠（改了）"),

    ("CLI 参数：README 的参数表里删掉一行",
     "README.md",
     "| `--hotkey-status` | 打印快速退出快捷键的注册状态（排查「按了没反应」） |\n",
     "",
     "--hotkey-status"),

    ("版本号：README 与 project.yml 不一致",
     "README.md",
     "- **当前版本**：", "- **当前版本**：0.0.1  <!-- ",
     "版本号不一致"),

    ("转义插值：界面文案里多写一个反斜杠",
     "DeepSleep/Views/QuickQuitView.swift",
     r'"名单 \(engine.targets.count) 个应用"',
     r'"名单 \\(engine.targets.count) 个应用"',
     "转义"),

    ("协议命令：文档里的命令名与枚举不一致",
     "docs/architecture.md",
     "| `terminateProcesses` |", "| `terminateProcessesX` |",
     "terminateProcesses"),

    ("文件引用：文档里引用一个不存在的文件",
     "docs/maintenance.md",
     "`scripts/test-process-guard.swift`",
     "`scripts/test-does-not-exist.swift`",
     "test-does-not-exist.swift"),

    ("标题被改名：检查依据的节标题不在了",
     "docs/architecture.md",
     "### URL 命令一览", "### URL 命令（改过标题）",
     "找不到"),

    ("文案：README 里混进 AI 味短语",
     "README.md",
     "## 已知限制",
     "## 已知限制\n\n值得注意的是，此外，这个功能不仅仅是修补。\n",
     "AI 味短语"),

    ("文案：README 里靠长破折号撑句子",
     "README.md",
     "## 已知限制",
     "## 已知限制\n\n甲——乙——丙——丁\n",
     "长破折号"),
]


def prepare(work):
    if os.path.exists(work):
        shutil.rmtree(work)
    shutil.copytree(
        ROOT, work,
        ignore=shutil.ignore_patterns(".git", "build", "release", "*.xcodeproj"))


def run_checker(work):
    result = subprocess.run(
        [sys.executable, "scripts/check-docs.py"], cwd=work,
        capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def main():
    print("负向测试：故意改坏文档/代码，确认 check-docs.py 会拦")
    print("=" * 52)

    work = os.path.join(tempfile.gettempdir(), "deepsleep-check-docs-negative")
    passed = failed = 0

    for description, path, old, new, keyword in CASES:
        prepare(work)
        full = os.path.join(work, path)
        with open(full, encoding="utf-8") as handle:
            text = handle.read()

        if old not in text:
            print(f"[失败] {description}")
            print("       用例本身失效：原文没找到，需要同步这个测试的假设")
            failed += 1
            continue

        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text.replace(old, new, 1))

        code, output = run_checker(work)
        if code != 0 and keyword in output:
            print(f"[通过] {description} → 被拦下（退出码 {code}）")
            passed += 1
        else:
            hit = "命中" if keyword in output else "没出现"
            print(f"[失败] {description} → 没拦住"
                  f"（退出码 {code}，关键词「{keyword}」{hit}）")
            failed += 1

    # 反面用例：没有改动时必须退出 0，否则检查脚本有假阳性
    prepare(work)
    code, output = run_checker(work)
    if code == 0:
        print("[通过] 未改动的副本 → 退出码 0（没有假阳性）")
        passed += 1
    else:
        print(f"[失败] 未改动的副本不该失败，实际退出码 {code}")
        print(output)
        failed += 1

    print("=" * 52)
    print(f"测试结论: {passed} 项通过，{failed} 项失败")

    shutil.rmtree(work, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
