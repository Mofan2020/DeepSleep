#!/usr/bin/env python3
"""
文档与代码一致性检查。

存在的理由：**过期的文档比没有文档更糟** —— 它不只是没帮上忙，
而是会把人引到错的方向。靠「记得更新」是治不住的，只能靠机器查。

检查项：
  1. CLI 参数    AppDelegate 里接受的参数  ↔  README.md 的参数表
  2. 协议命令    HelperCommand 枚举        ↔  docs/architecture.md 的命令表
  3. URL 命令    DeepSleepURL.commands     ↔  docs/architecture.md 的命令表
  4. Siri 短语   编译期短语                 ↔  展示用目录（同一文件里两份）
  5. 保护名单    ProcessGuard 硬名单        ↔  docs/architecture.md 的名单表
  6. 版本号      project.yml               ↔  README.md
  7. 文件引用    文档里提到的项目文件是否都存在
  8. 转义插值    Swift 源码里写错的 `\\(`（用户可见文案会原样显示）
  9. 文案        README.md 有没有 AI 味的句式（用户第一眼看到的就是它）

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


def compare_sets(label, in_code, in_doc, missing_in_doc_hint, missing_in_code_hint):
    """比较两组名字并登记差异。返回是否一致。"""
    print(f"  代码中 {len(in_code)} 个，文档中 {len(in_doc)} 个")

    missing_in_doc = sorted(in_code - in_doc)
    missing_in_code = sorted(in_doc - in_code)

    if missing_in_doc:
        failures.append(missing_in_doc_hint + ", ".join(missing_in_doc))
    if missing_in_code:
        failures.append(missing_in_code_hint + ", ".join(missing_in_code))
    if not missing_in_doc and not missing_in_code:
        print("  ✓ 一致")
        return True
    return False


# ---------------------------------------------------------------- CLI 参数

def check_cli_arguments():
    section("CLI 参数")

    source = read("DeepSleep/AppDelegate.swift")
    in_code = set(re.findall(r'case\s+"(--[a-z0-9-]+)"', source))

    doc = read("README.md")
    # 表格行形如：| `--hold <kinds>` | 说明 |
    in_doc = set(re.findall(r'^\|\s*`(--[a-z0-9-]+)', doc, re.MULTILINE))

    compare_sets(
        "CLI 参数", in_code, in_doc,
        "这些参数代码里有、README.md 的参数表里没有：",
        "这些参数 README.md 里写了、代码里没有：")


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

    compare_sets(
        "协议命令", in_code, in_doc,
        "这些命令代码里有、docs/architecture.md 的命令表里没有：",
        "这些命令文档里写了、代码里没有：")


# ---------------------------------------------------------------- URL 命令

def check_url_commands():
    section("URL 命令")

    source = read("DeepSleep/Core/URLCommands.swift")
    block = re.search(
        r"static let commands:\s*\[Command\]\s*=\s*\[(.*?)\n\s*\]",
        source, re.DOTALL)
    if not block:
        failures.append(
            "无法从 DeepSleep/Core/URLCommands.swift 里解析出 commands 表")
        return

    in_code = set(re.findall(r'Command\(name:\s*"([^"]+)"', block.group(1)))

    doc = read("docs/architecture.md")
    section_text = re.search(
        r"### URL 命令一览\n(.*?)(?=\n## |\n### |\Z)", doc, re.DOTALL)
    if not section_text:
        failures.append(
            "docs/architecture.md 里找不到「### URL 命令一览」一节 —— "
            "该节是 check-docs.py 的检查依据，不要删也不要改标题")
        return
    in_doc = set(re.findall(
        r"^\|\s*`([a-z][a-z0-9-]*)`\s*\|", section_text.group(1),
        re.MULTILINE))

    compare_sets(
        "URL 命令", in_code, in_doc,
        "这些 URL 命令代码里有、docs/architecture.md 的命令表里没有：",
        "这些 URL 命令文档里写了、代码里没有：")

    # README 是用户可见文档：至少要提到这个 scheme，否则用户不知道有这条路。
    readme = read("README.md")
    if "deepsleep://" not in readme:
        failures.append("README.md 里没有出现 `deepsleep://` —— 用户看不到 URL 这条通道")


# ---------------------------------------------------------------- Siri 短语

def check_shortcut_phrases():
    section("Siri 短语")

    source = read("DeepSleep/Intents/DeepSleepAppShortcuts.swift")

    def canonical(phrase):
        """两份短语的占位符写法不同，统一成同一个记号再比。"""
        return (phrase.replace("{应用名}", "{APP}")
                      .replace("\\(.applicationName)", "{APP}"))

    # 编译期短语（给系统用）
    typed = {}
    for match in re.finditer(
            r"AppShortcut\(\s*intent:\s*\w+\(\),\s*phrases:\s*\[(.*?)\],\s*"
            r"shortTitle:\s*\"([^\"]+)\",\s*systemImageName:\s*\"([^\"]+)\"",
            source, re.DOTALL):
        phrases = {canonical(p) for p in re.findall(r'"([^"]+)"', match.group(1))}
        typed[match.group(2)] = (match.group(3), phrases)

    # 展示用目录（给界面、--automation 与文档用）
    catalog = {}
    for match in re.finditer(
            r"Entry\(title:\s*\"([^\"]+)\",\s*symbol:\s*\"([^\"]+)\",\s*"
            r"phrases:\s*\[(.*?)\]",
            source, re.DOTALL):
        phrases = {canonical(p) for p in re.findall(r'"([^"]+)"', match.group(3))}
        catalog[match.group(1)] = (match.group(2), phrases)

    if not typed or not catalog:
        failures.append(
            "无法从 DeepSleepAppShortcuts.swift 里解析出两份短语 "
            f"（编译期 {len(typed)} 条 / 目录 {len(catalog)} 条）—— "
            "解析假设可能已过期，请检查 AppShortcut(...) 与 Entry(...) 的写法")
        return

    print(f"  编译期 {len(typed)} 组，目录 {len(catalog)} 组")

    only_typed = sorted(set(typed) - set(catalog))
    only_catalog = sorted(set(catalog) - set(typed))
    if only_typed:
        failures.append("这些短语只有编译期那份、展示目录里没有：" + ", ".join(only_typed))
    if only_catalog:
        failures.append("这些短语只有展示目录那份、编译期没有（说出去不会生效）："
                        + ", ".join(only_catalog))

    for title in sorted(set(typed) & set(catalog)):
        typed_symbol, typed_phrases = typed[title]
        catalog_symbol, catalog_phrases = catalog[title]
        if typed_symbol != catalog_symbol:
            failures.append(
                f"「{title}」的图标不一致：编译期 {typed_symbol} / 目录 {catalog_symbol}")
        if typed_phrases != catalog_phrases:
            failures.append(
                f"「{title}」的短语不一致：编译期 {sorted(typed_phrases)} / "
                f"目录 {sorted(catalog_phrases)}")

    if not (only_typed or only_catalog):
        print("  ✓ 两份一一对应")


# ---------------------------------------------------------------- 保护名单

def check_process_guard_lists():
    section("保护名单")

    source = read("Shared/ProcessGuard.swift")

    def literal_set(name):
        block = re.search(
            rf"public static let {name}:\s*Set<String>\s*=\s*\[(.*?)\n\s*\]",
            source, re.DOTALL)
        if not block:
            return None
        return set(re.findall(r'"([^"]+)"', block.group(1)))

    names = literal_set("protectedNames")
    bundles = literal_set("protectedBundleIDs")
    if names is None or bundles is None:
        failures.append("无法从 Shared/ProcessGuard.swift 里解析出保护名单")
        return

    doc = read("docs/architecture.md")
    section_text = re.search(
        r"### 受保护的系统进程（快速退出的硬名单）\n(.*?)(?=\n## |\Z)",
        doc, re.DOTALL)
    if not section_text:
        failures.append(
            "docs/architecture.md 里找不到「### 受保护的系统进程（快速退出的硬名单）」一节 —— "
            "该节是 check-docs.py 的检查依据，不要删也不要改标题")
        return

    doc_names, doc_bundles = set(), set()
    for line in section_text.group(1).splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 2 or cells[0] in ("分组", "---") or set(cells[0]) == {"-"}:
            continue
        for token in re.findall(r"`([^`]+)`", cells[1]):
            # 带点的是 bundle id，其余是进程名（都按代码里的写法小写）
            (doc_bundles if "." in token else doc_names).add(token)

    compare_sets(
        "保护名单", names, doc_names,
        "这些进程名代码里有、docs/architecture.md 的名单表里没有：",
        "这些进程名文档里写了、代码里没有：")
    compare_sets(
        "保护 bundle id", bundles, doc_bundles,
        "这些 bundle id 代码里有、docs/architecture.md 的名单表里没有：",
        "这些 bundle id 文档里写了、代码里没有：")


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


# ---------------------------------------------------------------- 转义插值

def check_literal_interpolation():
    """扫「被转义掉的插值」：写成 `\\(` 时编译器不报错，但用户会看到原文。

    只有同时带双引号的行才算 —— 注释里用反引号举例子
    （`` `\\(.applicationName)` ``）是正常写法，不该误报。
    """
    section("转义插值")

    hits = []
    for folder, subfolders, files in os.walk(ROOT):
        subfolders[:] = [name for name in subfolders
                         if name not in (".git", "build", "release")]
        if folder.endswith(".xcodeproj"):
            continue
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle.read().splitlines(), 1):
                    stripped = line.strip()
                    if stripped.startswith(("//", "*", "/*")):
                        continue
                    if '"' in line and "\\\\(" in line:
                        hits.append(f"{os.path.relpath(path, ROOT)}:{number}")

    if hits:
        failures.append(
            "这些行里的 Swift 插值被转义成了普通文本（界面/日志会原样显示 `\\(...)`）："
            + ", ".join(hits))
    else:
        print("  ✓ 没有发现被转义的插值")


# ---------------------------------------------------------------- 文案

# 用户打开这个项目，第一眼看到的就是 README 与发布说明。那种「AI 写的」
# 腔调会让人失去耐心直接走人，所以它值得被机器拦一道。
#
# 只查 README：docs/ 下面几份是给改代码的人看的，写详细一点没关系。
#
# 词表刻意短。这些是最容易识别的套话，误伤正常中文的可能性低 ——
# 一条总在冤枉正常句子的检查，最后一定会被人关掉。
AI_PHRASES = [
    "不仅仅是", "不仅是", "此外，", "值得一提的是", "值得注意的是",
    "至关重要", "综上所述", "显而易见", "众所周知", "彰显", "奠定了",
    "见证了", "总而言之", "不可否认", "归根结底",
]

# 「不是 X，而是 Y」：AI 爱用的对偶句，中文写作里偶有正当用法，
# 但成段出现就是腔调问题。
AI_PATTERNS = [
    (r"不是[^，。！？\n]{1,24}，而是", "「不是……而是……」对偶句"),
]

# 长破折号允许少量（正常中文会用它补充说明），靠它撑句子就会成排出现。
MAX_EM_DASHES = 2


def check_prose():
    section("文案")

    text = read("README.md")
    if not text:
        return False

    problems = [f"AI 味短语「{phrase}」" for phrase in AI_PHRASES if phrase in text]

    for pattern, label in AI_PATTERNS:
        if re.search(pattern, text):
            problems.append(label)

    dashes = text.count("——")
    if dashes > MAX_EM_DASHES:
        problems.append(f"长破折号 {dashes} 处（上限 {MAX_EM_DASHES}）")

    if problems:
        failures.append("README 的文字读起来像 AI 写的，改成人话：" + "；".join(problems))
        return False

    print("  ✓ README 没有发现 AI 味句式")
    return True


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
    check_url_commands()
    check_shortcut_phrases()
    check_process_guard_lists()
    check_version()
    check_file_references()
    check_literal_interpolation()
    check_prose()

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
