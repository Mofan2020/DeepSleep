//
//  SMCTemperature.swift
//  deepsleep-helper
//
//  通过 Apple SMC IOKit 读 CPU 温度。仅 deepsleep-helper 编译。
//
// ============================================================================
// 设计 / 借鉴声明
// ============================================================================
// 本文件**借鉴** dkorunic/iSMC 项目（https://github.com/dkorunic/iSMC,
// GPL-3.0）的算法原理。借鉴的具体内容：
//
//   1. SMC IOKit 接口调用姿势：
//      - IOServiceMatching("AppleSMC") → IOServiceGetMatchingServices
//      - IOServiceOpen 拿到 io_connect_t
//      - IOConnectCallStructMethod + KernelIndexSMC（=2）+ 子命令 SMCReadKey（=2）
//      - SMCKeyData 内存布局（keyInfo 段 + SMCVal 输出段）
//      以上是 Apple SMC IOKit 的公开接口形状，不是 iSMC 的原创，
//      但 iSMC 的 Go 包装是公共实现里写得最干净的，本文件照同一形状实现。
//
//   2. SMC 数据类型 → °C 解码公式：
//      - fp1f..fp88/fpa6/fpc4/fpe2：BE u16 / 2^小数位数（unsiged）
//      - sp1e..sp96/spa5/spb4/spf0：BE u16 重解释为 int16 / 2^小数位数（signed）
//      - flt：LE Float32bits（4 字节）
//      - ioft：LE int64 / 65536
//      - Ta0P 特殊：plist 标 flt 但实际是 sp78
//      以上解码事实源自 Apple 公开文档与社区多源验证，iSMC 的 AppleFPConv
//      字典是该领域最完整的整理，本文件复用同一组事实。
//
//   3. 合理性窗口：温度 [-100, 200] °C（与 iSMC rawTempMin/Max 一致）。
//
// 本文件与 iSMC 的关系：
//   - **不是 iSMC 源码的 Swift 翻译**。iSMC 用 Go + CGO，结构体布局、
//     错误处理、并发模型完全不同；本文件用纯 Swift 走 IOKit C API。
//   - **不是 iSMC 的 fork 或 import**。没有复制 iSMC 一行 Go 代码。
//   - **没有混入 GPL 代码**。DeepSleep 是 MIT，iSMC 是 GPL-3.0；
//     本文件独立用 Swift 重写，不污染 DeepSleep 的 MIT 许可证。
//
// 这条借鉴声明同时写在 docs/notes.md（开发笔记）+ commit message 里，
// 方便后续维护者理解「算法从哪来 / 代码是怎么写的」。
// ============================================================================
//

import Foundation
import IOKit

/// Apple SMC IOKit 接口。root 进程独占使用，不考虑并发。
///
/// 每个 helper 命令触发一次 `readSample()`,内部按需打开/关闭连接。
/// 单次连接只读一次的原因:helper 重启成本低于长时间持有 SMC 连接,
/// 同时避免 SMC 连接异常挂掉时 helper 卡死的风险。
final class SMCTemperature {

    // MARK: - SMC 协议常量(借鉴自 iSMC smc/raw.go + Apple SMC 文档)

    private static let kernelIndexSMC: UInt32 = 0x2
    private static let cmdReadKey: UInt8 = 2
    private static let bytesMax: Int = 32

    // MARK: - SMC 字节解码字典(借鉴自 iSMC smc/conv.go AppleFPConv)

    private struct FPConv { let div: Float32; let signed: Bool }

    /// 与 iSMC 的 AppleFPConv 一一对应。Apple SMC 文档里 spXY / fpXY
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

    // MARK: - 温度合理性窗口(借鉴自 iSMC smc/rawtemp.go rawTempMin/Max)

    private static let minTempCelsius: Float = -100.0
    private static let maxTempCelsius: Float = 200.0

    // MARK: - 目标 SMC key

    /// Apple Silicon 通用 CPU Die 温度 key。
    /// `Platform: "Apple"`(见 iSMC smc/sensors.go AppleTemp)。
    /// 在 M1/M2/M3/M4 上都存在；key 实际类型由 firmware 决定,
    /// 我们靠通用解码吃下 fp/sp/flt 三种可能。
    private static let keyMax = "TCMz"        // CPU Die Max
    private static let keyAverage = "TCMb"    // CPU Die Average
    private static let keyAggregate = "TCDX"  // CPU Die Aggregate

    // MARK: - 公开 API

    enum SMCError: Error {
        case openFailed(String)
        case readFailed(key: String, status: Int32)
        case invalidKey(String)
    }

    /// 读一次 CPU 温度样本。
    /// - Returns: 三个字段任意一个读到就填对应槽位,读不到/超出窗口就保持 nil。
    /// - Throws: SMC 接口本身打不开时(理论 root 下不会)。
    func readSample() throws -> CPUTemperatureSample {
        let conn = try openConnection()
        defer { closeConnection(conn) }

        let maxC = readTemperature(conn, key: Self.keyMax)
        let avgC = readTemperature(conn, key: Self.keyAverage)
        let aggC = readTemperature(conn, key: Self.keyAggregate)

        return CPUTemperatureSample(
            maxC: maxC.map { Double($0) },
            averageC: avgC.map { Double($0) },
            aggregateC: aggC.map { Double($0) }
        )
    }

    // MARK: - 连接管理

    private func openConnection() throws -> io_connect_t {
        guard let service = IOServiceMatching("AppleSMC") else {
            throw SMCError.openFailed("IOServiceMatching 返回 nil")
        }
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, service, &iter)
        guard kr == KERN_SUCCESS, iter != IO_OBJECT_NULL else {
            throw SMCError.openFailed("IOServiceGetMatchingServices 返回 \(kr)")
        }
        defer { IOObjectRelease(iter) }

        let firstObj = IOIteratorNext(iter)
        guard firstObj != IO_OBJECT_NULL else {
            throw SMCError.openFailed("没有匹配 AppleSMC 的服务对象")
        }
        defer { IOObjectRelease(firstObj) }

        var conn: io_connect_t = 0
        let kr2 = IOServiceOpen(firstObj, mach_task_self_, 0, &conn)
        guard kr2 == KERN_SUCCESS else {
            throw SMCError.openFailed("IOServiceOpen 返回 \(kr2)")
        }
        return conn
    }

    private func closeConnection(_ conn: io_connect_t) {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: - 单 key 读取

    /// SMCKeyData 内存布局:
    ///   input 段(keyInfo,32 字节):
    ///     key(u32) | vers(u8) + 3 pad | data8(u8) + 3 pad | data32(u32) | data64(u64)
    ///     (注:Swift 侧把 data8 与 pad 合并到 UInt32 中方便统一偏移)
    ///   output 段(SMCVal,32 字节):
    ///     key(u32) | vers(u8) + 3 pad | reserved(u32) | dataType(u32) | dataSize(u32) | bytes[32]
    ///
    /// 严格按 IOKit SMC 头文件 SMCDataStruct.h 的顺序排列,
    /// **不依赖 iSMC 的 Go struct 布局**(我们用 Swift 独立写出)。
    private struct SMCKeyData {
        // keyInfo 段(前 32 字节)
        var key: UInt32 = 0           // upper command;对 SMCReadKey 用 1(直接 by-name)
        var data8Padded: UInt32 = 0    // 低 8 位是子命令(SMCReadKey = 2)
        var data32: UInt32 = 0         // key 4-char BE(读 by-index 时用)
        var data64: UInt64 = 0         // (keyName << 32) | bytesRequested
        // SMCVal 段(后 32 字节,首 16 字节)
        var outKey: UInt32 = 0
        var outVersPadded: UInt32 = 0  // 低 8 位是 vers
        var outReserved: UInt32 = 0
        // SMCVal 段(后 32 字节,后 16 字节)
        var outData32: UInt32 = 0      // dataType(4-char 紧凑 u32)
        var outData64: UInt64 = 0      // 低 32 位是 bytesCount
        // SMCVal.bytes(32 字节)
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    /// 读取 key 的 raw(type + bytes)。失败返回 nil。
    private func readKey(_ conn: io_connect_t, key4: String) -> (dataType: String, bytes: [UInt8])? {
        guard key4.count == 4 else { return nil }
        let keyBE = Self.fourCharToUInt32BE(key4)

        var data = SMCKeyData()
        data.key = 1                                          // 上层命令:直接按 name 读
        data.data8Padded = UInt32(Self.cmdReadKey)            // 子命令:SMCReadKey
        data.data32 = keyBE                                   // name(冗余,但部分 firmware 需要)
        data.data64 = (UInt64(keyBE) << 32) | UInt64(Self.bytesMax)

        var outputSize = MemoryLayout<SMCKeyData>.stride
        let kr: kern_return_t = withUnsafePointer(to: &data) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<SMCKeyData>.stride) { bytePtr -> kern_return_t in
                var localOut: UnsafePointer<UInt8> = bytePtr
                return IOConnectCallStructMethod(
                    conn,
                    Self.kernelIndexSMC,
                    UnsafeMutableRawPointer(mutating: bytePtr),
                    MemoryLayout<SMCKeyData>.stride,
                    &localOut,
                    &outputSize
                )
            }
        }
        guard kr == KERN_SUCCESS else {
            return nil
        }
        let dataType = Self.u32ToFourChar(data.outData32)
        let dataSize = UInt32(data.outData64 & 0xFFFF_FFFF)
        let bytes: [UInt8] = withUnsafeBytes(of: &data.bytes) { Array($0) }
        return (dataType, Array(bytes.prefix(Int(dataSize))))
    }

    /// 读一个 key 并按温度解码。读不到 / 类型不认识 / 数值出窗口 → 返回 nil。
    private func readTemperature(_ conn: io_connect_t, key: String) -> Float32? {
        guard let r = readKey(conn, key4: key) else { return nil }
        let f: Float32?
        // 借鉴自 iSMC:Ta0P 例外 — plist 标 flt 但实际是 sp78。
        // 我们也对 `flt` 但前面看 M2 实际以 fp88 为主。统一走 decodeValue,
        // Ta0P 例外保留以防 SMC 固件对部分机型这么标。
        if r.dataType == "flt", key == "Ta0P", r.bytes.count >= 2 {
            let raw = (UInt16(r.bytes[0]) << 8) | UInt16(r.bytes[1])
            let s = Int16(bitPattern: raw)
            f = Float32(s) / 256.0
        } else {
            f = Self.decodeValue(r.dataType, r.bytes)
        }
        guard let v = f, v.isFinite,
              v >= Self.minTempCelsius, v <= Self.maxTempCelsius else { return nil }
        return v
    }

    // MARK: - 字节解码(借鉴自 iSMC smc/conv.go + rawtemp.go)

    /// SMC 类型 + bytes → Float32。返回 nil 表示类型不支持或 bytes 太短。
    static func decodeValue(_ dataType: String, _ bytes: [UInt8]) -> Float32? {
        if dataType == "flt", bytes.count >= 4 {
            // LE Float32bits
            var bits: UInt32 = 0
            for i in 0..<4 { bits |= UInt32(bytes[i]) << (8 * i) }
            let f = Float32(bitPattern: bits)
            return f.isFinite ? f : nil
        }
        if dataType == "ioft", bytes.count >= 8 {
            // LE signed int64 / 65536
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[i]) << (8 * i) }
            let signed = Int64(bitPattern: v)
            return Float32(signed) / 65536.0
        }
        if let conv = fpConvTable[dataType], bytes.count >= 2 {
            // BE u16(对 sp 类型则重解释为 int16)
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
