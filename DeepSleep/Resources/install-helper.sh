#!/bin/sh
#
#  install-helper.sh
#  Deep Sleep
#
#  特权助手的一次性安装脚本。由 Deep Sleep.app 通过
#  `osascript ... with administrator privileges` 以 root 身份执行。
#
#  该脚本从 Swift 侧（HelperConstants）通过环境变量接收全部路径，
#  自身不包含任何硬编码路径。
#
#  必需的输入变量：
#    HELPER_SRC      app bundle 内 deepsleep-helper 二进制的路径
#    HELPER_DEST     安装目标（/Library/PrivilegedHelperTools/...）
#    DAEMON_PLIST    LaunchDaemon 描述文件路径
#    DAEMON_LABEL    launchd 标签
#    SOCKET_PATH     助手监听的 UNIX socket 路径
#    LOG_PATH        助手日志路径
#
#  退出码：0 成功且 socket 就绪；其余见每处 exit 前的说明。
#
#  **这份脚本的每一步都以「可以重复执行」为前提。**
#  以前的做法是 bootout 之后立刻 bootstrap：bootout 是异步的，旧任务还没
#  退干净就 bootstrap，会返回「Bootstrap failed: 5: Input/output error」，
#  而 bootout 之前那句 `rm -f socket` 已经把正在跑的助手的 socket 删了——
#  结果是：安装报错、助手还在跑但没人连得上、界面显示「助手不可用」，
#  再点一次才成功。现在改成：等旧任务真的消失 → 原子替换二进制 →
#  bootstrap 失败时先看任务是不是已经在 → 在就 kickstart。
#

set -eu

: "${HELPER_SRC:?缺少 HELPER_SRC}"
: "${HELPER_DEST:?缺少 HELPER_DEST}"
: "${DAEMON_PLIST:?缺少 DAEMON_PLIST}"
: "${DAEMON_LABEL:?缺少 DAEMON_LABEL}"
: "${SOCKET_PATH:?缺少 SOCKET_PATH}"
: "${LOG_PATH:?缺少 LOG_PATH}"

DEST_DIR="$(dirname "$HELPER_DEST")"

fail() {
    echo "$1" >&2
    exit "$2"
}

# ---------------------------------------------------------------- 1. 预检

if [ ! -f "$HELPER_SRC" ]; then
    fail "helper-source-missing: 找不到要安装的助手二进制：$HELPER_SRC" 2
fi
if [ ! -r "$HELPER_SRC" ]; then
    # 常见于「app 还在磁盘映像里 / 被 App Translocation 挡住」：
    # 用户点的是同一个 app，但 root 读不到它里面的文件。
    fail "helper-source-unreadable: 助手二进制读不出来（把 Deep Sleep 拖进「应用程序」再装一次）：$HELPER_SRC" 2
fi

mkdir -p "$DEST_DIR" || fail "dest-dir-failed: 建不出安装目录：$DEST_DIR" 3

# ---------------------------------------------------------------- 2. 停旧任务

# bootout 是异步的：命令返回成功不代表任务已经退出。轮询到真的没了为止，
# 最多等 5 秒；超时也不硬失败——后面 bootstrap 会自己判断「已经在跑」。
i=0
while [ "$i" -lt 50 ]; do
    if ! /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 0 ]; then
        /bin/launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
    fi
    /bin/sleep 0.1
    i=$((i + 1))
done

# 任务真的停了之后才动 socket。反过来的话：助手还活着、socket 却没了，
# 它继续占着监听口但没人能找到它，界面只会显示「助手不可用」。
if ! /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    /bin/rm -f "$SOCKET_PATH"
fi

# ---------------------------------------------------------------- 3. 装二进制

# 先写到同目录下的临时名，改完属性再原子 mv 过去。
# 不要直接 cp 覆盖：目标可能正被旧进程 map 着，cp 会把文件截断再写，
# 旧进程读到一半的字节会崩。
STAGING="$HELPER_DEST.new"
/bin/rm -f "$STAGING"
/bin/cp -f "$HELPER_SRC" "$STAGING" \
    || fail "copy-failed: 复制助手失败：$HELPER_SRC → $STAGING" 4
/usr/sbin/chown root:wheel "$STAGING"
/bin/chmod 755 "$STAGING"
# 从 zip / dmg 解压并拖进 app 的二进制会带 com.apple.quarantine，
# 不清掉等于把一个受隔离的文件交给 launchd。
/usr/bin/xattr -c "$STAGING" 2>/dev/null || true
/bin/mv -f "$STAGING" "$HELPER_DEST" \
    || fail "replace-failed: 替换助手失败：$HELPER_DEST" 4

if [ ! -x "$HELPER_DEST" ]; then
    fail "not-executable: 装好了但不可执行：$HELPER_DEST" 4
fi

# ---------------------------------------------------------------- 4. 写 LaunchDaemon

/bin/cat > "$DAEMON_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER_DEST}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>${LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_PATH}</string>
</dict>
</plist>
PLIST_EOF

/usr/sbin/chown root:wheel "$DAEMON_PLIST"
/bin/chmod 644 "$DAEMON_PLIST"
/usr/bin/xattr -c "$DAEMON_PLIST" 2>/dev/null || true

# plist 必须能被解析，否则 launchd 会静默拒绝加载。
if ! /usr/bin/plutil -lint "$DAEMON_PLIST" >/dev/null; then
    fail "plist-invalid: $DAEMON_PLIST" 5
fi

# ---------------------------------------------------------------- 5. 注册

# label 被写进 disabled 标记时，bootstrap 只会回一句「Input/output error」，
# 光看那句话完全指不到真正的原因。先无条件清标记。
/bin/launchctl enable "system/$DAEMON_LABEL" 2>/dev/null || true

BOOTSTRAP_OUT="$(/bin/launchctl bootstrap system "$DAEMON_PLIST" 2>&1)" || true
if [ -n "$BOOTSTRAP_OUT" ]; then
    echo "bootstrap: $BOOTSTRAP_OUT" >&2
fi

# bootstrap 失败不等于没装上：任务可能早就在（上一次装过、只是没跑起来）。
# 这种情况把它踢起来就行，不必让用户再输一次密码。
if ! /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    # 再试一次：刚 bootout 完的那一刻 bootstrap 偶尔会碰上 HAL 还没回收。
    /bin/sleep 0.3
    BOOTSTRAP_OUT="$(/bin/launchctl bootstrap system "$DAEMON_PLIST" 2>&1)" || true
    if [ -n "$BOOTSTRAP_OUT" ]; then
        echo "bootstrap(retry): $BOOTSTRAP_OUT" >&2
    fi
fi

if ! /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "bootstrap-failed: $DAEMON_LABEL 没能在 launchd 里注册" >&2
    echo "--- disabled 状态 ---" >&2
    /bin/launchctl print-disabled system 2>&1 | /usr/bin/grep "$DAEMON_LABEL" >&2 || true
    exit 6
fi

# 注册上了但没在跑（上次崩溃被 throttle 之后就是这样）：主动拉起一次。
if ! /bin/launchctl print "system/$DAEMON_LABEL" 2>/dev/null | /usr/bin/grep -q 'state = running'; then
    /bin/launchctl kickstart -k "system/$DAEMON_LABEL" 2>/dev/null || true
fi

# ---------------------------------------------------------------- 6. 等 socket

i=0
while [ "$i" -lt 50 ]; do
    if [ -S "$SOCKET_PATH" ]; then
        echo "helper-ready"
        exit 0
    fi
    /bin/sleep 0.1
    i=$((i + 1))
done

echo "helper-socket-missing: $SOCKET_PATH" >&2
echo "--- launchctl 状态 ---" >&2
/bin/launchctl print "system/$DAEMON_LABEL" >&2 2>&1 || true
echo "--- 最近的助手日志 ---" >&2
/usr/bin/tail -20 "$LOG_PATH" >&2 2>&1 || true
exit 1
