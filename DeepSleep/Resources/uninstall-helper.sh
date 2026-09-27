#!/bin/sh
#
#  uninstall-helper.sh
#  Deep Sleep
#
#  完全移除特权助手，把系统恢复到安装前的状态。
#  路径同样由 Swift 侧通过环境变量传入。
#
#  必需的输入变量：
#    HELPER_DEST     安装的助手二进制路径
#    DAEMON_PLIST    LaunchDaemon 描述文件路径
#    DAEMON_LABEL    launchd 标签
#    SOCKET_PATH     助手监听的 UNIX socket 路径
#    LOG_PATH        助手日志路径
#

set -eu

: "${HELPER_DEST:?缺少 HELPER_DEST}"
: "${DAEMON_PLIST:?缺少 DAEMON_PLIST}"
: "${DAEMON_LABEL:?缺少 DAEMON_LABEL}"
: "${SOCKET_PATH:?缺少 SOCKET_PATH}"
: "${LOG_PATH:?缺少 LOG_PATH}"

/bin/launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true

/bin/rm -f "$SOCKET_PATH"
/bin/rm -f "$HELPER_DEST"
/bin/rm -f "$DAEMON_PLIST"
/bin/rm -f "$LOG_PATH"

if /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "helper-still-loaded: $DAEMON_LABEL" >&2
    exit 1
fi

echo "helper-removed"
