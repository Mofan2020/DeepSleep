#!/usr/bin/env bash
# FanModels 编解码往返自测。
# 测的是真实源码（Shared/FanModels.swift），不是副本 —— 副本会漂移。
#
# 运行： bash scripts/test-fan-models.sh

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

BIN=/tmp/t_fanmodels
SRC="$ROOT/Shared/FanModels.swift"
TEST="$ROOT/scripts/test-fan-models.swift"

if [ ! -f "$SRC" ]; then
    echo "[失败] 找不到 $SRC"
    exit 1
fi

swiftc -parse-as-library "$SRC" "$TEST" -o "$BIN" 2>/tmp/t_fanmodels_compile.log
if [ $? -ne 0 ]; then
    echo "[失败] 编译失败"
    head -20 /tmp/t_fanmodels_compile.log
    exit 1
fi

"$BIN"
