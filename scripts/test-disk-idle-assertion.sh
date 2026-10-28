#!/usr/bin/env bash
# PreventDiskIdle assertion 自测。
# 验证「阻止外部磁盘空闲休眠」在普通用户进程里能创建、能被系统登记、能释放。
#
# 运行： bash scripts/test-disk-idle-assertion.sh

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

BIN=/tmp/t_diskidle
TEST="$ROOT/scripts/test-disk-idle-assertion.swift"

if [ ! -f "$TEST" ]; then
    echo "[失败] 找不到 $TEST"
    exit 1
fi

swiftc -parse-as-library "$TEST" -o "$BIN" 2>/tmp/t_diskidle_compile.log
if [ $? -ne 0 ]; then
    echo "[失败] 编译失败"
    head -20 /tmp/t_diskidle_compile.log
    exit 1
fi

"$BIN"
