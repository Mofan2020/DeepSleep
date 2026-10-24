#!/bin/bash
# DeepSleep 全量自测回归
# 用法：bash scripts/run-all-tests.sh
# 每个脚本的编译依赖不统一，失败时打印命令供人工排查。

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
PASS=0
FAIL=0
FAILED_LIST=()

run() {
    local name="$1"; shift
    local out
    out=$("$@" 2>&1)
    local code=$?
    local ok_count failed_count
    # 两种断言风格：逐项 [通过]/[失败]（check 函数）与整体 OK/FAIL（probe 风格）
    ok_count=$(printf '%s' "$out" | grep -cE '\[通过\]|^OK:')
    failed_count=$(printf '%s' "$out" | grep -cE '\[失败\]|^FAIL')
    if [ $code -eq 0 ]; then
        printf '  ✓ %-42s 通过 %s 项\n' "$name" "$ok_count"
        PASS=$((PASS + ok_count))
    else
        printf '  ✗ %-42s 退出码 %s（失败 %s 项）\n' "$name" "$code" "$failed_count"
        printf '%s\n' "$out" | grep '\[失败\]' | head -5 | sed 's/^/      /'
        FAILED_LIST+=("$name")
        FAIL=$((FAIL + 1))
    fi
}

build_and_run() {
    local name="$1"; local outbin="$2"; shift 2
    if ! swiftc -parse-as-library "$@" -o "$outbin" 2>/tmp/ds_compile_err.txt; then
        printf '  ✗ %-42s 编译失败\n' "$name"
        head -8 /tmp/ds_compile_err.txt | sed 's/^/      /'
        FAILED_LIST+=("$name")
        FAIL=$((FAIL + 1))
        return
    fi
    run "$name" "$outbin"
}

echo "=== DeepSleep 自测回归 ==="

build_and_run "version-compare"      /tmp/t_version  Shared/Version.swift scripts/test-version-compare.swift
build_and_run "nice-page-size"       /tmp/t_nice     Shared/NicePageSize.swift scripts/test-nice-page-size.swift
build_and_run "hosts-allowed-editors" /tmp/t_hosts   Shared/HelperProtocol.swift Shared/HostsAllowedEditors.swift scripts/test-hosts-allowed-editors.swift
build_and_run "pmset-parse"          /tmp/t_pmset    Shared/PMSetOutput.swift scripts/test-pmset-parse.swift
build_and_run "process-guard"        /tmp/t_guard    Shared/ProcessInventory.swift Shared/ProcessGuard.swift Shared/ProcessPriority.swift Shared/TerminationReport.swift scripts/test-process-guard.swift
build_and_run "process-snapshot"     /tmp/t_snap     Shared/ProcessStats.swift Shared/HelperProtocol.swift Shared/ProcessSnapshot.swift Shared/ProcessPriority.swift Shared/ProcessInventory.swift scripts/test-process-snapshot.swift
build_and_run "process-stats"        /tmp/t_stats    Shared/ProcessStats.swift scripts/test-process-stats.swift
build_and_run "servermode-fsm"       /tmp/t_smode    Shared/ServerModeIdlePolicy.swift scripts/test-servermode-fsm.swift
build_and_run "keepalive-url"        /tmp/t_kaurl    DeepSleep/AIKeepAlive/KeepAliveModels.swift scripts/test-keepalive-url.swift
build_and_run "toolbox-layout"       /tmp/t_tblay    DeepSleep/Views/ToolboxLayout.swift DeepSleep/LLMGateway/Database/QuotaModels.swift DeepSleep/LLMGateway/Database/GatewayConfigStore.swift scripts/test-toolbox-layout.swift
build_and_run "toolbox-gate"         /tmp/t_tbgate   DeepSleep/Views/ToolboxLayout.swift DeepSleep/AIKeepAlive/KeepAliveModels.swift DeepSleep/AIKeepAlive/KeepAliveStore.swift DeepSleep/LLMGateway/KeychainStore.swift DeepSleep/LLMGateway/Database/QuotaModels.swift DeepSleep/LLMGateway/Database/GatewayConfigStore.swift DeepSleep/LLMGateway/GatewayDisclaimer.swift scripts/test-toolbox-gate.swift
build_and_run "keepalive-schedule"   /tmp/t_kasch    scripts/test-support/KeepAliveTestStubs.swift DeepSleep/AIKeepAlive/KeepAliveModels.swift DeepSleep/AIKeepAlive/KeepAliveStore.swift DeepSleep/AIKeepAlive/KeepAliveClient.swift DeepSleep/AIKeepAlive/KeepAliveEngine.swift DeepSleep/LLMGateway/Database/QuotaModels.swift scripts/test-keepalive-schedule.swift
build_and_run "keepalive-backoff"    /tmp/t_kabk     scripts/test-support/KeepAliveTestStubs.swift DeepSleep/AIKeepAlive/KeepAliveModels.swift DeepSleep/AIKeepAlive/KeepAliveStore.swift DeepSleep/AIKeepAlive/KeepAliveClient.swift DeepSleep/AIKeepAlive/KeepAliveEngine.swift DeepSleep/LLMGateway/Database/QuotaModels.swift scripts/test-keepalive-backoff-timing.swift

echo
echo "=== 结果 ==="
echo "  断言通过: $PASS"
echo "  脚本失败: $FAIL"
if [ $FAIL -gt 0 ]; then
    printf '  失败脚本: %s\n' "${FAILED_LIST[*]}"
    exit 1
fi
echo "  全部通过"
