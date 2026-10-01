#!/bin/bash
#
# 助手更新路径的端到端验证。
#
# 为什么需要它：助手更新是「检查 → 用户确认 → 就地替换 root 二进制」这条链，
# 单元测试覆盖不到（要真实 socket、真实 /Library 里的那个助手）。
# 而这条链曾经真的出过问题 —— 手动点击被自动路径的次数上限吞掉，
# 用户看到「检测到了差异，但什么都没发生，也没有任何提示」。
#
# 做法：用两个内容不同的构建产物（Debug 与 Release）互为「新版本」，
# 依次手动更新 —— 一次换过去、一次换回来，每次都要求
#   1) 命令报出「与内置版本不同」（含两边的短摘要）
#   2) 命令报出「助手已更新」
#   3) /Library 里那份的摘要真的变成目标摘要（用 shasum 对着看，不信自述）
#
# 注意：**这会真的替换系统里已安装的助手**（这是它要验证的东西）。
# 结束时会把助手恢复成本仓库 Release 产物内置的那一份。
#
# 用法：bash scripts/test-helper-update.sh

set -u
cd "$(dirname "$0")/.." || exit 1

# open -a 只认绝对路径或应用名：给相对路径会被当成「按名字找应用」而失败。
ROOT="$(pwd)"

DEBUG_APP="$ROOT/build/Build/Products/Debug/Deep Sleep.app"
RELEASE_APP="$ROOT/build/Build/Products/Release/Deep Sleep.app"
HELPER="/Library/PrivilegedHelperTools/com.skyc8266.deepsleep.helper"

passed=0
failed=0

short() { shasum -a 256 "$1" 2>/dev/null | cut -c1-8; }

check() {   # check <说明> <期望> <实际>
    if [ "$2" = "$3" ]; then
        echo "[通过] $1"
        passed=$((passed + 1))
    else
        echo "[失败] $1：期望 $2，实际 $3"
        failed=$((failed + 1))
    fi
}

run_args() {   # run_args <app 路径> <等待秒数> <参数...>
    local app="$1" wait_s="$2"; shift 2
    rm -f /tmp/ds-helper-test-out.log
    open -a "$app" --stdout /tmp/ds-helper-test-out.log --stderr /dev/null --args "$@"
    sleep "$wait_s"
    pkill -f "$app/Contents/MacOS/Deep Sleep" 2>/dev/null
    sleep 1
}

for app in "$DEBUG_APP" "$RELEASE_APP"; do
    if [ ! -d "$app" ]; then
        echo "缺构建产物：$app（先 xcodegen generate 并构建两个配置）"
        exit 1
    fi
done

if [ ! -f "$HELPER" ]; then
    echo "系统里没有已安装的助手，这条验证需要先在应用里启用「完全控制」"
    exit 1
fi

DEBUG_DIGEST=$(short "$DEBUG_APP/Contents/Library/PrivilegedHelperTools/deepsleep-helper")
RELEASE_DIGEST=$(short "$RELEASE_APP/Contents/Library/PrivilegedHelperTools/deepsleep-helper")

echo "Debug   内置助手摘要: $DEBUG_DIGEST"
echo "Release 内置助手摘要: $RELEASE_DIGEST"
echo "当前已安装        : $(short "$HELPER")"
echo

if [ "$DEBUG_DIGEST" = "$RELEASE_DIGEST" ]; then
    echo "两个配置的助手摘要相同，无法互相作为「不同的一份」，跳过"
    echo
    echo "测试结论: 跳过（环境不满足）"
    exit 0
fi

# ---- 1. 换成 Debug 内置的那一份 ----
echo "== 用 Debug 产物手动更新 =="
run_args "$DEBUG_APP" 30 --helper-update
OUT=$(grep 'deepsleep:' /tmp/ds-helper-test-out.log)
echo "$OUT"
check "报出了版本差异" "1" "$(echo "$OUT" | grep -c '与内置版本不同')"
check "报出了更新成功" "1" "$(echo "$OUT" | grep -c '助手已更新')"
check "已安装助手真的换成了 Debug 那一份" "$DEBUG_DIGEST" "$(short "$HELPER")"
echo

# ---- 2. 换回 Release 内置的那一份 ----
echo "== 用 Release 产物手动更新（换回来）=="
run_args "$RELEASE_APP" 30 --helper-update
OUT=$(grep 'deepsleep:' /tmp/ds-helper-test-out.log)
echo "$OUT"
check "报出了版本差异" "1" "$(echo "$OUT" | grep -c '与内置版本不同')"
check "报出了更新成功" "1" "$(echo "$OUT" | grep -c '助手已更新')"
check "已安装助手真的换成了 Release 那一份" "$RELEASE_DIGEST" "$(short "$HELPER")"
echo

# ---- 3. 两边一致时，检查必须说「无需更新」而不是沉默 ----
echo "== 一致时再检查一次 =="
run_args "$RELEASE_APP" 12 --helper-update
OUT=$(grep 'deepsleep:' /tmp/ds-helper-test-out.log)
echo "$OUT"
check "一致时明确回答「无需更新」" "1" "$(echo "$OUT" | grep -c '无需更新')"
echo

echo "测试结论: $passed 项通过，$failed 项失败"
[ "$failed" -eq 0 ] || exit 1
