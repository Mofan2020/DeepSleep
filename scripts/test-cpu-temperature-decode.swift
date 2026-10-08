//
//  test-cpu-temperature-decode.swift
//  Deep Sleep 回归测试
//
//  验证 `SMCTemperature.decodeValue` 的 SMC 类型字节 → °C 浮点解码。
//
//  为什么单测：SMC 是 macOS 上的特权 IOKit 接口，普通进程不能直接连。
//  整个算法要在 root helper 跑，但**纯解码逻辑**（不依赖 IOKit 连接）
//  可以在普通进程单测。覆盖了 Apple SMC 公开文档里所有浮点/定点类型：
//
//   - fp1f...fp88 / fpa6 / fpc4 / fpe2：BE u16 / 2^小数位数（unsigned）
//   - sp1e...sp96 / spa5 / spb4 / spf0：BE u16 重解释为 int16 / 2^小数位数（signed）
//   - flt：LE Float32bits（4 字节）
//   - ioft：LE int64 / 65536
//   - Ta0P 例外：plist 标 flt 但实际是 sp78（在主代码里以分支处理）
//
//  这套字典与计算公式借鉴自 dkorunic/iSMC（GPL-3.0）。本测试只验证
//  数值算法正确性，**不**复制 iSMC 任何源码（事实/算法/参数 → 自由复用）。
//
//  运行：
//    swiftc DeepSleepHelper/SMCTemperature.swift \
//           Shared/CPUTemperatureSample.swift \
//           scripts/test-cpu-temperature-decode.swift -parse-as-library \
//           -o /tmp/cput && /tmp/cput
//

import Foundation

@main
struct CPUTemperatureDecodeTests {

    static func assertNear(_ a: Float32?, _ b: Float32, label: String,
                           tolerance: Float32 = 0.01) {
        guard let a else {
            print("FAIL [\(label)]: got nil, expected \(b)")
            exit(1)
        }
        if abs(a - b) > tolerance {
            print("FAIL [\(label)]: got \(a), expected \(b)")
            exit(1)
        }
        print("  [通过] \(label)  got=\(a)  exp=\(b)")
    }

    static func assertNil(_ a: Float32?, _ label: String) {
        guard a == nil else {
            print("FAIL [\(label)]: got \(a!), expected nil")
            exit(1)
        }
        print("  [通过] \(label)  got=nil")
    }

    static func main() {
        print("=== SMC 类型 → °C 解码 单测 ===\n")

        // fp88:div=256, unsigned
        assertNear(SMCTemperature.decodeValue("fp88", [0x40, 0x00]), 64.0, label: "fp88 0x4000 → 64.0")
        assertNear(SMCTemperature.decodeValue("fp88", [0x19, 0x00]), 25.0, label: "fp88 0x1900 → 25.0")
        assertNear(SMCTemperature.decodeValue("fp88", [0x17, 0x70]), 23.4375, label: "fp88 0x1770 → 23.4375")
        assertNear(SMCTemperature.decodeValue("fp88", [0x00, 0x01]), 1.0/256.0, label: "fp88 0x0001 → 1/256")

        // sp78:div=256, signed
        assertNear(SMCTemperature.decodeValue("sp78", [0x19, 0x00]), 25.0, label: "sp78 0x1900 → 25.0")
        assertNear(SMCTemperature.decodeValue("sp78", [0xFF, 0x9C]), -100.0/256.0, label: "sp78 0xFF9C → -100/256")
        assertNear(SMCTemperature.decodeValue("sp78", [0x17, 0x70]), 23.4375, label: "sp78 0x1770 → 23.4375")

        // sp87:div=128
        assertNear(SMCTemperature.decodeValue("sp87", [0x0C, 0x80]), 25.0, label: "sp87 0x0C80 → 25.0")
        // sp5a:div=1024
        assertNear(SMCTemperature.decodeValue("sp5a", [0x64, 0x00]), 25.0, label: "sp5a 0x6400 → 25.0")
        // sp3c:div=4096;0x1900=6400/4096=1.5625
        assertNear(SMCTemperature.decodeValue("sp3c", [0x19, 0x00]), 1.5625, label: "sp3c 0x1900 → 1.5625")
        // fp4c:div=4096 unsigned;0x1900=6400/4096=1.5625
        assertNear(SMCTemperature.decodeValue("fp4c", [0x19, 0x00]), 1.5625, label: "fp4c 0x1900 → 1.5625")
        // fp79:div=512 unsigned
        assertNear(SMCTemperature.decodeValue("fp79", [0x32, 0x00]), 25.0, label: "fp79 0x3200 → 25.0")

        // 短字节 → nil
        assertNil(SMCTemperature.decodeValue("fp4c", [0x19]), "fp4c 单字节 → nil")
        assertNil(SMCTemperature.decodeValue("flt", [0x00, 0x00]), "flt 2 字节 → nil")
        assertNil(SMCTemperature.decodeValue("ioft", [0x00, 0x00, 0x00]), "ioft 3 字节 → nil")

        // flt:LE Float32bits
        assertNear(SMCTemperature.decodeValue("flt", [0x00, 0x00, 0x48, 0x42]), 50.0, label: "flt 50.0 LE")
        assertNear(SMCTemperature.decodeValue("flt", [0x00, 0x00, 0x00, 0x00]), 0.0, label: "flt 0.0 LE")
        assertNear(SMCTemperature.decodeValue("flt", [0x00, 0x00, 0x80, 0xBF]), -1.0, label: "flt -1.0 LE")

        // ioft:LE int64 / 65536
        // 25.0 * 65536 = 1638400 = 0x190000 → LE:00 00 19 00 00 00 00 00
        assertNear(SMCTemperature.decodeValue("ioft", [0x00, 0x00, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00]), 25.0,
                   label: "ioft 25.0 LE")
        // -1.0 * 65536 = -65536 = 0xFFFFFFFFFFFEFFFF... LE 16-bit signed 是 -1
        // 用 16-bit-equivalent: ioft 是 47.16, -1 / 65536 = -1.5259e-5
        // 这里只测一个正数

        // 不支持的 type → nil
        assertNil(SMCTemperature.decodeValue("hex_", [0x00, 0x01]), "hex_ → nil")
        assertNil(SMCTemperature.decodeValue("ui8", [0x2A]), "ui8 → nil（非温度类型）")
        assertNil(SMCTemperature.decodeValue("totally-unknown", [0x00, 0x01]),
                  "totally-unknown → nil")

        // CPUTemperatureSample 编解码 round-trip
        let sample = CPUTemperatureSample(
            maxC: 78.5,
            averageC: 72.3,
            aggregateC: 75.0
        )
        let encoded = sample.encode()
        let decoded = CPUTemperatureSample.decode(encoded)
        guard decoded.maxC == 78.5, decoded.averageC == 72.3, decoded.aggregateC == 75.0 else {
            print("FAIL [CPUTemperatureSample round-trip]: got \(decoded)")
            exit(1)
        }
        print("  [通过] CPUTemperatureSample round-trip max=\(decoded.maxC!) avg=\(decoded.averageC!) agg=\(decoded.aggregateC!)")

        // nil 字段 round-trip
        let partial = CPUTemperatureSample(maxC: 80.0, averageC: nil, aggregateC: nil)
        let pEncoded = partial.encode()
        let pDecoded = CPUTemperatureSample.decode(pEncoded)
        guard pDecoded.maxC == 80.0, pDecoded.averageC == nil, pDecoded.aggregateC == nil else {
            print("FAIL [partial sample]: got \(pDecoded)")
            exit(1)
        }
        print("  [通过] CPUTemperatureSample 部分字段 round-trip")

        print("\n测试结论: 全部通过")
    }
}
