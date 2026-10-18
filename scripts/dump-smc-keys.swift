//
//  dump-smc-keys.swift
//  Deep Sleep 诊断工具
//
//  借鉴自 AppHouseKitchen/AlDente-Battery_Care_and_Monitoring
//    com.davidwernhart.Helper/SMC.swift(MIT / beltex SMCKit 风格)
//  关键差异: AlDente 把 selector 直接当 IOConnectCallStructMethod 的
//  selectorId,kernelIndexSMC = 0x2 这种 iSMC 风格在这里完全不要用。
//
//  本脚本是诊断工具,只在调试时手动跑,不会参与 release 链路。
//
//  必须以 root 跑:
//    sudo swift scripts/dump-smc-keys.swift
//

import Foundation
import IOKit

// -- 以下 struct 字段 / Selector enum 与 AlDente 的 SMCParamStruct 一致 --
// 借鉴自 AlDente 的 SMC.swift(MIT)。本脚本直接挪了它的 80 字节内存布局
// 与 selector 编号表,跟 helper 端目前用的 iSMC 风格字段命名有差异,
// 因为 AlDente 是把 selector 当 selectorId 用的,所以 input struct 不需要
// 单独的"data8 字段"——selector 编号直接喂给 IOConnect。

public typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8)

public struct SMCParamStruct {
    public enum Selector: UInt8 {
        case kSMCHandleYPCEvent  = 2
        case kSMCReadKey         = 5
        case kSMCWriteKey        = 6
        case kSMCGetKeyFromIndex = 8
        case kSMCGetKeyInfo      = 9
    }
    public enum Result: UInt8 {
        case kSMCSuccess     = 0
        case kSMCError       = 1
        case kSMCKeyNotFound = 132
    }

    public struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    public struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    public struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// FourCharCode telling the SMC what we want
    var key: UInt32 = 0

    var vers = SMCVersion()

    var pLimitData = SMCPLimitData()

    var keyInfo = SMCKeyInfoData()

    /// Padding for struct alignment when passed over to C side
    var padding: UInt16 = 0

    var result: UInt8 = 0

    var status: UInt8 = 0

    /// Selector 与 selectorId 同一位置;AlDente 把它当 data8 / 由 inputData8 喂
    var data8: UInt8 = 0

    var data32: UInt32 = 0

    /// Data returned from the SMC
    var bytes: SMCBytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0))
}

// -- 工具 --

private func fourCCBE(_ s: String) -> UInt32 {
    precondition(s.count == 4)
    var v: UInt32 = 0
    for b in Array(s.utf8) { v = (v << 8) | UInt32(b) }
    return v
}
private func u32To4CC(_ v: UInt32) -> String {
    let b0 = UInt8((v >> 24) & 0xFF)
    let b1 = UInt8((v >> 16) & 0xFF)
    let b2 = UInt8((v >>  8) & 0xFF)
    let b3 = UInt8( v        & 0xFF)
    return String(bytes: [b0, b1, b2, b3], encoding: .ascii)?
        .trimmingCharacters(in: .controlCharacters) ?? "????"
}
private func pad(_ s: String, _ w: Int) -> String {
    if s.count >= w { return s }
    return s + String(repeating: " ", count: w - s.count)
}

// 8 字节 raw bytes → UInt32(AlDente 用 Big Endian for SMC fds / keyCount 这类)
private func u32BE(bytes: SMCBytes) -> UInt32 {
    (UInt32(bytes.0) << 24) | (UInt32(bytes.1) << 16)
    | (UInt32(bytes.2) << 8) |  UInt32(bytes.3)
}
// 类型 4cc from u32
private func type4cc(_ v: UInt32) -> String { u32To4CC(v) }

// -- SMC 通信(借鉴 AlDente callDriver) --

private func smcCall(_ conn: io_connect_t,
                     selector: SMCParamStruct.Selector,
                     input: inout SMCParamStruct) -> (Int32, SMCParamStruct) {
    var output = SMCParamStruct()
    let inputSize = MemoryLayout<SMCParamStruct>.stride
    var outputSize = MemoryLayout<SMCParamStruct>.stride
    let kr = withUnsafePointer(to: &input) { ptr -> Int32 in
        ptr.withMemoryRebound(to: UInt8.self, capacity: inputSize) { bytePtr -> Int32 in
            var localOut: UnsafePointer<UInt8> = bytePtr
            return IOConnectCallStructMethod(
                conn,
                UInt32(selector.rawValue),    // AlDente 风格:selector 直接是 selectorId
                UnsafeMutableRawPointer(mutating: bytePtr),
                inputSize,
                &localOut,
                &outputSize)
        }
    }
    // kr 是从 IOConnect 的 kern return
    _ = input  // 防止优化掉
    return (kr, output)
}

// 在 AlDente 风格下,read/get 是:kr=0 && result=0 → 成功
private func smcIsOk(_ kr: Int32, _ result: UInt8) -> Bool {
    if kr != 0 { return false }
    if result != SMCParamStruct.Result.kSMCSuccess.rawValue { return false }
    return true
}

// -- 主流程 --

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("必须以 root 跑（sudo swift scripts/dump-smc-keys.swift）\n".utf8))
    exit(1)
}

// 跟 AlDente 完全一致
let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                          IOServiceMatching("AppleSMC"))
guard service != 0 else {
    print("无法匹配 AppleSMC service")
    exit(1)
}
var conn: io_connect_t = 0
let openKr = IOServiceOpen(service, mach_task_self_, 0, &conn)
IOObjectRelease(service)
guard openKr == KERN_SUCCESS else {
    print("无法打开 AppleSMC 连接: kr=0x\(String(UInt32(bitPattern: openKr), radix: 16))")
    exit(1)
}
defer { IOServiceClose(conn) }
print("[connect] AppleSMC 直连 ✅\n")

print("=== SMC 枚举诊断（AlDente / MIT 借鉴姿势）===")
let osVer = ProcessInfo.processInfo.operatingSystemVersionString
print("系统: \(osVer)\n")

// ---- 列 SMC 全部 keys:用 by-index 试到 kSMCKeyNotFound ----
print("[握手测试] by-index 枚举前 5 ...")
for i in 0..<5 {
    var probeInput = SMCParamStruct()
    probeInput.data8 = SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue
    probeInput.data32 = UInt32(i)
    var probeOutput = SMCParamStruct()
    let inputSize = MemoryLayout<SMCParamStruct>.stride
    var outputSize = MemoryLayout<SMCParamStruct>.stride
    let kr = withUnsafePointer(to: &probeInput) { ptr -> Int32 in
        ptr.withMemoryRebound(to: UInt8.self, capacity: inputSize) { bytePtr -> Int32 in
            var localOut: UnsafePointer<UInt8> = bytePtr
            return IOConnectCallStructMethod(
                conn,
                UInt32(SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue),
                UnsafeMutableRawPointer(mutating: bytePtr),
                inputSize,
                &localOut,
                &outputSize)
        }
    }
    let name4cc = u32To4CC(probeOutput.key)
    let krHex = String(UInt32(bitPattern: kr), radix: 16)
    print("  [idx=\(i)] kr=0x\(krHex)  result=\(probeOutput.result)  name=\(name4cc)")
}
print("")
exit(0)
var total = 0
while total < 4096 {
    var probeInput = SMCParamStruct()
    probeInput.data8 = SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue
    probeInput.data32 = UInt32(total)
    let (k, out) = smcCall(conn, selector: .kSMCGetKeyFromIndex, input: &probeInput)
    if k != 0 { break }
    if out.result == SMCParamStruct.Result.kSMCKeyNotFound.rawValue { break }
    if out.result != SMCParamStruct.Result.kSMCSuccess.rawValue { break }
    total += 1
}
print("枚举到 \(total) 个 key ✅\n")

if total > 0 {
    // ---- 验证 2:kSMCGetKeyFromIdx 拿 0..N 个 key 名字 ----
    print("KEY     | dataType | size | raw(first 4B) | decode")
    print("--------|----------|------|---------------|-------")

    var hotByPrefix: [String: Int] = [:]
    var sampleKeys: [(String, String, UInt32, SMCBytes)] = []  // name, type, dataSize, bytes
    let scanLimit = min(total, 256)  // 防止异常 #KEY 把脚本拖死
    for i in 0..<scanLimit {
        var idxInput = SMCParamStruct()
        idxInput.data8 = SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue
        idxInput.data32 = UInt32(i)
        let (kr, out) = smcCall(conn, selector: .kSMCGetKeyFromIndex, input: &idxInput)
        guard smcIsOk(kr, out.result) else { continue }
        let name = u32To4CC(out.key)
        guard !name.isEmpty, name != "????" else { continue }

        // GetKeyInfo
        var kiInput = SMCParamStruct()
        kiInput.key = out.key
        kiInput.data8 = SMCParamStruct.Selector.kSMCGetKeyInfo.rawValue
        let (krInfo, outInfo) = smcCall(conn, selector: .kSMCGetKeyInfo, input: &kiInput)
        guard smcIsOk(krInfo, outInfo.result) else { continue }
        let dt = u32To4CC(outInfo.keyInfo.dataType)
        let ds = outInfo.keyInfo.dataSize
        if ds == 0 { continue }

        // ReadBytes(AlDente 说是 kSMCReadKey)
        var rbInput = SMCParamStruct()
        rbInput.key = out.key
        rbInput.keyInfo.dataSize = ds
        rbInput.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        let (krRb, outRb) = smcCall(conn, selector: .kSMCReadKey, input: &rbInput)
        guard smcIsOk(krRb, outRb.result) else { continue }

        let rawHex = "\(String(format: "%02x", outRb.bytes.0)) \(String(format: "%02x", outRb.bytes.1)) \(String(format: "%02x", outRb.bytes.2)) \(String(format: "%02x", outRb.bytes.3))"

        // 解码 flt (LE Float32bits)
        let cellText: String
        if dt == "flt", ds >= 4 {
            var bits: UInt32 = 0
            for j in 0..<4 { bits |= UInt32(outRb.bytes.0 &>> (8 * j) & 0xFF) << (8 * j) }
            // 上面写法有 right-shift unsigned 隐患;直接用 byte 序列:
            bits = UInt32(outRb.bytes.0) | (UInt32(outRb.bytes.1) << 8)
                 | (UInt32(outRb.bytes.2) << 16) | (UInt32(outRb.bytes.3) << 24)
            let f = Float32(bitPattern: bits)
            if f.isFinite, f >= -50, f <= 200 {
                cellText = String(format: "%.2f", f)
            } else {
                cellText = "—"
            }
        } else if dt == "sp78", ds >= 2 {
            // BE u16 重解释 int16 / 256
            let raw = (UInt16(outRb.bytes.0) << 8) | UInt16(outRb.bytes.1)
            let s = Int16(bitPattern: raw)
            let v = Float32(s) / 256.0
            cellText = v.isFinite ? String(format: "%.2f", v) : "—"
        } else if dt == "ui32", ds >= 4 {
            let v = UInt32(outRb.bytes.0) | (UInt32(outRb.bytes.1) << 8)
                  | (UInt32(outRb.bytes.2) << 16) | (UInt32(outRb.bytes.3) << 24)
            cellText = "\(v)"
        } else if dt == "ui8", ds >= 1 {
            cellText = "\(outRb.bytes.0)"
        } else if dt == "fpe2", ds >= 2 {
            // BE u16 14.2 unsigned
            let raw = (UInt16(outRb.bytes.0) << 8) | UInt16(outRb.bytes.1)
            let v = Int(raw >> 2)  // 简化
            cellText = "\(v)"
        } else {
            cellText = "—"
        }

        let prefix = String(name.prefix(2))
        if name.first == "T" { hotByPrefix[prefix, default: 0] += 1 }

        // 只打 T/F/V/P 开头的 key
        if let firstCh = name.first, ["T","F","V","P"].contains(firstCh) {
            let line = "\(pad(name, 7)) | \(pad(dt, 8)) | \(pad(String(ds), 4)) | \(pad(rawHex, 14)) | \(cellText)"
            print(line)
        }
        sampleKeys.append((name, dt, ds, outRb.bytes))
    }

    print("\n[温度前缀分布]")
    let sorted = hotByPrefix.sorted { $0.value > $1.value }
    for (k, n) in sorted {
        print("  \(pad(k, 4)) \(n)")
    }
} else {
    print("枚举 #KEY 失败:0 个 key 拿到")
}
