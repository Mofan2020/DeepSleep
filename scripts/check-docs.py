#!/usr/bin/env python3
"""
文档与代码一致性检查。

存在的理由：**过期的文档比没有文档更糟** —— 它不只是没帮上忙，
而是会把人引到错的方向。靠「记得更新」是治不住的，只能靠机器查。

检查项：
  1. CLI 参数    AppDelegate 里接受的参数  ↔  README.md 的参数表
  2. 协议命令    HelperCommand 枚举        ↔  docs/architecture.md 的命令表
  3. 版本号      project.yml               ↔  README.md
  4. 文件引用    文档里提到的项目文件是否都存在

用法：
    python3 scripts/check-docs.py

不一致时打印具体差异并以 1 退出。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures = []
notes = []


def read(relative_path):
    """读取项目内文件，不存在则记为失败。"""
    full = os.path.join(ROOT, relative_path)
    if not os.path.exists(full):
        failures.append(f"文件不存在：{relative_path}")
        return ""
    with open(full, encoding="utf-8") as handle:
        return handle.read()


def section(title):
    print(f"\n[{title}]")


# ---------------------------------------------------------------- CLI 参数

def check_cli_arguments():
    section("CLI 参数")

    source = read("DeepSleep/AppDelegate.swift")
    in_code = set(re.findall(r'case\s+"(--[a-z0-9-]+)"', source))

    doc = read("README.md")
    # 表格行形如：| `--hold <kinds>` | 说明 |
    in_doc = set(re.findall(r'^\|\s*`(--[a-z0-9-]+)', doc, re.MULTILINE))

    print(f"  代码中 {len(in_code)} 个，README 中 {len(in_doc)} 个")

    missing_in_doc = sorted(in_code - in_doc)
    missing_in_code = sorted(in_doc - in_code)

    if missing_in_doc:
        failures.append(
            "这些参数代码里有、README.md 的参数表里没有："
            + ", ".join(missing_in_doc))
    if missing_in_code:
        failures.append(
            "这些参数 README.md 里写了、代码里没有："
            + ", ".join(missing_in_code))
    if not missing_in_doc and not missing_in_code:
        print("  ✓ 一致")


# ---------------------------------------------------------------- 协议命令

def check_protocol_commands():
    section("协议命令")

    source = read("Shared/HelperProtocol.swift")
    block = re.search(
        r"public enum HelperCommand[^{]*\{(.*?)\n\}", source, re.DOTALL)
    if not block:
        failures.append("无法从 HelperProtocol.swift 里解析出 HelperCommand 枚举")
        return

    in_code = set(re.findall(
        r"^\s*case\s+([a-zA-Z][a-zA-Z0-9]*)", block.group(1), re.MULTILINE))

    doc = read("docs/architecture.md")
    # 命令表行形如：| `ping` | 存活探测 |
    # 只在「协议命令一览」这一节里找 —— 文档里还有别的表（关键常量等），
    # 全局扫表格行会把它们当成命令，产生假阳性。
    section_text = re.search(
        r"### 协议命令一览\n(.*?)(?=\n## |\n### |\Z)", doc, re.DOTALL)
    if not section_text:
        failures.append(
            "docs/architecture.md 里找不到「### 协议命令一览」一节 —— "
            "该节是 check-docs.py 的检查依据，不要删也不要改标题")
        return
    in_doc = set(re.findall(
        r"^\|\s*`([a-zA-Z][a-zA-Z0-9]*)`\s*\|", section_text.group(1),
        re.MULTILINE))

    print(f"  代码中 {len(in_code)} 个，文档中 {len(in_doc)} 个")

    missing_in_doc = sorted(in_code - in_doc)
    missing_in_code = sorted(in_doc - in_code)

    if missing_in_doc:
        failures.append(
            "这些命令代码里有、docs/architecture.md 的命令表里没有："
            + ", ".join(missing_in_doc))
    if missing_in_code:
        failures.append(
            "这些命令文档里写了、代码里没有："
            + ", ".join(missing_in_code))
    if not missing_in_doc and not missing_in_code:
        print("  ✓ 一致")


# ---------------------------------------------------------------- 版本号

def check_version():
    section("版本号")

    project = read("project.yml")
    match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project)
    if not match:
        failures.append("project.yml 里找不到 MARKETING_VERSION")
        return
    code_version = match.group(1)

    readme = read("README.md")
    match = re.search(r"\*\*当前版本\*\*：([0-9][0-9.]*)", readme)
    if not match:
        failures.append(
            "README.md 里找不到「**当前版本**：x.y.z」—— "
            "该行是 check-docs.py 的检查依据，不要改格式")
        return
    doc_version = match.group(1)

    print(f"  project.yml: {code_version}")
    print(f"  README.md:   {doc_version}")

    if code_version != doc_version:
        failures.append(
            f"版本号不一致：project.yml 是 {code_version}，README.md 写的是 {doc_version}")
    else:
        print("  ✓ 一致")

    # 版本格式：纯数字三段式。带字母的版本号会让自动更新静默失效。
    if not re.fullmatch(r"\d+\.\d+\.\d+", code_version):
        failures.append(
            f"版本号「{code_version}」不是纯数字三段式 —— "
            "带字母的版本号解析不了，自动更新会静默不生效")


# ---------------------------------------------------------------- 文件引用

# 文档里被反引号包起来、且看起来像项目内相对路径的东西
FILE_REFERENCE = re.compile(
    r"`((?:DeepSleep|DeepSleepHelper|Shared|docs|scripts)/[\w./-]+"
    r"\.(?:swift|sh|py|md|yml|plist))`")

# 允许引用但不要求存在的（生成物、示例）
IGNORED_PREFIXES = (
    "build/",
)


def check_file_references():
    section("文件引用")

    documents = ["README.md"] + [
        f"docs/{name}" for name in sorted(os.listdir(os.path.join(ROOT, "docs")))
        if name.endswith(".md")
    ]

    referenced = {}
    for document in documents:
        text = read(document)
        for reference in FILE_REFERENCE.findall(text):
            if reference.startswith(IGNORED_PREFIXES):
                continue
            referenced.setdefault(reference, []).append(document)

    missing = []
    for reference, sources in sorted(referenced.items()):
        if not os.path.exists(os.path.join(ROOT, reference)):
            missing.append(f"{reference}（被 {', '.join(sorted(set(sources)))} 引用）")

    print(f"  检查了 {len(referenced)} 个文件引用，来自 {len(documents)} 份文档")

    if missing:
        for item in missing:
            failures.append(f"引用了不存在的文件：{item}")
    else:
        print("  ✓ 全部存在")


# ---------------------------------------------------------------- 文档存在性

def check_documents_exist():
    section("文档完整性")

    required = [
        "docs/README.md",
        "docs/architecture.md",
        "docs/maintenance.md",
        "docs/release.md",
        "docs/gotchas.md",
    ]
    missing = [name for name in required
               if not os.path.exists(os.path.join(ROOT, name))]

    if missing:
        failures.append("缺少文档：" + ", ".join(missing))
    else:
        print(f"  ✓ 五份核心文档都在（{len(required)} 份）")


# ---------------------------------------------------------------- 主流程

def main():
    print("文档一致性检查")
    print("=" * 46)

    check_documents_exist()
    check_cli_arguments()
    check_protocol_commands()
    check_version()
    check_file_references()

    print()
    print("=" * 46)
    if failures:
        print(f"结论：{len(failures)} 项不一致\n")
        for index, item in enumerate(failures, 1):
            print(f"  {index}. {item}")
        print("\n文档与代码不一致。请更新文档，或修正上面的解析假设。")
        print("同步清单见 docs/README.md 的两张表。")
        return 1

    print("结论：全部一致 ✓")
    for note in notes:
        print(f"  提示：{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
