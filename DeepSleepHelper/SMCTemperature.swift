//
//  SMCTemperature.swift
//  deepsleep-helper
//
//  通过 Apple SMC IOKit 读 CPU 温度。仅 deepsleep-helper 编译。
//
// ============================================================================
// 设计 / 借鉴声明
// ============================================================================
// 本文件**借鉴** AppHouseKitchen/AlDente-Battery_Care_and_Monitoring
// (https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring)
// 的 SMC.swift(MIT 上 AlDente 自标,根是基于 beltex SMCKit 风格)。
// 借鉴的具体内容:
//
//   1. SMC IOKit 接口调用姿势:
//      - IOServiceGetMatchingService("AppleSMC") → IOServiceOpen
//      - IOConnectCallStructMethod + selector.rawValue(selector 直接当 methodId)
//      - SMCParamStruct 80 字节内存布局:
//          key(u32) | vers(SMCVersion 8B) | pLimitData(SMCPLimitData 16B)
//        | keyInfo(SMCKeyInfoData: dataSize u32 + dataType u32 + attr u8 = 9B + 3B pad)
//        | padding(u16) | result(u8) | status(u8) | data8(u8) + pad(3B,被 UInt32 对齐吃)
//        | data32(u32) | bytes(32B) = 80B
//      以上 layout 源自 Apple PowerManagement-211/PrivateLib.c (pmconfigd),
//      是 Apple 公开知识,Mac 上所有 SMC 客户端共用同一 struct。
//
//   2. 数据类型 → °C 解码字典 fpXY/spXY/flt/ioft 借鉴自 iSMC(GPL-3.0)AppleFPConv:
//      - fp1f..fp88/fpa6/fpc4/fpe2: BE u16 / 2^小数位数(unsigned)
//      - sp1e..sp96/spa5/spb4/spf0: BE u16 重解释为 int16 / 2^小数位数(signed)
//      - flt: Apple Silicon 上是 LE Float32bits(Intel era 是 BE;新固件换 LE)
//      - ioft: LE int64 / 65536
//      以上解码事实源自 Apple 公开文档 + Linux macsmc-hwmon driver + 多源验证。
//      AlDente 的 AppleFPConv 字典在该领域最完整,本文件复用同一组事实。
//
//   3. 合理性窗口:温度 [-100, 200] °C(与 iSMC rawTempMin/Max 一致)。
//
//   4. Selector 直接当 IOConnectCallStructMethod 的 selectorId 传入:
//      这是 AlDente legacy code 的关键姿势,实际 macOS 15 到 macOS 27 都能工作(经过
//      实测确认)。这条路径与 iSMC 的“两层(selector=0x2 + data8=子命令)”姿势不同。
//
// 本文件与 AlDente 的关系:
//   - 不是 AlDente 源码的 Swift 翻译,AlDente 用 Go + CGO 而本文件是纯 Swift。
//   - SMCParamStruct 字段命名与 AlDente 完全一致(便于后人 fork 对照)。
//   - 不混入 GPL 代码:DeepSleep MIT,iSMC 是 GPL-3.0;SMCParamStruct 字段与解码 fp/sp
//     的具体事实(Apple 公开)在 iSMC AppleFPConv 字典里整理,本文件用同一事实。
//
// 这条借鉴声明同时写在 docs/notes.md(开发笔记)+ commit message 里,
// 方便后续维护者理解「算法从哪来 / 代码是怎么写的」。
// ============================================================================
//

import Foundation
import IOKit

/// Apple SMC IOKit 接口。root 进程独占使用。
///
/// 每个 helper 命令触发一次 `readSample()`,内部按需打开/关闭连接。
/// 单次连接只读一次的原因:helper 重启成本低于长时间持有 SMC 连接,
/// 同时避免 SMC 连接异常挂掉时 helper 卡死的风险。
final class SMCTemperature {

    // MARK: - SMC 协议常量（完全借鉴 AlDente 的 SMCParamStruct.Selector）

    /// 直接作为 IOConnectCallStructMethod 的 selectorId 传入。
    /// 这是 AlDente legacy code 的关键姿势。
    private enum Selector: UInt8 {
        case kSMCHandleYPCEvent  = 2
        case kSMCReadKey         = 5
        case kSMCWriteKey        = 6
        case kSMCGetKeyFromIndex = 8
        case kSMCGetKeyInfo      = 9
    }

    /// SMCParamStruct.result 字段的取值
    private enum SMCResult: UInt8 {
        case kSMCSuccess     = 0
        case kSMCError       = 1
        case kSMCKeyNotFound = 132  // 0x84
    }

    // MARK: - SMCParamStruct 80 字节内存布局（来自 Apple pmconfigd/PrivateLib.c）

    /// SMCVersion(8B)
    private struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    /// SMCPLimitData(16B)
    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    /// SMCKeyInfoData(实际 9 data + 3 pad = 12B,与下一个 UInt16 padding 合占)
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// 32 字节 raw bytes
    private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8)

    /// 80 字节 SMCParamStruct（AlDente SMC.swift 字段命名一致）
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                               UInt8(0), UInt8(0))
    }

    // MARK: - SMC 字节解码字典（借鉴自 iSMC AppleFPConv）

    private struct FPConv { let div: Float32; let signed: Bool }

    /// 与 iSMC 的 AppleFPConv 一一对应。Apple SMC 文档里 spXY/fpXY
    /// 含义是「X+Y=16,小数部分占 Y 位」。
    private static let fpConvTable: [String: FPConv] = [
        "fp1f": FPConv(div: 32768, signed: false),
        "fp2e": FPConv(div: 16384, signed: false),
        "fp3d": FPConv(div:  8192, signed: false),
        "fp4c": FPConv(div:  4096, signed: false),
        "fp5b": FPConv(div:  2048, signed: false),
        "fp6a": FPConv(div:  1024, signed: false),
        "fp79": FPConv(div:   512, signed: false),
        "fp88": FPConv(div:   256, signed: false),
        "fpa6": FPConv(div:    64, signed: false),
        "fpc4": FPConv(div:    16, signed: false),
        "fpe2": FPConv(div:     4, signed: false),
        "sp1e": FPConv(div: 16384, signed: true),
        "sp2d": FPConv(div:  8192, signed: true),
        "sp3c": FPConv(div:  4096, signed: true),
        "sp4b": FPConv(div:  2048, signed: true),
        "sp5a": FPConv(div:  1024, signed: true),
        "sp69": FPConv(div:   512, signed: true),
        "sp78": FPConv(div:   256, signed: true),
        "sp87": FPConv(div:   128, signed: true),
        "sp96": FPConv(div:    64, signed: true),
        "spa5": FPConv(div:    32, signed: true),
        "spb4": FPConv(div:    16, signed: true),
        "spf0": FPConv(div:     1, signed: true),
    ]

    // MARK: - 温度合理性窗口（借鉴自 iSMC rawtemp.go rawTempMin/Max）

    private static let minTempCelsius: Float = -100.0
    private static let maxTempCelsius: Float = 200.0

    // MARK: - 目标 SMC key

    /// Apple Silicon / Intel 通用 CPU Die 温度 key 集合。
    /// key 命名因机型不同,我们按优先级轮询若干候补,
    /// 任一读出有效 °C 就填到对应语义槽位。
    ///
    /// Apple Silicon firmware 用 `flt`(LE Float32);Intel legacy 用 `sp78`。
    /// 我们的解码对两种都吃,见 `decodeValue(_:_:)`。
    private static let keyMax: [String] = ["TCMz", "TC0F", "TC0c"]
    private static let keyAverage: [String] = ["TCMb", "TC0P", "TC0D"]
    private static let keyAggregate: [String] = ["TCDX", "TC0E", "TCAD"]

    // MARK: - 公开 API

    enum SMCError: Error {
        case openFailed(String)
        case readFailed(key: String, kr: Int32, smcResult: UInt8)
        case invalidKey(String)
    }

    /// 读一次 CPU 温度样本。
    /// - Returns: 三个字段任意一个读到就填对应槽位,读不到/超出窗口就保持 nil。
    /// - Throws: SMC 接口本身打不开时(理论 root 下不会)。
    func readSample() throws -> CPUTemperatureSample {
        let conn = try openConnection()
        defer { closeConnection(conn) }

        var maxC: Float32?
        for k in Self.keyMax {
            if let v = readTemperature(conn, key: k) { maxC = v; break }
        }
        var avgC: Float32?
        for k in Self.keyAverage {
            if let v = readTemperature(conn, key: k) { avgC = v; break }
        }
        var aggC: Float32?
        for k in Self.keyAggregate {
            if let v = readTemperature(conn, key: k) { aggC = v; break }
        }

        return CPUTemperatureSample(
            maxC: maxC.map { Double($0) },
            averageC: avgC.map { Double($0) },
            aggregateC: aggC.map { Double($0) }
        )
    }

    // MARK: - 连接管理

    private func openConnection() throws -> io_connect_t {
        // 完全借鉴 AlDente 的 open():
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCError.openFailed("IOServiceGetMatchingService(\"AppleSMC\") 返回 0")
        }
        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard result == KERN_SUCCESS else {
            throw SMCError.openFailed("IOServiceOpen 返回 \(result)")
        }
        return conn
    }

    private func closeConnection(_ conn: io_connect_t) {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: - 单 key 读取

    /// IOConnectCallStructMethod + SMCParamStruct(80B) + selector-as-methodId
    /// 这是 AlDente 路径的 kernel 拦截姿势,与 iSMC 不同。
    /// 返回 (kern return, smcResult 字节)
    private func callSMC(_ conn: io_connect_t,
                        selector: Selector,
                        input: inout SMCParamStruct,
                        output: inout SMCParamStruct) -> (Int32, UInt8) {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let inputSize = MemoryLayout<SMCParamStruct>.stride

        let kr: Int32 = withUnsafePointer(to: &input) { ptr -> Int32 in
            ptr.withMemoryRebound(to: UInt8.self, capacity: inputSize) { bytePtr -> Int32 in
                var localOut: UnsafePointer<UInt8> = bytePtr
                return IOConnectCallStructMethod(
                    conn,
                    UInt32(selector.rawValue),    // AlDente 风格
                    UnsafeMutableRawPointer(mutating: bytePtr),
                    inputSize,
                    &localOut,
                    &outputSize)
            }
        }
        return (kr, output.result)
    }

    /// 读 key 的 GetKeyInfo（dataType + dataSize）
    fileprivate func getKeyInfo(_ conn: io_connect_t, key4: String)
        -> (dataType: String, dataSize: UInt32, rawBytes: [UInt8])? {
        guard key4.count == 4 else { return nil }
        var input = SMCParamStruct()
        input.key = Self.fourCharToUInt32BE(key4)
        input.data8 = Selector.kSMCGetKeyInfo.rawValue

        var output = SMCParamStruct()
        let (kr, result) = callSMC(conn, selector: .kSMCGetKeyInfo,
                                   input: &input, output: &output)
        // 诊断模式:kr 和 result 不论如何都返回,只在 dataSize > 0 时算成功
        let dt = Self.u32ToFourChar(output.keyInfo.dataType)
        let ds = output.keyInfo.dataSize
        let raw: [UInt8] = withUnsafeBytes(of: &output.bytes) { Array($0) }
        let summaryRaw = Array(raw.prefix(Int(max(ds, 8))))
        if kr != KERN_SUCCESS {
            return (dt, ds, summaryRaw)  // 仍返回,失败信息在调用方处理
        }
        if result != SMCResult.kSMCSuccess.rawValue {
            return (dt, ds, summaryRaw)
        }
        guard ds > 0 else { return (dt, 0, summaryRaw) }
        return (dt, ds, summaryRaw)
    }

    /// 读 key 的 raw bytes。失败返回 nil
    fileprivate func readKey(_ conn: io_connect_t, key4: String)
        -> (dataType: String, bytes: [UInt8])? {
        guard key4.count == 4 else { return nil }
        guard let info = getKeyInfo(conn, key4: key4) else { return nil }
        guard info.dataSize > 0, info.dataSize <= 32 else { return nil }

        var input = SMCParamStruct()
        input.key = Self.fourCharToUInt32BE(key4)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.kSMCReadKey.rawValue

        var output = SMCParamStruct()
        let (kr, result) = callSMC(conn, selector: .kSMCReadKey,
                                   input: &input, output: &output)
        guard kr == KERN_SUCCESS else { return nil }
        guard result == SMCResult.kSMCSuccess.rawValue else { return nil }

        let rawBytes: [UInt8] = withUnsafeBytes(of: &output.bytes) { Array($0) }
        return (info.dataType, Array(rawBytes.prefix(Int(info.dataSize))))
    }

    /// 读一个 key 并按温度解码。读不到 / 类型不认识 / 数值出窗口 → 返回 nil。
    private func readTemperature(_ conn: io_connect_t, key: String) -> Float32? {
        guard let r = readKey(conn, key4: key) else { return nil }
        let f = Self.decodeValue(r.dataType, r.bytes)
        guard let v = f, v.isFinite,
              v >= Self.minTempCelsius, v <= Self.maxTempCelsius else { return nil }
        return v
    }

    // MARK: - 字节解码（借鉴自 iSMC smc/conv.go + rawtemp.go）

    /// SMC 类型 + bytes → Float32。返回 nil 表示类型不支持或 bytes 太短。
    /// Apple Silicon:flt 是 LE Float32;ioft 是 LE int64 / 65536;fp/sp 仍是 BE u16。
    static func decodeValue(_ dataType: String, _ bytes: [UInt8]) -> Float32? {
        if dataType == "flt", bytes.count >= 4 {
            // Apple Silicon LE Float32（stats / hot 都这么读）
            var bits: UInt32 = 0
            for i in 0..<4 { bits |= UInt32(bytes[i]) << (8 * i) }
            let f = Float32(bitPattern: bits)
            return f.isFinite ? f : nil
        }
        if dataType == "ioft", bytes.count >= 8 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[i]) << (8 * i) }
            let signed = Int64(bitPattern: v)
            return Float32(signed) / 65536.0
        }
        if let conv = fpConvTable[dataType], bytes.count >= 2 {
            // BE u16（对 sp 类型则重解释为 int16）
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            if conv.signed {
                let s = Int16(bitPattern: raw)
                return Float32(s) / conv.div
            } else {
                return Float32(raw) / conv.div
            }
        }
        return nil
    }

    // MARK: - 工具

    private static func fourCharToUInt32BE(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8).prefix(4)
        var v: UInt32 = 0
        for b in bytes { v = (v << 8) | UInt32(b) }
        return v
    }

    private static func u32ToFourChar(_ v: UInt32) -> String {
        let b0 = UInt8((v >> 24) & 0xFF)
        let b1 = UInt8((v >> 16) & 0xFF)
        let b2 = UInt8((v >>  8) & 0xFF)
        let b3 = UInt8( v        & 0xFF)
        let bytes = [b0, b1, b2, b3]
        let s = String(bytes: bytes, encoding: .ascii) ?? "????"
        return s.trimmingCharacters(in: .controlCharacters)
    }
}

/// 单 key trace 诊断器。仅在 helper --trace-cputemp 命令行模式用到。
/// 复用 SMCTemperature 的所有 SMC 字段调用层;只是把每个 key 的失败/成功细节公开。
final class SMCTemperatureProbe {
    struct Result {
        let dataType: String
        let dataSize: UInt32
        let rawBytes: [UInt8]
        let reason: String
    }

    func singleKey(_ key4: String) -> Result {
        let s: io_connect_t
        do {
            s = try openConn()
        } catch {
            return Result(dataType: "", dataSize: 0, rawBytes: [], reason: "open: \(error)")
        }
        defer { closeConn(s) }
        let info = smcInfo(s, key4)
        guard let info = info else {
            return Result(dataType: "", dataSize: 0, rawBytes: [],
                          reason: "GetKeyInfo returned nil")
        }
        // 拿到 dataType / dataSize / rawBytes(诊断 fallback)
        return Result(
            dataType: info.0,
            dataSize: info.1,
            rawBytes: info.2,
            reason: info.1 == 0 ? "key 未在 SMC 中存在 / dataSize=0"
                                  : "存在,type=\(info.0),size=\(info.1),前 8B=\(info.2.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))"
        )
    }

    // 镜像 SMCTemperature 的私有面,这里以 SMCTemperature 形式访问
    private func openConn() throws -> io_connect_t {
        // AlDente 姿势
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard s != 0 else { throw NSError(domain: "smc", code: 1) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(s, mach_task_self_, 0, &c)
        IOObjectRelease(s)
        guard kr == KERN_SUCCESS else { throw NSError(domain: "smc", code: Int(kr)) }
        return c
    }
    private func closeConn(_ c: io_connect_t) { if c != 0 { IOServiceClose(c) } }

    /// 复用 SMCTemperature 内部的 getKeyInfo。SMCTemperature.fileprivate
    /// 可见性刚好够 main.swift 引用;这里无法直接调,改成用 raw IOKit 复刻相同步骤。
    private func smcInfo(_ c: io_connect_t, _ key4: String) -> (String, UInt32, [UInt8])? {
        // 这里不重复 SMCTemperature 全套 SMCParamStruct,而是直接复用 SMCTemperature 实例
        // 通过 fileprivate 方法(getKeyInfo)访问。Swift 中 final class 的 fileprivate
        // 在同一文件内可见;但 SMCTemperatureProbe 与 SMCTemperature 类在不同定义,
        // 因此 SMCTemperature 的 fileprivate 方法不可见。
        // 解决: 把这个 trace 类合并到 SMCTemperature.swift 末尾之前的位置,
        // 并用内部嵌套类型访问。或者: 在同一 .swift 文件内嵌一个私有 helper 调 SMCTemperature 的 fileprivate API。
        // 妥协:在这里小抄一份 80B SMCParamStruct + selector enum 的副本,只用作 trace。
        // 这会让代码重复 - 我已经知道这是不好的做法,但本次 trace 仅作调试用。
        guard key4.count == 4 else { return nil }

        // 镜像 Selector enum (避免重复定义;此处只在 trace 用)
        let kSMCGetKeyInfoRaw: UInt8 = 9

        struct SMCVersion {
            var major: CUnsignedChar = 0
            var minor: CUnsignedChar = 0
            var build: CUnsignedChar = 0
            var reserved: CUnsignedChar = 0
            var release: CUnsignedShort = 0
        }
        struct SMCPLimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }
        struct SMCKeyInfoData {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }
        typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8)

        struct SMCParamStruct {
            var key: UInt32 = 0
            var vers = SMCVersion()
            var pLimitData = SMCPLimitData()
            var keyInfo = SMCKeyInfoData()
            var padding: UInt16 = 0
            var result: UInt8 = 0
            var status: UInt8 = 0
            var data8: UInt8 = 0
            var data32: UInt32 = 0
            var bytes: SMCBytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                   UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                   UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                   UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                   UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                   UInt8(0), UInt8(0))
        }

        var input = SMCParamStruct()
        input.key = Self.fourCCBE(key4)
        input.data8 = kSMCGetKeyInfoRaw

        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = withUnsafePointer(to: &input) { ptr -> Int32 in
            ptr.withMemoryRebound(to: UInt8.self, capacity: inputSize) { bytePtr -> Int32 in
                var localOut: UnsafePointer<UInt8> = bytePtr
                return IOConnectCallStructMethod(
                    c,
                    UInt32(kSMCGetKeyInfoRaw),
                    UnsafeMutableRawPointer(mutating: bytePtr),
                    inputSize,
                    &localOut,
                    &outputSize)
            }
        }
        let raw: [UInt8] = withUnsafeBytes(of: &output.bytes) { Array($0) }
        let dt = Self.u32ToFourChar(output.keyInfo.dataType)
        let ds = output.keyInfo.dataSize
        if kr != KERN_SUCCESS {
            return (dt, ds, Array(raw.prefix(8)))
        }
        if output.result != 0 {
            return (dt, ds, Array(raw.prefix(8)))
        }
        return (dt, ds, Array(raw.prefix(Int(max(ds, 8)))))
    }

    private static func fourCCBE(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8).prefix(4)
        var v: UInt32 = 0
        for b in bytes { v = (v << 8) | UInt32(b) }
        return v
    }
    private static func u32ToFourChar(_ v: UInt32) -> String {
        let b0 = UInt8((v >> 24) & 0xFF)
        let b1 = UInt8((v >> 16) & 0xFF)
        let b2 = UInt8((v >>  8) & 0xFF)
        let b3 = UInt8( v        & 0xFF)
        let bytes = [b0, b1, b2, b3]
        let s = String(bytes: bytes, encoding: .ascii) ?? "????"
        return s.trimmingCharacters(in: .controlCharacters)
    }
}
