//
//  UnixSocket.swift
//  Deep Sleep
//
//  UNIX domain socket 的读写封装，带长度前缀分帧。
//  被 app（客户端）与 helper（服务端）共同使用。
//

import Foundation
import Darwin

public enum SocketError: LocalizedError {
    case creationFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case timeout
    case peerClosed
    case malformedFrame(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let m):   return "无法创建 socket：\(m)"
        case .bindFailed(let m):       return "无法绑定 socket：\(m)"
        case .listenFailed(let m):     return "无法监听 socket：\(m)"
        case .connectFailed(let m):    return "无法连接助手：\(m)"
        case .timeout:                 return "等待助手响应超时"
        case .peerClosed:              return "助手连接被关闭"
        case .malformedFrame(let m):   return "数据帧格式错误：\(m)"
        case .encodingFailed(let m):   return "数据编码失败：\(m)"
        }
    }
}

public enum UnixSocket {

    /// 构造 `sockaddr_un`。路径过长时会被截断到系统上限。
    public static func makeAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let capacity = raw.count
            let count = min(bytes.count, capacity - 1)
            raw.copyBytes(from: bytes.prefix(count))
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// 用 `sockaddr_un` 调用需要 `sockaddr` 指针的 BSD API。
    public static func withSockaddr<T>(
        _ addr: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// 创建服务端 socket，绑定并开始监听。
    /// - Returns: 监听用的文件描述符。
    public static func makeListener(at path: String, backlog: Int32 = 16) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.creationFailed(String(cString: strerror(errno)))
        }

        // 清理上一次运行遗留的 socket 文件，否则 bind 会因 EADDRINUSE 失败。
        unlink(path)

        var addr = makeAddress(path)
        let bindResult = withSockaddr(&addr) { sa, len in
            bind(fd, sa, len)
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SocketError.bindFailed(message)
        }

        guard listen(fd, backlog) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw SocketError.listenFailed(message)
        }

        return fd
    }

    /// 连接到 UNIX domain socket，并设置收发超时。
    public static func connect(to path: String, timeout: TimeInterval = 10) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.creationFailed(String(cString: strerror(errno)))
        }

        var addr = makeAddress(path)
        let result = withSockaddr(&addr) { sa, len in
            Darwin.connect(fd, sa, len)
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SocketError.connectFailed(message)
        }

        setTimeout(fd, seconds: timeout)
        return fd
    }

    /// 设置收/发超时，避免对端无响应时永久阻塞。
    public static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: suseconds_t(Int32((seconds - Double(Int(seconds))) * 1_000_000))
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 取得对端进程的有效 uid/gid。用于确认连接来自当前登录用户。
    public static func peerCredentials(_ fd: Int32) -> (uid: uid_t, gid: gid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return (uid, gid)
    }

    /// 完整写出 data，循环处理短写。
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.creationFailed(String(cString: strerror(errno)))
                }
                if written == 0 { throw SocketError.peerClosed }
                offset += written
            }
        }
    }

    /// 精确读取 count 字节，遇 EOF 抛错。
    public static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            var chunk = [UInt8](repeating: 0, count: count - offset)
            let readCount = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
                throw SocketError.creationFailed(String(cString: strerror(errno)))
            }
            if readCount == 0 { throw SocketError.peerClosed }
            for index in 0..<readCount {
                buffer[offset + index] = chunk[index]
            }
            offset += readCount
        }
        return Data(buffer)
    }

    /// 发送一帧：4 字节大端长度 + JSON 负载。
    public static func sendFrame<T: Encodable>(_ fd: Int32, _ value: T) throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(value)
        } catch {
            throw SocketError.encodingFailed(String(describing: error))
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        try writeAll(fd, frame)
    }

    /// 接收一帧，返回解码后的对象。
    public static func readFrame<T: Decodable>(_ fd: Int32, as type: T.Type) throws -> T {
        let header = try readExactly(fd, count: MemoryLayout<UInt32>.size)
        let length = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self)
        }
        let count = Int(UInt32(bigEndian: length))
        guard count > 0 && count <= 4 * 1024 * 1024 else {
            throw SocketError.malformedFrame("负载长度 \(count) 不合法")
        }
        let payload = try readExactly(fd, count: count)
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw SocketError.malformedFrame(String(describing: error))
        }
    }
}
