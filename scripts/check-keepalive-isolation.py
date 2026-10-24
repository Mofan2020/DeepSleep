#!/usr/bin/env python3
"""
保活模块的独立性检查。

**为什么需要它**：网关（LLMGateway）那块功能随时可能被关停或彻底移除 ——
它会在本机开端口、转发请求，暴露面大，值不值得留还没定。
保活必须能在网关消失之后照常工作，所以它不能依赖网关的任何类型。

这个脚本是这条约束的守卫：一旦保活里出现对网关的引用，它就失败。

检查项：
  1. `DeepSleep/AIKeepAlive/` 下不许 import 或引用任何网关类型
  2. 保活不许依赖网关目录下的文件（编译依赖检查）
  3. 网关目录整体不参与 App 构建（project.yml 的 excludes）

用法：
    python3 scripts/check-keepalive-isolation.py

不一致时打印具体差异并以 1 退出。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEEPALIVE_DIR = "DeepSleep/AIKeepAlive"

failures = []


def section(title):
    print(f"\n[{title}]")


def read(relative_path):
    full = os.path.join(ROOT, relative_path)
    if not os.path.exists(full):
        failures.append(f"文件不存在：{relative_path}")
        return ""
    with open(full, encoding="utf-8") as handle:
        return handle.read()


# 网关里那些「通用到可能被人顺手复用」的类型名。
# 保活一旦用了其中任何一个，就说明耦合又回去了。
GATEWAY_TYPES = [
    "LLMGatewayError",
    "KeychainStore",
    "HTTPClient",
    "HTTPRequest",
    "HTTPResponse",
    "GatewayConfig",
    "GatewayDatabase",
    "GatewayController",
    "GatewayServer",
    "QuotaPoller",
    "ProviderConfig",
    "QuotaWindow",
    "LLMPlatform",
    "BillingMode",
    "LLMGatewayFeature",
    "GatewayDisclaimer",
]


def check_no_gateway_types():
    section("保活不引用网关类型")

    if not os.path.isdir(os.path.join(ROOT, KEEPALIVE_DIR)):
        failures.append(f"找不到目录：{KEEPALIVE_DIR}")
        return

    files = sorted(
        name for name in os.listdir(os.path.join(ROOT, KEEPALIVE_DIR))
        if name.endswith(".swift")
    )
    print(f"  检查了 {len(files)} 个文件")

    hits = []
    for name in files:
        path = os.path.join(KEEPALIVE_DIR, name)
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            # 注释里提到网关是正常的 —— 那是解释「为什么不复用」。
            if stripped.startswith("//"):
                continue
            for type_name in GATEWAY_TYPES:
                # `KeepAliveHTTPClient` 里含 "HTTPClient"，但那是保活自己的。
                if type_name in ("HTTPClient", "HTTPRequest", "HTTPResponse"):
                    pattern = r"(?<!KeepAlive)\b" + type_name + r"\b"
                elif type_name == "KeychainStore":
                    pattern = r"(?<!KeepAlive)\bKeychainStore\b"
                else:
                    pattern = r"\b" + type_name + r"\b"
                if re.search(pattern, line):
                    hits.append(f"{path}:{number} 用了 {type_name}")

    if hits:
        failures.append(
            "保活模块引用了网关的类型（网关随时可能被移除，保活必须能独立工作）："
            + "；".join(hits)
        )
    else:
        print("  ✓ 没有引用任何网关类型")


def check_keepalive_files_are_independent():
    section("保活自带的文件")
    expected = [
        "KeepAliveModels.swift",
        "KeepAliveError.swift",
        "KeepAliveHTTP.swift",
        "KeepAliveKeychain.swift",
        "KeepAliveStore.swift",
        "KeepAliveClient.swift",
        "KeepAliveEngine.swift",
        "KeepAliveView.swift",
    ]
    actual = sorted(
        name for name in os.listdir(os.path.join(ROOT, KEEPALIVE_DIR))
        if name.endswith(".swift")
    )
    missing = [name for name in expected if name not in actual]
    if missing:
        failures.append(
            "保活目录缺少文件（这些是它自带的 HTTP / Keychain / 错误类型）："
            + "、".join(missing)
        )
    else:
        print(f"  ✓ {len(expected)} 个文件都在")


def check_gateway_not_built():
    section("网关不参与 App 构建")
    project = read("project.yml")
    if not project:
        return
    # 网关目录必须出现在 excludes 里。
    if re.search(r'^\s*-\s*"LLMGateway"\s*$', project, re.MULTILINE):
        print("  ✓ project.yml 里 LLMGateway 在 excludes 中")
    else:
        failures.append(
            "project.yml 里没有把 LLMGateway 排除出构建 —— "
            "网关会跟着产物一起发布，用户看不到入口却背着这段代码"
        )


def check_gateway_still_in_repo():
    section("网关源码仍在仓库里")
    # 网关是「隐藏」不是「删除」—— 源码要留着，将来决定了去留再处理。
    gateway_dir = os.path.join(ROOT, "DeepSleep/LLMGateway")
    if not os.path.isdir(gateway_dir):
        failures.append(
            "DeepSleep/LLMGateway/ 不见了 —— 当前状态是「隐藏」而不是「删除」，"
            "源码要留着"
        )
        return
    count = sum(
        1 for _, _, files in os.walk(gateway_dir) for f in files if f.endswith(".swift")
    )
    print(f"  ✓ 网关源码仍在（{count} 个 swift 文件）")


def main():
    print("保活模块独立性检查")
    print("=" * 46)

    check_no_gateway_types()
    check_keepalive_files_are_independent()
    check_gateway_not_built()
    check_gateway_still_in_repo()

    print()
    print("=" * 46)
    if failures:
        print(f"结论：{len(failures)} 项不一致\n")
        for index, item in enumerate(failures, 1):
            print(f"  {index}. {item}")
        print("\n保活必须能脱离网关独立工作。")
        return 1

    print("结论：全部一致 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
