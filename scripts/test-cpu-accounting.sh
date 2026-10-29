#!/usr/bin/env bash
# CPU 读数自测。跟内核真值（getrusage）对撞，不是自说自话。
#
# 运行： bash scripts/test-cpu-accounting.sh

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

BIN=/tmp/t_cpuacct
TEST="$ROOT/scripts/test-cpu-accounting.swift"

if [ ! -f "$TEST" ]; then
    echo "[失败] 找不到 $TEST"
    exit 1
fi

swiftc -parse-as-library \
    "$ROOT/Shared/CPUAccounting.swift" \
    "$TEST" -o "$BIN" 2>/tmp/t_cpuacct_compile.log
if [ $? -ne 0 ]; then
    echo "[失败] 编译失败"
    head -25 /tmp/t_cpuacct_compile.log
    exit 1
fi

"$BIN"
