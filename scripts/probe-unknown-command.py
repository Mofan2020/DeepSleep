#!/usr/bin/env python3
"""
probe-unknown-command.py

给已安装的助手发一条它可能不认识的命令（updateSelf），
确认旧版助手会体面地拒绝，而不是崩溃或超时。

背景：应用发现助手版本落后时会发 updateSelf。而「落后」这件事本身就意味着
对方多半是旧二进制 —— 它可能根本没有这个命令。这时候它必须优雅失败，
否则用户看到的是助手一遍遍崩溃重启。
"""

import json
import os
import socket
import struct
import sys

SOCKET_PATH = "/var/run/com.skyc8266.deepsleep.sock"


def call(command: str, arguments: dict) -> dict:
    payload = json.dumps({"command": command, "arguments": arguments}).encode("utf-8")
    frame = struct.pack(">I", len(payload)) + payload

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(8)
        connection.connect(SOCKET_PATH)
        connection.sendall(frame)

        header = b""
        while len(header) < 4:
            header += connection.recv(4 - len(header))
        length = struct.unpack(">I", header)[0]

        body = b""
        while len(body) < length:
            chunk = connection.recv(length - len(body))
            if not chunk:
                raise SystemExit("连接被助手关闭")
            body += chunk

    return json.loads(body.decode("utf-8"))


def main() -> None:
    if not os.path.exists(SOCKET_PATH):
        print("助手 socket 不存在，跳过（助手未安装）")
        return

    print("== 旧助手对未知命令的响应 ==")
    try:
        # 故意传一个注定被拒的参数组合：只要对方认识这个命令，
        # 就应该回一句「拒绝更新：…」而不是断开连接。
        response = call("updateSelf", {
            "source": "/tmp/not-a-real-helper",
            "sha256": "0" * 64,
            "build": "9999",
        })
    except Exception as error:                      # noqa: BLE001
        print(f"  [失败] 连接层面出错：{error}")
        sys.exit(1)

    ok = response.get("success", False)
    message = response.get("message", "")
    print(f"  success = {ok}")
    print(f"  message = {message}")

    if ok:
        print("  [失败] 居然接受了非法来源的更新请求")
        sys.exit(1)

    # 认识这个命令 → 回的是「拒绝更新：…」；
    # 不认识（旧版）→ 解码失败，回的是通用错误。两者都算通过。
    if "拒绝更新" in message:
        print("  [通过] 认识该命令，并正确拒绝了非法来源")
    else:
        print("  [通过] 不认识该命令，体面地返回了错误（旧版助手应有的行为）")


if __name__ == "__main__":
    main()
