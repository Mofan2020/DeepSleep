//
//  test-npu-gpu-metrics.swift
//  Deep Sleep 回归测试
//
//  验证 Shared/NgAcceleratorMetrics.swift 的解码与状态判定：
//   - 有值：IOAccelerator 的 PerformanceStatistics 真实键名能解出三个百分比
//   - 无值：字典为空 / 键缺失 → nil，界面显示「不可用」而不是 0
//   - 畸形：非数字、空串、负数、超 100、NaN / Inf、带空格、小数
//   - NPU：读不到时带原因；有读数时原因必须被清掉
//
//  运行：
//  swiftc -parse-as-library \
//    Shared/NgAcceleratorMetrics.swift \
//    scripts/test-npu-gpu-metrics.swift -o /tmp/t_npngpu && /tmp/t_npngpu
//

import Foundation

@main
struct NgAcceleratorMetricsTests {

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        func checkClose(_ name: String, _ expected: Double, _ actual: Double?,
                        tolerance: Double = 0.001) {
            guard let actual else {
                check(name, false, "期望 \(expected)，实际 nil")
                return
            }
            let ok = abs(expected - actual) <= tolerance
            check(name, ok, String(format: "期望 %.4f，实际 %.4f", expected, actual))
        }

        // ------------------------------------------- 有值：真实 ioreg 输出
        print("== 有值：PerformanceStatistics 真实键名 ==")

        // 本机实测的一行（ioreg -r -d 1 -w 0 -c IOAccelerator）：
        // "PerformanceStatistics" = {"In use system memory (driver)"=0,
        //   "Alloc system memory"=4071260160,"Tiler Utilization %"=32,
        //   "Renderer Utilization %"=32,"Device Utilization %"=33, …}
        let realStats: [String: String] = [
            "Device Utilization %": "33",
            "Renderer Utilization %": "32",
            "Tiler Utilization %": "32",
            "In use system memory (driver)": "0",
            "Alloc system memory": "4071260160",
            "Allocated PB Size": "79691776",
            "recoveryCount": "0",
        ]
        let real = NgAcceleratorDecoder.decodeStatistics(realStats)

        checkClose("设备占用解出 33%", 33, real.gpuDevicePercent)
        checkClose("渲染器占用解出 32%", 32, real.gpuRendererPercent)
        checkClose("分块占用解出 32%", 32, real.gpuTilerPercent)
        check("采到 GPU 读数", real.hasGPUReading)
        check("无关的内存计数器不影响结果", real.gpuDevicePercent == 33)
        check("NPU 默认没有读数", !real.hasNPUReading)
        check("NPU 没有读数时也没有原因", real.npuUnavailableReason == nil)

        // ----------------------------------------------------- 无值：读不到
        print("\n== 无值：读不到 ==")

        let empty = NgAcceleratorDecoder.decodeStatistics([:])
        check("空字典时设备占用为 nil", empty.gpuDevicePercent == nil)
        check("空字典时渲染器占用为 nil", empty.gpuRendererPercent == nil)
        check("空字典时分块占用为 nil", empty.gpuTilerPercent == nil)
        check("空字典时不算采到 GPU", !empty.hasGPUReading)

        let partial = NgAcceleratorDecoder.decodeStatistics(
            ["Device Utilization %": "17"])
        checkClose("只给设备占用时解出 17%", 17, partial.gpuDevicePercent)
        check("缺失的渲染器占用是 nil", partial.gpuRendererPercent == nil)
        check("缺失的分块占用是 nil", partial.gpuTilerPercent == nil)
        check("只给一个计数器也算采到 GPU", partial.hasGPUReading)

        let missingKey = NgAcceleratorDecoder.decodeStatistics(
            ["Device Utilisation %": "40"])
        check("键名拼错时读不到（不能当成 0）",
              missingKey.gpuDevicePercent == nil)
        check("键名拼错时不算采到 GPU", !missingKey.hasGPUReading)

        // ------------------------------------------------------- 畸形输出
        print("\n== 畸形输出 ==")

        check("非数字读不到", NgAcceleratorDecoder.percent(from: "abc") == nil)
        check("空串读不到", NgAcceleratorDecoder.percent(from: "") == nil)
        check("纯空格读不到", NgAcceleratorDecoder.percent(from: "   ") == nil)
        check("nil 读不到", NgAcceleratorDecoder.percent(from: nil) == nil)
        check("负数读不到", NgAcceleratorDecoder.percent(from: "-5") == nil)
        check("大于 100 读不到", NgAcceleratorDecoder.percent(from: "150") == nil)
        check("NaN 读不到", NgAcceleratorDecoder.percent(from: "nan") == nil)
        check("Inf 读不到", NgAcceleratorDecoder.percent(from: "inf") == nil)
        check("带百分号读不到", NgAcceleratorDecoder.percent(from: "33%") == nil)
        check("带单位读不到", NgAcceleratorDecoder.percent(from: "33 ms") == nil)

        checkClose("前后空格会被去掉", 42, NgAcceleratorDecoder.percent(from: " 42 "))
        checkClose("小数能解出来", 33.5, NgAcceleratorDecoder.percent(from: "33.5"))
        checkClose("0 是合法读数", 0, NgAcceleratorDecoder.percent(from: "0"))
        checkClose("100 是合法读数", 100, NgAcceleratorDecoder.percent(from: "100"))

        // 畸形值混在真实输出里：好的那个照常解出来，坏的那个读不到。
        let mixed = NgAcceleratorDecoder.decodeStatistics([
            "Device Utilization %": "33",
            "Renderer Utilization %": "N/A",
            "Tiler Utilization %": "-1",
        ])
        checkClose("混合输出里好的那项照常解出", 33, mixed.gpuDevicePercent)
        check("混合输出里坏的那项读不到", mixed.gpuRendererPercent == nil)
        check("负数那项读不到", mixed.gpuTilerPercent == nil)

        // ---------------------------------------------------------- NPU 原因
        print("\n== NPU 读不到的原因 ==")

        let noDevice = NgAcceleratorDecoder.decodeStatistics(
            [:], npuPercent: nil, npuUnavailableReason: .noANEDevice)
        check("系统没有 ANE 节点时原因是 noANEDevice",
              noDevice.npuUnavailableReason == .noANEDevice)
        check("NPU 没有读数", !noDevice.hasNPUReading)

        let noCounter = NgAcceleratorDecoder.decodeStatistics(
            [:], npuPercent: nil, npuUnavailableReason: .noUtilizationCounter)
        check("有节点但没计数器时原因是 noUtilizationCounter",
              noCounter.npuUnavailableReason == .noUtilizationCounter)

        let withValue = NgAcceleratorDecoder.decodeStatistics(
            [:], npuPercent: 12, npuUnavailableReason: .noANEDevice)
        check("有读数时 NPU 可用", withValue.hasNPUReading)
        checkClose("NPU 读数原样带过来", 12, withValue.npuPercent)
        check("有读数时原因必须被清掉", withValue.npuUnavailableReason == nil)

        // ---------------------------------------------------------- 其它字段
        print("\n== 其它字段 ==")

        check("GPU 三个计数器都缺时不算采到",
              !NgAcceleratorDecoder.decodeStatistics([
                  "Device Utilization %": "10"
              ], npuPercent: nil).hasNPUReading)

        let stamped = NgAcceleratorDecoder.decodeStatistics(realStats, timestamp: 1_700_000_000)
        checkClose("时间戳原样带过来", 1_700_000_000, stamped.timestamp)

        // --------------------------------------------------------- 汇总
        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
