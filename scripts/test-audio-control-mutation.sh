#!/bin/bash
# test-audio-control-mutation.sh
# DeepSleep
#
# 变异测试：把 AudioControlSupport 的实现改坏，测试**必须红**。
#
# 「测试绿了不代表它在测东西」——这条专门证明增益/合并那些断言
# 确实在盯着那几行代码，而不是恰好通过。
#
# 每个变异点：
#   1. 增益上限放开到 2.0（放大 → 削波）
#   2. 增益曲线改成线性（0.5 → 0.5 而不是 0.25）
#   3. clamp 漏掉上界（1.8 → 1.8 原样通过）
#   4. 同 bundleID 不合并（一个 app 拆成两行）
#   5. storedVolume 对缺失键返回 0（没设过 = 静音）
#
# 用法： bash scripts/test-audio-control-mutation.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SRC=DeepSleep/Core/AudioControlModels.swift
TEST=scripts/test-audio-control.swift
TMP=/tmp/ds_audio_mutation
mkdir -p "$TMP"

PASS=0
FAIL=0

# 变异点定义：名字 + sed 表达式。
#
# 用 sed 做定点替换：改完必须能编译、且测试必须失败。
# 「编译不过」也算变异被抓住 —— 但要分开报，不跟「测试跑完却通过」混为一谈。

run_mutation() {
    local name="$1"; shift
    local sed_expr="$1"; shift

    local mutated="$TMP/mutated.swift"
    sed "$sed_expr" "$SRC" > "$mutated"

    # 变异点没生效 → 测试文件与实现不同步，这条变异不算数
    if cmp -s "$SRC" "$mutated"; then
        printf '  [失败] %-46s 变异点没找到（实现已改，测试要同步更新）\n' "$name"
        FAIL=$((FAIL + 1))
        return
    fi

    local bin="$TMP/mutant"
    if ! swiftc -parse-as-library "$mutated" "$TEST" -o "$bin" >/dev/null 2>&1; then
        # 编译不过：变异确实改变了行为（类型系统挡住了），也算抓住
        printf '  [通过] %-46s 变异实现编译不过（类型系统挡住）\n' "$name"
        PASS=$((PASS + 1))
        return
    fi

    if "$bin" >/dev/null 2>&1; then
        printf '  [失败] %-46s 变异实现居然通过了 —— 断言没在测这一条\n' "$name"
        FAIL=$((FAIL + 1))
    else
        printf '  [通过] %-46s 变异被测试抓住\n' "$name"
        PASS=$((PASS + 1))
    fi
}

echo "=== 音频控制变异测试 ==="

# 1. 增益上限放开到 2.0 —— 放大导致削波
run_mutation "增益上限放开到 2.0" \
    's|static let maxVolume: Double = 1.0|static let maxVolume: Double = 2.0|'

# 2. 增益曲线改成线性 —— 0.5 变成 0.5 而不是 0.25
run_mutation "增益曲线改成线性" \
    's|return Float(v \* v)|return Float(v)|'

# 3. clamp 漏掉上界
run_mutation "clamp 漏掉上界" \
    's|min(max(v, 0), maxVolume)|max(v, 0)|'

# 4. 同 bundleID 不合并 —— 用 pid 当 key
run_mutation "同 bundleID 不合并" \
    's|let key = p.bundleID ?? "pid:\\(p.pid)"|let key = "pid:\\(p.pid)"|'

# 5. storedVolume 对缺失键返回 0（没设过 = 静音）
run_mutation "缺失键返回 0 而不是 unity" \
    's|guard defaults.object(forKey: key) != nil else { return maxVolume }|return defaults.double(forKey: key)|'

# 6. 增益反了 —— 音量越大越小声
run_mutation "增益方向反了" \
    's|return Float(v \* v)|return Float((1.0 - v) * (1.0 - v))|'

echo
echo "=== 结果 ==="
echo "  变异被抓住: $PASS"
echo "  变异漏过:   $FAIL"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
echo "  全部抓住"
