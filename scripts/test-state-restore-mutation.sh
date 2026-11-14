#!/bin/bash
# test-state-restore-mutation.sh
# DeepSleep
#
# 变异测试：把「跨重启恢复」的实现改坏，测试**必须红**。
#
# 「测试绿了不代表它在测东西」——这条专门证明恢复判据与倒计时口径
# 确实在盯着那几行代码，而不是恰好通过。
#
# 每个变异点：
#   1. 特权断言不再检查助手 → 没助手时也「恢复」，用户以为接回来了
#   2. 定时保持到期照旧恢复 → 昨天的「保持 1 小时」今天还在
#   3. 定时到期的断言照旧恢复 → 同上，且更难发现（只是少了自动释放）
#   4. 风扇控制不再检查免责声明 → 恢复流程替用户同意了
#   5. 存档缺字段时整份作废 → 升级一次就把用户设置全清掉
#   6. 倒计时用原始空闲 → 远程开启时一开启就关屏（正是这版要改的）
#
# 用法： bash scripts/test-state-restore-mutation.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

STATE=DeepSleep/Core/RunState.swift
WINDOW=DeepSleep/Core/ServerModeIdleWindow.swift
TEST=scripts/test-state-restore.swift
SUPPORT="DeepSleep/Core/AudioControlModels.swift Shared/ServerModeIdlePolicy.swift"
TMP=/tmp/ds_state_mutation
mkdir -p "$TMP"

PASS=0
FAIL=0

# run_mutation <名字> <被改的文件> <sed 表达式> <变异后是否需要额外源文件>
run_mutation() {
    local name="$1"
    local target="$2"
    local sed_expr="$3"

    local mutated="$TMP/mutated_$(basename "$target")"
    sed "$sed_expr" "$target" > "$mutated"

    # 变异点没生效 → 测试文件与实现不同步，这条变异不算数
    if cmp -s "$target" "$mutated"; then
        printf '  [失败] %-44s 变异点没找到（实现已改，测试要同步更新）\n' "$name"
        FAIL=$((FAIL + 1))
        return
    fi

    local sources="$STATE $WINDOW $SUPPORT"
    if [ "$target" = "$STATE" ]; then
        sources="$mutated $WINDOW $SUPPORT"
    else
        sources="$STATE $mutated $SUPPORT"
    fi

    local bin="$TMP/mutant"
    # shellcheck disable=SC2086
    if ! swiftc -parse-as-library $sources "$TEST" -o "$bin" >/dev/null 2>&1; then
        # 编译不过：变异确实改变了行为（类型系统挡住了），也算抓住
        printf '  [通过] %-44s 变异实现编译不过（类型系统挡住）\n' "$name"
        PASS=$((PASS + 1))
        return
    fi

    if env DEEPSLEEP_RUNSTATE_SUITE=com.skyc8266.deepsleep.tests.runstate.mutation \
        "$bin" >/dev/null 2>&1; then
        printf '  [失败] %-44s 变异实现居然通过了 —— 断言没在测这一条\n' "$name"
        FAIL=$((FAIL + 1))
    else
        printf '  [通过] %-44s 变异被测试抓住\n' "$name"
        PASS=$((PASS + 1))
    fi
}

echo "=== 跨重启恢复变异测试 ==="

# 1. 特权断言不再检查助手就绪
run_mutation "特权断言不检查助手" "$STATE" \
    's|if environment.privilegedAssertions.contains(raw), !environment.helperReady {|if false {|'

# 2. 定时保持到期也照旧恢复
run_mutation "定时保持到期照旧恢复" "$STATE" \
    's|let holdExpired = holdUntil.map { $0 <= now } ?? false|let holdExpired = false|'

# 3. 定时到期的断言也照旧恢复（只改断言那一段）
run_mutation "到期后断言仍恢复" "$STATE" \
    's|if holdExpired {|if false {|'

# 4. 风扇控制不检查免责声明
run_mutation "风扇不检查免责声明" "$STATE" \
    's|if !environment.disclaimerAccepted {|if false {|'

# 5. 缺字段的存档直接作废（拿一个「老存档里没有的字段」来试）
run_mutation "缺字段存档整份作废" "$STATE" \
    's|container.decodeIfPresent(Bool.self, forKey: .sleepDisabled) ?? false|try container.decode(Bool.self, forKey: .sleepDisabled)|'

# 6. 倒计时用原始空闲（等于恢复「一开启就关屏」）
run_mutation "倒计时不扣掉开启前的空闲" "$WINDOW" \
    's|return min(raw, window)|return raw|'

echo
echo "=== 结果 ==="
echo "  变异被抓住: $PASS"
echo "  变异漏过:   $FAIL"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
echo "  全部抓住"
