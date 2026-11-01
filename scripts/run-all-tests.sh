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

# 需要注入环境变量的测试。格式：build_and_run_env <名> <KEY=VAL> <输出路径> <源码...>
# 用途：测试要写 UserDefaults，但键名跟 App 真实在用的撞了 ——
#       拿 .standard 去写会改掉用户自己的配置，必须换个 suite。
build_and_run_env() {
    local name="$1"; local envspec="$2"; local outbin="$3"; shift 3
    if ! swiftc -parse-as-library "$@" -o "$outbin" 2>/tmp/ds_compile_err.txt; then
        printf '  ✗ %-42s 编译失败\n' "$name"
        head -8 /tmp/ds_compile_err.txt | sed 's/^/      /'
        FAILED_LIST+=("$name")
        FAIL=$((FAIL + 1))
        return
    fi
    local out code ok_count failed_count
    out=$(env "$envspec" "$outbin" 2>&1)
    code=$?
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

# 需要额外 swiftc 参数的（比如 -framework）。参数原样传给 swiftc，
# 不强制加 -parse-as-library —— 用例自己决定。
build_and_run_raw() {
    local name="$1"; local outbin="$2"; shift 2
    if ! swiftc "$@" -o "$outbin" 2>/tmp/ds_compile_err.txt; then
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
build_and_run "update-flow"          /tmp/t_updateflow Shared/Version.swift DeepSleep/Core/UpdateFlow.swift scripts/test-update-flow.swift
build_and_run "nice-page-size"       /tmp/t_nice     Shared/NicePageSize.swift scripts/test-nice-page-size.swift
build_and_run "hosts-allowed-editors" /tmp/t_hosts   Shared/HelperProtocol.swift Shared/HostsAllowedEditors.swift scripts/test-hosts-allowed-editors.swift
build_and_run "pmset-parse"          /tmp/t_pmset    Shared/PMSetOutput.swift scripts/test-pmset-parse.swift
build_and_run "process-guard"        /tmp/t_guard    Shared/ProcessInventory.swift Shared/ProcessGuard.swift Shared/ProcessPriority.swift Shared/TerminationReport.swift scripts/test-process-guard.swift
build_and_run "process-snapshot"     /tmp/t_snap     Shared/ProcessStats.swift Shared/HelperProtocol.swift Shared/ProcessSnapshot.swift Shared/ProcessPriority.swift Shared/ProcessInventory.swift Shared/CPUAccounting.swift scripts/test-process-snapshot.swift
build_and_run "process-stats"        /tmp/t_stats    Shared/ProcessStats.swift scripts/test-process-stats.swift
build_and_run "servermode-fsm"       /tmp/t_smode    Shared/ServerModeIdlePolicy.swift scripts/test-servermode-fsm.swift
build_and_run_env "monitor-config" "DEEPSLEEP_MONITOR_CONFIG_SUITE=com.skyc8266.deepsleep.tests.monitor-config" /tmp/t_mcfg Shared/NicePageSize.swift DeepSleep/Core/MonitorConfig.swift scripts/test-monitor-config.swift
build_and_run "cpu-temp-alert"       /tmp/t_cputempalert Shared/CPUTemperatureAlert.swift scripts/test-cpu-temperature-alert.swift
build_and_run "idle-time"            /tmp/t_idle     Shared/IdleTime.swift scripts/test-idle-time.swift
build_and_run "selfupdate"           /tmp/t_selfupd  Shared/HelperProtocol.swift DeepSleepHelper/SelfUpdate.swift scripts/test-selfupdate.swift
build_and_run "auto-start-manager"   /tmp/t_autostart DeepSleep/Core/AutoStartManager.swift scripts/test-auto-start-manager.swift
build_and_run "cpu-temperature-decode" /tmp/t_cputemp DeepSleepHelper/SMCTemperature.swift Shared/CPUTemperatureSample.swift scripts/test-cpu-temperature-decode.swift
build_and_run "fan-models"          /tmp/t_fanmodels Shared/FanModels.swift scripts/test-fan-models.swift
build_and_run "fan-mode-store"      /tmp/t_fanmodestore DeepSleep/Core/FanMode.swift DeepSleep/Core/FanModeStore.swift scripts/test-fan-mode-store.swift
build_and_run "fan-stall"           /tmp/t_fanstall Shared/FanModels.swift Shared/FanWriteFailureTracker.swift scripts/test-fan-stall.swift
build_and_run "cpu-accounting"      /tmp/t_cpuacct Shared/CPUAccounting.swift scripts/test-cpu-accounting.swift
build_and_run "fan-control"         /tmp/t_fanctl Shared/FanModels.swift Shared/HelperProtocol.swift Shared/UnixSocket.swift DeepSleep/Privileged/HelperClient.swift DeepSleep/Core/ThermalMonitor.swift DeepSleep/Core/FanMode.swift DeepSleep/Core/FanModeStore.swift DeepSleep/Core/FanController.swift DeepSleep/Core/FanDisclaimer.swift scripts/test-fan-control.swift
build_and_run "alert-rules"         /tmp/t_alertrules DeepSleep/Core/AlertRule.swift DeepSleep/Core/AlertRuleEngine.swift scripts/test-alert-rules.swift
build_and_run "disk-idle-assertion" /tmp/t_diskidle scripts/test-disk-idle-assertion.swift
build_and_run_raw "cgeventtap"       /tmp/t_cgevtap  -parse-as-library -framework ApplicationServices scripts/test-cgeventtap.swift

# check-docs.py 自身的负向测试：故意改坏文档，确认校验器会拦。
# 它是 Python 脚本不是 Swift，单独跑。
if [ -f scripts/test-check-docs.py ]; then
    if python3 scripts/test-check-docs.py > /tmp/t_checkdocs.log 2>&1; then
        printf '  ✓ %-42s 通过\n' "check-docs 负向测试"
        PASS=$((PASS + 1))
    else
        printf '  ✗ %-42s 有失败项\n' "check-docs 负向测试"
        grep '\[失败\]' /tmp/t_checkdocs.log | head -5 | sed 's/^/      /'
        FAILED_LIST+=("check-docs 负向测试")
        FAIL=$((FAIL + 1))
    fi
fi

# 保活独立性检查：保活不许依赖网关（网关随时可能被移除）。
# 这是 Python 脚本不是 Swift，单独跑。
if [ -f scripts/check-keepalive-isolation.py ]; then
    if python3 scripts/check-keepalive-isolation.py > /tmp/t_ka_isolation.log 2>&1; then
        printf '  ✓ %-42s 通过\n' "保活独立性检查"
        PASS=$((PASS + 1))
    else
        printf '  ✗ %-42s 有失败项\n' "保活独立性检查"
        grep -E '^\s+[0-9]+\.' /tmp/t_ka_isolation.log | head -5 | sed 's/^/      /'
        FAILED_LIST+=("保活独立性检查")
        FAIL=$((FAIL + 1))
    fi
fi
build_and_run "keepalive-url"        /tmp/t_kaurl    DeepSleep/AIKeepAlive/KeepAliveModels.swift scripts/test-keepalive-url.swift
build_and_run "lsof-service"         /tmp/t_lsof    DeepSleep/Core/LsofService.swift scripts/test-lsof-service.swift
build_and_run "toolbox-layout"       /tmp/t_tblay    DeepSleep/Views/ToolboxLayout.swift scripts/test-toolbox-layout.swift
build_and_run "toolbox-gate"         /tmp/t_tbgate   DeepSleep/Views/ToolboxLayout.swift DeepSleep/AIKeepAlive/KeepAliveModels.swift DeepSleep/AIKeepAlive/KeepAliveError.swift DeepSleep/AIKeepAlive/KeepAliveStore.swift DeepSleep/AIKeepAlive/KeepAliveKeychain.swift scripts/test-toolbox-gate.swift
build_and_run "keepalive-schedule"   /tmp/t_kasch    scripts/test-support/KeepAliveTestStubs.swift DeepSleep/AIKeepAlive/KeepAliveModels.swift DeepSleep/AIKeepAlive/KeepAliveError.swift DeepSleep/AIKeepAlive/KeepAliveStore.swift DeepSleep/AIKeepAlive/KeepAliveClient.swift DeepSleep/AIKeepAlive/KeepAliveEngine.swift scripts/test-keepalive-schedule.swift
build_and_run "keepalive-backoff"    /tmp/t_kabk     scripts/test-support/KeepAliveTestStubs.swift DeepSleep/AIKeepAlive/KeepAliveModels.swift DeepSleep/AIKeepAlive/KeepAliveError.swift DeepSleep/AIKeepAlive/KeepAliveStore.swift DeepSleep/AIKeepAlive/KeepAliveClient.swift DeepSleep/AIKeepAlive/KeepAliveEngine.swift scripts/test-keepalive-backoff-timing.swift
build_and_run "shell-config"         /tmp/t_shellcfg DeepSleep/Core/ShellConfigService.swift scripts/test-shell-config.swift
build_and_run_raw "image-upscaler"  /tmp/t_upscale -sdk $(xcrun --show-sdk-path --sdk macosx) -target arm64-apple-macos26.0 DeepSleep/Core/ImageUpscaler.swift scripts/test-image-upscaler.swift

# ---------------------------------------------------------------- v1.10.0
# 系统监控的换算与格式化（纯逻辑，Shared/ 里那份）。
build_and_run "system-metrics"      /tmp/t_sysmetrics Shared/SystemMetrics.swift scripts/test-system-metrics.swift
# GPU / NPU 使用率的解码（纯逻辑，Shared/ 里那份）。
build_and_run "npu-gpu-metrics"     /tmp/t_npngpu Shared/NgAcceleratorMetrics.swift scripts/test-npu-gpu-metrics.swift
# 设备诊断的判定层（纯逻辑，构造「事实」驱动，不碰真机状态）。
build_and_run "diagnostic-rules"    /tmp/t_diag    Shared/DiagnosticModel.swift DeepSleep/Core/DiagnosticsExtras.swift scripts/test-diagnostic-rules.swift
# WOL 的魔术包构造与 MAC 解析：发错了在界面上看不出来，只能在这里挡。
# 依赖里带上了助手协议 / socket / 客户端：WOLService 现在会请特权助手
# 读邻居表（兜底），编译期需要这几个文件。
build_and_run "wol-packet"          /tmp/t_wol     Shared/HelperProtocol.swift Shared/UnixSocket.swift DeepSleep/Privileged/HelperClient.swift DeepSleep/Core/WakeOnLANService.swift scripts/test-wol-packet.swift
# WOL 的邻居表解析与特权助手兜底：ARP / 邻居表 / netstat 三种格式 + 合并 + 摘要三态。
build_and_run "wol-neighbor-table"  /tmp/t_wolneighbor Shared/HelperProtocol.swift Shared/UnixSocket.swift DeepSleep/Privileged/HelperClient.swift DeepSleep/Core/WakeOnLANService.swift scripts/test-wol-neighbor-table.swift
# 未响应检测的过滤器与配置。
build_and_run "hang-config"         /tmp/t_hangcfg DeepSleep/Core/HangDetectionConfig.swift scripts/test-hang-config.swift
# 仪表盘的结构护栏：环形仪表 + 卡片网格 + 令牌合规，改坏了不能发版。
build_and_run "dashboard-layout"    /tmp/t_dashlayout scripts/test-dashboard-layout.swift
# 未响应判据本身：符号可用性 + 正常应用不许被误报。
# 这条要 AppKit，所以带 sdk 与 target。
build_and_run_raw "hang-verdict"    /tmp/t_hangverdict -parse-as-library -sdk $(xcrun --show-sdk-path --sdk macosx) -target arm64-apple-macos26.0 DeepSleep/Core/HangDetector.swift DeepSleep/Core/HangDetectionConfig.swift scripts/test-hang-verdict.swift

echo
echo "=== 结果 ==="
echo "  断言通过: $PASS"
echo "  脚本失败: $FAIL"
if [ $FAIL -gt 0 ]; then
    printf '  失败脚本: %s\n' "${FAILED_LIST[*]}"
    exit 1
fi
echo "  全部通过"
