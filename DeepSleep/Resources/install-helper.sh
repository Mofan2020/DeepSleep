#!/bin/sh
#
#  install-helper.sh
#  Deep Sleep
#
#  特权助手的一次性安装脚本。由 Deep Sleep.app 通过
#  `osascript ... with administrator privileges` 以 root 身份执行一次。
#
#  该脚本从 Swift 侧（HelperConstants）通过环境变量接收全部路径，
#  自身不包含任何硬编码路径，也不接受除下列变量之外的任何输入。
#
#  必需的输入变量：
#    HELPER_SRC      app bundle 内 deepsleep-helper 二进制的路径
#    HELPER_DEST     安装目标（/Library/PrivilegedHelperTools/...）
#    DAEMON_PLIST    LaunchDaemon 描述文件路径
#    DAEMON_LABEL    launchd 标签
#    SOCKET_PATH     助手监听的 UNIX socket 路径
#    LOG_PATH        助手日志路径
#
#  退出码：0 成功且 socket 就绪；非 0 失败。
#

set -eu

: "${HELPER_SRC:?缺少 HELPER_SRC}"
: "${HELPER_DEST:?缺少 HELPER_DEST}"
: "${DAEMON_PLIST:?缺少 DAEMON_PLIST}"
: "${DAEMON_LABEL:?缺少 DAEMON_LABEL}"
: "${SOCKET_PATH:?缺少 SOCKET_PATH}"
: "${LOG_PATH:?缺少 LOG_PATH}"

if [ ! -f "$HELPER_SRC" ]; then
    echo "helper-source-missing: $HELPER_SRC" >&2
    exit 2
fi

DEST_DIR="$(dirname "$HELPER_DEST")"

mkdir -p "$DEST_DIR"

# 先停掉旧实例：旧进程会占着 socket，导致新进程 bind 失败。
/bin/launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
/bin/rm -f "$SOCKET_PATH"

/bin/cp -f "$HELPER_SRC" "$HELPER_DEST"
/usr/sbin/chown root:wheel "$HELPER_DEST"
/bin/chmod 755 "$HELPER_DEST"

# 写入 LaunchDaemon 描述。路径来自调用方，必须是绝对路径。
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

# plist 必须能被解析，否则 launchd 会静默拒绝加载。
if ! /usr/bin/plutil -lint "$DAEMON_PLIST" >/dev/null; then
    echo "plist-invalid: $DAEMON_PLIST" >&2
    exit 3
fi

/bin/launchctl bootstrap system "$DAEMON_PLIST"

# 等待 socket 就绪（最多 5 秒）。
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
exit 1
