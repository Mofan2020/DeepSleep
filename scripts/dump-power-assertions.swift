//
//  dump-power-assertions.swift
//  Deep Sleep 诊断工具
//
//  列出当前系统里所有持有电源断言的进程 —— 也就是「谁在阻止休眠」。
//  用于确认本应用要呈现给用户的数据能否可靠拿到。
//
//  用法：swift scripts/dump-power-assertions.swift
//

import AppKit
import Foundation
import IOKit.pwr_mgt

// 注意签名：这是 out 参数形式并返回 IOReturn，不是直接返回字典。
// 变量名也不要复用 —— 遮蔽同名变量会让 Swift 编译器直接崩溃。
var rawDict: Unmanaged<CFDictionary>?
let result = IOPMCopyAssertionsByProcess(&rawDict)

// Copy 规则：返回的字典是 +1 引用，用 takeRetainedValue 交给 ARC 接管。
guard result == kIOReturnSuccess, let unmanaged = rawDict else {
    print("拿不到断言列表，IOReturn = 0x\(String(result, radix: 16))")
    exit(1)
}
let byProcess = unmanaged.takeRetainedValue() as NSDictionary

print("持有电源断言的进程数: \(byProcess.count)\n")

var total = 0
for (key, value) in byProcess {
    guard let pid = key as? Int, let list = value as? [[String: Any]] else { continue }

    var name = "?"
    if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
        name = app.localizedName ?? app.bundleIdentifier ?? "?"
    }

    print("pid \(pid)  \(name)")
    for assertion in list {
        total += 1
        let type = assertion["AssertType"] as? String ?? "?"
        let assertionName = assertion["AssertName"] as? String ?? ""
        let reason = assertion["HumanReadableReason"] as? String ?? ""
        let level = assertion["AssertLevel"] as? Int ?? -1
        print("    type=\(type)  level=\(level)")
        print("      name:   \(assertionName)")
        if !reason.isEmpty { print("      reason: \(reason)") }
    }
    print("")
}

print("断言条目总数: \(total)")
