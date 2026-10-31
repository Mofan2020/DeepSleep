//
//  LsofService.swift
//  Deep Sleep
//
//  lsof 查询：谁占了这个端口、谁打开了这个文件。
//
//  为什么用 `-F` 机器格式而不是默认的人类表格：
//    - 人类表格的列宽随内容变化（`-i` 查询和全量查询列宽都不一样），
//      NAME 列里还可能带空格（"(LISTEN)"、带空格的路径），
//      按空白切列必然切错位；
//    - 机器格式一行一个字段，行首就是字段标识，切分规则固定。
//
//  `-F` 必须排在路径参数前面：`lsof -- /tmp -F pcuftn` 会把 -F 当成路径
//  参数忽略掉，输出退回人类表格。所以下面的参数顺序是固定写法，不要随手调换。
//
//  权限边界（界面上必须照实说，不能假装能看全）：
//    - 非特权用户能看到：自己的全部进程（含打开的文件）、所有 LISTEN 套接字；
//    - 非特权用户看不到：别的用户（尤其 root）进程打开的文件
//      （实测 `lsof -nP -p 1` 非特权输出为空）；
//    - 所以「按端口查」能看到所有监听者，「按 PID / 按路径查」只能看到自己的。
//
//  不做的事：
//    - 不做任何提权。`sudo lsof` 能看到全部进程，但那等于把整台机器的
//      文件句柄摊到界面上，这条边界交给界面文字说明，不在代码里绕过去。
//
//  执行方式：Foundation 的 Process + 参数数组，不经过 shell
//  （用户输入的路径只作为 arguments 里的一个元素，不拼字符串）。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 一条 lsof 结果。
struct LsofEntry: Identifiable, Equatable {
    let command: String
    let pid: Int
    let user: String
    let fd: String
    let type: String
    let name: String

    /// 网络条目的协议（TCP / UDP）。文件条目没有协议，为 nil。
    ///
    /// 单独一个字段而不是拼进 type：type 是 lsof 的原始类型（IPv4 / IPv6 / REG），
    /// 拼在一起就没法再按类型过滤了。
    ///
    /// 声明成 var 而不是 let：let + 默认值不会进成员初始化器，
    /// 那样就没法在解析时按字段赋值了。
    var protocolName: String? = nil

    var id: String { "\(pid)-\(fd)-\(name)" }
}

enum LsofService {

    // MARK: - 常量

    /// lsof 的绝对路径。写死不查 PATH —— PATH 是用户可控的，
    /// 从 GUI 应用里解析 PATH 等于把执行路径交给环境变量。
    static let executablePath = "/usr/sbin/lsof"

    /// 单次查询超时。本机实测 lsof 一次 0.1–0.7 秒，10 秒足够跑完，
    /// 又不至于在 lsof 异常卡住时把界面永远挂在「查询中」。
    static let timeout: TimeInterval = 10

    /// 机器格式字段集：p=pid c=命令 u=uid L=登录名 f=fd t=类型 P=协议 n=名称。
    ///
    /// 比「pcuftn」多了 L 和 P 两个字段：
    ///   - 少了 L，USER 列只能显示 uid（501）而不是用户名（mofan）；
    ///   - 少了 P，按端口查时分不清 TCP 和 UDP（mDNS 的 5353 就在 UDP 上）。
    static let fieldSpec = "pcuftnLP"

    /// 端口合法范围。
    static let portRange = 1...65535

    /// PID 合法范围：内核 PID 是正整数。
    static let pidRange = 1...Int(Int32.max)

    // MARK: - 错误

    enum LsofError: Error, LocalizedError, CustomStringConvertible {
        case invalidPort(Int)
        case invalidPID(Int)
        case invalidPath(String)
        case pathNotFound(String)
        case timedOut(TimeInterval)
        case launchFailed(String)
        case commandFailed(String)

        var description: String {
            switch self {
            case .invalidPort(let p):
                return "端口号必须是 \(portRange.lowerBound)–\(portRange.upperBound) 之间的整数（收到 \(p)）。"
            case .invalidPID(let p):
                return "PID 必须是正整数（收到 \(p)）。"
            case .invalidPath:
                return "请填写要查询的文件或目录路径。"
            case .pathNotFound(let p):
                return "路径不存在：\(p)"
            case .timedOut(let t):
                return "lsof 超时（\(Int(t)) 秒）未返回，已终止。"
            case .launchFailed(let m):
                return "无法启动 lsof：\(m)"
            case .commandFailed(let m):
                return "lsof 报错：\(m)"
            }
        }

        /// 界面上显示的文案。
        ///
        /// **必须实现这个** —— 只实现 `CustomStringConvertible` 的话，
        /// `error.localizedDescription` 给的是系统那句没用的
        /// "The operation couldn't be completed."，用户看不到到底哪里错了。
        var errorDescription: String? { description }
    }

    /// 一次 lsof 执行的原始结果。
    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    // MARK: - 查询入口

    /// 列出所有 TCP 监听端口。
    static func listening() async throws -> [LsofEntry] {
        try await query(["-nP", "-iTCP", "-sTCP:LISTEN", "-F", fieldSpec])
    }

    /// 按端口查占用情况（TCP 与 UDP 都查）。
    static func port(_ port: Int) async throws -> [LsofEntry] {
        guard isValidPort(port) else { throw LsofError.invalidPort(port) }
        return try await query(["-nP", "-iTCP:\(port)", "-iUDP:\(port)", "-F", fieldSpec])
    }

    /// 按 PID 查该进程打开的文件。
    ///
    /// 注意权限边界：非特权下只能看到自己的进程，别人（尤其 root）的
    /// 进程这里会是空结果 —— 不是 bug，是内核不允许。
    static func pid(_ pid: Int) async throws -> [LsofEntry] {
        guard isValidPID(pid) else { throw LsofError.invalidPID(pid) }
        return try await query(["-nP", "-F", fieldSpec, "-p", String(pid)])
    }

    /// 按路径查谁打开了这个文件或目录。
    static func path(_ rawPath: String) async throws -> [LsofEntry] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPath(trimmed) else { throw LsofError.invalidPath(rawPath) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw LsofError.pathNotFound(expanded)
        }
        // `--` 之后的都是路径参数，路径里带空格、带横杠都不用担心被当成选项。
        // `-F` 必须在 `--` 之前，否则会被 lsof 当成路径忽略掉。
        return try await query(["-nP", "-F", fieldSpec, "--", expanded])
    }

    // MARK: - 校验（纯函数，可单独测）

    static func isValidPort(_ port: Int) -> Bool {
        portRange.contains(port)
    }

    /// 从输入框文本解析端口：非数字、超范围都返回 nil。
    static func parsePortText(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let value = Int(trimmed), isValidPort(value) else { return nil }
        return value
    }

    static func isValidPID(_ pid: Int) -> Bool {
        pidRange.contains(pid)
    }

    /// 从输入框文本解析 PID。
    static func parsePIDText(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let value = Int(trimmed), isValidPID(value) else { return nil }
        return value
    }

    static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0")
    }

    // MARK: - 解析（纯函数，可单独测）

    /// 解析 lsof 输出。自动识别机器格式与人类表格格式。
    static func parse(_ text: String) -> [LsofEntry] {
        if looksLikeTable(text) {
            return parseTableOutput(text)
        }
        return parseFieldOutput(text)
    }

    /// 解析 `-F` 机器格式输出。
    ///
    /// 一行的格式是「字段标识 + 值」，例如 `p1171` / `f11` / `n*:52641`。
    /// 记录切分规则：
    ///   - 遇到 `p` 换进程，进程级的 c/u/L 只在进程开头出现一次；
    ///   - 遇到 `f` 换文件描述符，后面的 t/P/n 属于这个 fd；
    ///   - 一个 fd 一条记录。
    static func parseFieldOutput(_ text: String) -> [LsofEntry] {
        var entries: [LsofEntry] = []
        var seen = Set<String>()

        var pid = 0
        /// 单独记一个标志而不是判断 pid > 0：pid 0 是合法的（内核任务），
        /// 用 pid > 0 过滤会把这类记录悄悄丢掉。
        var havePID = false
        var command = ""
        var uid = ""
        var login = ""
        var fd = ""
        var type = ""
        var proto = ""
        var name = ""

        /// 把当前攒下的 fd 落成一条记录。
        func flush() {
            guard havePID, !fd.isEmpty else { return }
            let entry = LsofEntry(
                command: command,
                pid: pid,
                // 有登录名就用登录名（「mofan」比「501」好认），没有才退回 uid。
                user: login.isEmpty ? uid : login,
                fd: fd,
                type: type,
                name: name,
                protocolName: proto.isEmpty ? nil : proto
            )
            // 同一条记录可能被 lsof 重复吐一次（同一 pid+fd+name），去重避免
            // SwiftUI ForEach 撞 id。
            if seen.insert(entry.id).inserted {
                entries.append(entry)
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int(value) ?? 0
                havePID = true
                command = ""
                uid = ""
                login = ""
                fd = ""
                type = ""
                proto = ""
                name = ""
            case "c": command = value
            case "u": uid = value
            case "L": login = value
            case "f":
                flush()
                fd = value
                type = ""
                proto = ""
                name = ""
            case "t": type = value
            case "P": proto = value
            case "n": name = value
            default: break   // 不认识的字段标识直接忽略，不猜。
            }
        }
        flush()

        return entries
    }

    /// 解析人类可读表格输出。
    ///
    /// 两种切法混着用，因为 lsof 的表格两种对齐方式并存：
    ///   - 前几列（COMMAND PID USER FD TYPE）按**空白**切。PID 是右对齐的，
    ///     数据里的位置比表头标签的位置偏左，按表头偏移切会切出「171 m」
    ///     这种半截数字，所以这里改成「找到第一个纯数字 token 就是 PID」，
    ///     它前面的 token 拼起来就是进程名（进程名带空格也不会切错）。
    ///   - 最后一列（NAME）按**表头偏移**切。NAME 是最后一列，lsof 会把
    ///     整张表按固定网格排版，NAME 起始位置对所有行都一样 —— 而路径里
    ///     是可以带空格的，按空白切就会把路径切碎。
    static func parseTableOutput(_ text: String) -> [LsofEntry] {
        var entries: [LsofEntry] = []
        var seen = Set<String>()

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("COMMAND") }) else {
            return []
        }

        let header = lines[headerIndex]
        guard let nameStart = columnStart(of: "NAME", in: header) else { return [] }

        for line in lines[(headerIndex + 1)...] {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 5 else { continue }

            // PID：第一个纯数字 token。位置限定在前面几列里，
            // 免得把文件路径里的数字当成 PID。
            guard let pidIndex = (1..<min(fields.count, 6)).first(where: { fields[$0].allSatisfy(\.isNumber) }),
                  let pid = Int(fields[pidIndex]) else {
                continue
            }
            guard pidIndex + 3 < fields.count else { continue }

            let command = fields[0..<pidIndex].joined(separator: " ")
            let user = fields[pidIndex + 1]
            let fd = fields[pidIndex + 2]
            let type = fields[pidIndex + 3]
            let name = nameStart < line.count
                ? String(line.dropFirst(nameStart)).trimmingCharacters(in: .whitespaces)
                : ""

            let entry = LsofEntry(
                command: command,
                pid: pid,
                user: user,
                fd: normalizeFD(fd),
                type: type,
                name: name
            )
            if seen.insert(entry.id).inserted {
                entries.append(entry)
            }
        }

        return entries
    }

    /// 表头里某个列标签的起始字符下标。
    ///
    /// 用 `range(of:)` 而不是 `find` —— `find` 是 Swift 6 才有的 API，
    /// 本项目 SWIFT_VERSION=5.0，用了编不过。
    private static func columnStart(of label: String, in header: String) -> Int? {
        guard let range = header.range(of: label) else { return nil }
        return header.distance(from: header.startIndex, to: range.lowerBound)
    }

    /// 人类表格的 FD 列带访问模式后缀（`11u` = fd 11 只读/读写），
    /// 机器格式里没有这个后缀。统一去掉数字 fd 上的字母后缀，
    /// 免得同一条记录在两种格式下 id 对不上。
    private static func normalizeFD(_ raw: String) -> String {
        guard raw.count > 1, let last = raw.last, "urw".contains(last),
              let head = Int(raw.dropLast()) else { return raw }
        return String(head)
    }

    /// 判断输出是不是人类表格格式（第一行以 COMMAND 开头）。
    private static func looksLikeTable(_ text: String) -> Bool {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            return line.hasPrefix("COMMAND")
        }
        return false
    }

    // MARK: - 执行

    /// 跑一次 lsof 并解析结果。
    private static func query(_ arguments: [String]) async throws -> [LsofEntry] {
        let result = try await execute(arguments: arguments, timeout: timeout)
        return try interpret(result)
    }

    /// 把一次执行结果变成记录列表（纯逻辑，可单独测）。
    ///
    /// **退出码非 0 不等于「没找到」**。
    ///
    /// lsof 在**混合查询**时，只要有一个分支没匹配上就返回 1，但另一个
    /// 分支的结果照常输出到 stdout。实测 `-iTCP:49217 -iUDP:49217`
    /// （TCP 有、UDP 没有）时：退出码 1、stderr 空、stdout 里有 9 行
    /// 有效记录。早期版本在这里直接 `return []`，把有结果的查询报成
    /// 「没有占用」—— 用户看到的是「端口没人占」，实际有人占着。
    ///
    /// 所以判断顺序是：stdout 有内容 → 照常解析；stdout 空 → 才看
    /// stderr 决定是「没找到」还是「真的出错了」。
    static func interpret(_ result: RunResult) throws -> [LsofEntry] {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return parse(result.stdout)
        }

        if result.status != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.isEmpty {
                // 查不到时 lsof 退出码是 1 且什么都不打印 —— 这不是错误，
                // 是「没有占用」。
                return []
            }
            // stderr 后面还跟着 lsof 的版本横幅，取第一行才是真正的原因。
            let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? stderr
            throw LsofError.commandFailed(firstLine)
        }

        return parse(result.stdout)
    }

    /// 执行 lsof。整个过程放到全局队列上做 —— `waitUntilExit` 是阻塞调用，
    /// 占着主线程的话界面会僵住。
    private static func execute(arguments: [String], timeout: TimeInterval) async throws -> RunResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try executeBlocking(arguments: arguments, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func executeBlocking(arguments: [String], timeout: TimeInterval) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw LsofError.launchFailed(error.localizedDescription)
        }

        // 两个管道各自在后台线程读。lsof 的输出能有几 MB，不并发读的话
        // 管道缓冲区写满，lsof 卡在 write 上，两边一起走不下去。
        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        // 超时保护：到点就终止进程，不让它一直挂着。
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < hardDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            group.wait()
            throw LsofError.timedOut(timeout)
        }

        process.waitUntilExit()
        group.wait()

        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.value, as: UTF8.self),
            stderr: String(decoding: errBox.value, as: UTF8.self)
        )
    }

    /// 带锁的数据盒：管道读取线程写、等待线程读。
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
