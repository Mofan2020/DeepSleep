#!/usr/bin/env python3
"""
helper-probe.py — 直接与 Deep Sleep 特权助手对话的诊断工具。

用途：
  1. 排查「完全控制」功能为何不生效（助手是否在跑、协议是否对得上）
  2. 端到端验证外部改动恢复：用同一条提权通路把 disablesleep 改回 0，
     再观察 Deep Sleep 是否会在 3 秒内自动恢复。

协议：UNIX domain socket + 4 字节大端长度前缀 + JSON，与 Shared/UnixSocket.swift 一致。

用法：
    python3 scripts/helper-probe.py ping
    python3 scripts/helper-probe.py status
    python3 scripts/helper-probe.py read-settings
    python3 scripts/helper-probe.py set-disablesleep 0      # 模拟外部程序改设置
    python3 scripts/helper-probe.py set-disablesleep 1
    python3 scripts/helper-probe.py write-setting sleep 0
    python3 scripts/helper-probe.py release-assertion preventSystemSleep
"""

import json
import os
import socket
import struct
import sys

SOCKET_PATH = "/var/run/com.skyc8266.deepsleep.sock"
TIMEOUT = 10


def call(command: str, **arguments) -> dict:
    if not os.path.exists(SOCKET_PATH):
        raise SystemExit(
            f"助手 socket 不存在：{SOCKET_PATH}\n"
            "说明特权助手尚未安装或未运行。请先在 Deep Sleep 的「完全控制」页启用。"
        )

    payload = json.dumps({"command": command, "arguments": arguments}).encode("utf-8")
    frame = struct.pack(">I", len(payload)) + payload

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(TIMEOUT)
        connection.connect(SOCKET_PATH)
        connection.sendall(frame)

        header = _read_exactly(connection, 4)
        length = struct.unpack(">I", header)[0]
        body = _read_exactly(connection, length)

    return json.loads(body.decode("utf-8"))


def _read_exactly(connection: socket.socket, count: int) -> bytes:
    buffer = b""
    while len(buffer) < count:
        chunk = connection.recv(count - len(buffer))
        if not chunk:
            raise SystemExit("连接被助手关闭")
        buffer += chunk
    return buffer


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)

    action = sys.argv[1]
    value = sys.argv[2] if len(sys.argv) > 2 else None

    if action == "ping":
        response = call("ping")
    elif action == "status":
        response = call("status")
    elif action == "read-settings":
        response = call("readPowerSettings")
    elif action == "set-disablesleep":
        if value not in ("0", "1"):
            raise SystemExit("用法: set-disablesleep <0|1>")
        response = call("setSleepDisabled", enabled=value)
    elif action == "write-setting":
        if len(sys.argv) < 4:
            raise SystemExit("用法: write-setting <key> <value>")
        response = call("writePowerSetting", key=value, value=sys.argv[3])
    elif action == "acquire-assertion":
        if not value:
            raise SystemExit("用法: acquire-assertion <preventSystemSleep|preventIdleSystemSleep|preventIdleDisplaySleep>")
        response = call("acquireAssertion", kind=value, name="Deep Sleep - probe")
    elif action == "release-assertion":
        if not value:
            raise SystemExit("用法: release-assertion <kind>")
        response = call("releaseAssertion", kind=value)
    else:
        raise SystemExit(f"未知命令：{action}\n\n{__doc__}")

    ok = response.get("success", False)
    print(("[成功] " if ok else "[失败] ") + response.get("message", ""))
    payload = response.get("payload") or {}
    if payload:
        for key in sorted(payload):
            print(f"  {key} = {payload[key]}")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
