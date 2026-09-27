//
//  dump-windows.swift
//  Deep Sleep 诊断工具
//
//  列出屏幕上属于 Deep Sleep 的窗口。用途：验证「窗口是否真的出现」，
//  因为窗口创建发生在 AppKit/SwiftUI 内部，从进程外部观察才算数。
//
//  用法：swift scripts/dump-windows.swift
//

import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

var found = 0
for window in list {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains("Deep Sleep") else { continue }

    found += 1
    let name = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? Double).map { Int($0) } ?? -1
    let height = (bounds["Height"] as? Double).map { Int($0) } ?? -1
    print("窗口 #\(found): 标题=\"\(name)\" layer=\(layer) 尺寸=\(width)x\(height)")
}

if found == 0 {
    print("没找到任何 Deep Sleep 的窗口")
} else {
    print("共 \(found) 个窗口")
}
