#!/usr/bin/env bash
# 风扇「连续写不进 → 停止修改、交回系统」的判定逻辑自测。
# 测的是真实源码，不是副本 —— 副本会漂移。
#
# 运行： bash scripts/test-fan-stall.sh

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

BIN=/tmp/t_fanstall
TEST="$ROOT/scripts/test-fan-stall.swift"

if [ ! -f "$TEST" ]; then
    echo "[失败] 找不到 $TEST"
    exit 1
fi

swiftc -parse-as-library \
    "$ROOT/Shared/FanModels.swift" \
    "$ROOT/Shared/FanWriteFailureTracker.swift" \
    "$TEST" -o "$BIN" 2>/tmp/t_fanstall_compile.log
if [ $? -ne 0 ]; then
    echo "[失败] 编译失败"
    head -20 /tmp/t_fanstall_compile.log
    exit 1
fi

"$BIN"
