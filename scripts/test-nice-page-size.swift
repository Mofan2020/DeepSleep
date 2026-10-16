//
//  test-nice-page-size.swift
//  回归测试：NicePageSize.clamp 在边界与越界值上的行为。
//
//  跑：swiftc Shared/NicePageSize.swift scripts/test-nice-page-size.swift -o /tmp/t5 && /tmp/t5
//
//  MonitorConfig 那部分只在项目编译时验证（避免把 SystemMonitor / ProcessStats
//  等大文件拖进单文件 swiftc）。
//

import Foundation

private var failures = 0

private func expect(_ label: String, _ actual: Int, _ expected: Int) {
    if actual == expected {
        print("[通过] \(label): \(actual)")
    } else {
        print("[失败] \(label): 期望 \(expected)，实得 \(actual)")
        failures += 1
    }
}

func runAllTests() {
    // 1. 边界值：min / max / 默认值
    expect("minValue = 10", NicePageSize.minValue, 10)
    expect("maxValue = 30", NicePageSize.maxValue, 30)
    expect("defaultValue = 20", NicePageSize.defaultValue, 20)

    // 2. clamp 在合法范围内：原样返回
    expect("clamp(20) = 20", NicePageSize.clamp(20), 20)
    expect("clamp(10) = 10", NicePageSize.clamp(10), 10)
    expect("clamp(30) = 30", NicePageSize.clamp(30), 30)

    // 3. clamp 在越界值上：钳到边界
    expect("clamp(5)  → 10",  NicePageSize.clamp(5),  10)
    expect("clamp(0)  → 10",  NicePageSize.clamp(0),  10)
    expect("clamp(-5) → 10",  NicePageSize.clamp(-5), 10)
    expect("clamp(31) → 30",  NicePageSize.clamp(31), 30)
    expect("clamp(99) → 30",  NicePageSize.clamp(99), 30)
    expect("clamp(Int.max) → 30", NicePageSize.clamp(Int.max), 30)

    // 4. description 字符串包含上下限与默认值（供 UI 副标题用）
    let desc = NicePageSize.description
    expect("description 含 '10'", desc.contains("10") ? 1 : 0, 1)
    expect("description 含 '30'", desc.contains("30") ? 1 : 0, 1)
    expect("description 含 '20'", desc.contains("20") ? 1 : 0, 1)

    print()
    if failures == 0 {
        print("测试结论: 全部通过")
    } else {
        print("测试结论: \(failures) 项失败")
        exit(1)
    }
}

@main
struct TestEntry {
    static func main() {
        runAllTests()
    }
}