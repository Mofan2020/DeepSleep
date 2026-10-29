#!/usr/bin/env bash
# 风扇模式（含调速规则）持久化自测。
# 测的是真实源码，不是副本 —— 副本会漂移。
#
# 运行： bash scripts/test-fan-mode-store.sh

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

BIN=/tmp/t_fanmodestore
TEST="$ROOT/scripts/test-fan-mode-store.swift"

if [ ! -f "$TEST" ]; then
    echo "[失败] 找不到 $TEST"
    exit 1
fi

swiftc -parse-as-library \
    "$ROOT/DeepSleep/Core/FanMode.swift" \
    "$ROOT/DeepSleep/Core/FanModeStore.swift" \
    "$TEST" -o "$BIN" 2>/tmp/t_fanmodestore_compile.log
if [ $? -ne 0 ]; then
    echo "[失败] 编译失败"
    head -20 /tmp/t_fanmodestore_compile.log
    exit 1
fi

"$BIN"
