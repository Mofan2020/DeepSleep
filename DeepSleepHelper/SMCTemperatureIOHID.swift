//
//  SMCTemperatureIOHID.swift
//  deepsleep-helper
//
//  IOHID 私有事件通道读温度（Apple Silicon 上唯一能拿到真实 CPU / GPU / PMU 读数的路）。
//
//  ============================================================================
//  为什么需要这条通道
//  ============================================================================
//  Apple Silicon 上传统 SMC 温度键（TC0P / TC0C / TC0D …）全部不存在
//  （实测 0x84 = key not found），温度只能从 IOHID 的 vendor-defined 事件里拿。
//  实测参数（docs/SMC.md §3.4）：
//
//    IOHIDEventSystemClientCreate(NULL)
//      → SetMatching({ "PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5 })
//      → CopyServices()                       → 传感器服务集合
//      → 每个 service: CopyProperty(service, "Product") 取名字
//      → CopyEvent(service, 15, 0, 0)          // 15 = kIOHIDEventTypeTemperature
//      → IOHIDEventGetFloatValue(event, 0xF0000) // = kIOHIDEventFieldTemperatureLevel
//
//  ============================================================================
//  两个必须踩准的点（都是实测踩出来的）
//  ============================================================================
//  1. `IOHIDEventGetFloatValue` 返回 **double**，不是 float。
//     按 float 读会得到全部 0.0 —— arm64 的返回值在浮点寄存器里按 double 布局，
//     低 32 位是 0，看起来像「传感器没数据」，实际是类型错了。
//     上一版 CPU 温度一直读不到就是栽在这里。
//  2. 这些符号**不在公开 SDK 头文件里**（`IOHIDEventSystemClientCreate` 只在私有
//     头里，`IOHIDServiceClientCopyEvent` / `IOHIDEventGetFloatValue` 连私有头都没
//     导出到 SDK）。所以用 dlsym 取：编译期不依赖私有符号存在，运行时取不到就
//     优雅降级成「温度不可用」，而不是链接失败导致整个助手起不来。
//
//  ============================================================================
//  权限
//  ============================================================================
//  这条通道**普通用户进程就能读**（实测 euid=501 直连成功，38 个传感器全部有读数）。
//  所以它不是助手的特权能力 —— 放在这里是因为助手要独立执行 90°C 硬兜底，
//  不能指望应用还活着。
//

import Foundation
import CoreFoundation
import IOKit
import Darwin

/// IOHID 温度读取。
///
/// 一次性连接、读完即关：与 `SMCTemperature` 的策略一致 ——
/// 助手重启成本远低于长期持有 HID 客户端，也避免事件系统侧状态漂移。
final class SMCTemperatureIOHID {

    // MARK: - 错误

    enum TemperatureError: Error, CustomStringConvertible {
        /// 私有符号取不到：这台机器 / 这个系统版本不支持这条通道。
        case symbolsUnavailable(String)
        /// 通道打开了，但一个传感器的读数都没有。
        case noReadings

        var description: String {
            switch self {
            case .symbolsUnavailable(let detail):
                return "IOHID 温度通道不可用：\(detail)"
            case .noReadings:
                return "IOHID 温度通道没有任何读数（传感器集合为空或全部无效）"
            }
        }
    }

    // MARK: - 实测常量（SDK 里没有，来自 docs/SMC.md §3.4）

    /// 传感器匹配页：kHIDPage_VendorDefined。
    private static let usagePage: Int32 = 0xFF00
    /// 传感器匹配用途：Apple 暴露 SMC 温度传感器的那个 usage。
    private static let usage: Int32 = 5
    /// kIOHIDEventTypeTemperature。
    private static let eventTypeTemperature: UInt32 = 15
    /// kIOHIDEventFieldTemperatureLevel（983040）。
    private static let fieldTemperatureLevel: UInt32 = 0xF0000

    // MARK: - 私有符号（dlsym）

    // IOHIDEventSystemClientRef / IOHIDServiceClientRef / IOHIDEventRef 都是
    // CF_BRIDGED_TYPE(id) 的不透明指针，SDK 里没有公开定义，这里一律用
    // Unmanaged<CFTypeRef> / UnsafeRawPointer 承载，由我们自己管引用计数。

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (UnsafeRawPointer?, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (UnsafeRawPointer?) -> Unmanaged<CFTypeRef>?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, CFIndex) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (UnsafeRawPointer?, UInt32) -> Double

    /// 一组取到的符号。取不全就整条通道算不可用。
    private struct Symbols {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloatValue: GetFloatValueFn
    }

    /// IOKit 句柄。只 dlopen 一次，进程生命周期内复用。
    private static let iokitHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    }()

    /// 取符号。`RTLD_DEFAULT` 兜底：IOKit 已经作为 framework 链接进来时，
    /// 不 dlopen 也能找到。
    private static func loadSymbols() throws -> Symbols {
        func lookup(_ name: String) -> UnsafeMutableRawPointer? {
            if let handle = iokitHandle, let symbol = dlsym(handle, name) {
                return symbol
            }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
        }

        let required = [
            "IOHIDEventSystemClientCreate",
            "IOHIDEventSystemClientSetMatching",
            "IOHIDEventSystemClientCopyServices",
            "IOHIDServiceClientCopyProperty",
            "IOHIDServiceClientCopyEvent",
            "IOHIDEventGetFloatValue",
        ]
        let missing = required.filter { lookup($0) == nil }
        guard missing.isEmpty else {
            throw TemperatureError.symbolsUnavailable(
                "缺少符号 \(missing.joined(separator: ", "))（系统版本可能不支持这条通道）")
        }

        // 上面已经逐个确认非 nil。
        func cast<T>(_ name: String, to type: T.Type) -> T {
            unsafeBitCast(lookup(name)!, to: T.self)
        }

        return Symbols(
            create: cast("IOHIDEventSystemClientCreate", to: CreateFn.self),
            setMatching: cast("IOHIDEventSystemClientSetMatching", to: SetMatchingFn.self),
            copyServices: cast("IOHIDEventSystemClientCopyServices", to: CopyServicesFn.self),
            copyProperty: cast("IOHIDServiceClientCopyProperty", to: CopyPropertyFn.self),
            copyEvent: cast("IOHIDServiceClientCopyEvent", to: CopyEventFn.self),
            getFloatValue: cast("IOHIDEventGetFloatValue", to: GetFloatValueFn.self))
    }

    // MARK: - 对外 API

    /// 读一次全部温度传感器。
    ///
    /// - 通道取不到 / 一个读数都没有 → 抛错。**不返回「全 0」的快照**：
    ///   应用侧据「抛错 / readings 为空」区分「没数据」，不需要也不应该靠 0 来判断。
    /// - 读数 `<= 0` 的传感器会被丢弃（这类读数在 Apple Silicon 上表示
    ///   「这个传感器没被填充」，不是真实温度；参照 Macs Fan Control 的同一处理）。
    func readSnapshot() throws -> TemperatureSnapshot {
        let symbols = try Self.loadSymbols()

        guard let clientBox = symbols.create(nil) else {
            throw TemperatureError.symbolsUnavailable("IOHIDEventSystemClientCreate 返回 nil")
        }
        // CF 对象在 Swift 里由 ARC 管（`takeRetainedValue()` 接手 +1 引用），
        // 不需要也不能手动 CFRelease —— 编译器会直接报 CFRelease unavailable。
        let client = clientBox.takeRetainedValue()
        let clientRef = Unmanaged.passUnretained(client).toOpaque()

        // 匹配 { PrimaryUsagePage: 0xFF00, PrimaryUsage: 5 }
        // 用 Swift 字典桥接：Int 会自动变成 CFNumber，省掉手写 CFNumberCreate。
        let matching = [
            "PrimaryUsagePage": Int(Self.usagePage),
            "PrimaryUsage": Int(Self.usage)
        ] as CFDictionary

        symbols.setMatching(clientRef, matching)

        guard let servicesBox = symbols.copyServices(clientRef) else {
            throw TemperatureError.noReadings
        }
        let services = servicesBox.takeRetainedValue()

        // 实测本机返回 CFArray（typeID 19）；旧文档写的是 CFSet。
        // 两种都吃，避免换系统版本就整条通道哑掉。
        let servicePointers = Self.pointers(in: services)

        var readings: [TemperatureSnapshot.Reading] = []
        readings.reserveCapacity(servicePointers.count)

        for service in servicePointers {
            guard let name = Self.productName(of: service, using: symbols) else { continue }
            guard let celsius = Self.temperature(of: service, using: symbols) else { continue }
            guard celsius.isFinite, celsius > 0 else { continue }
            readings.append(TemperatureSnapshot.Reading(sensorID: name, celsius: celsius))
        }

        guard !readings.isEmpty else { throw TemperatureError.noReadings }
        return TemperatureSnapshot(readings: readings)
    }

    /// 只取最高温。90°C 兜底用这个，省掉调用方自己遍历。
    func maxCelsius() throws -> Double {
        guard let value = try readSnapshot().maxCelsius else {
            throw TemperatureError.noReadings
        }
        return value
    }

    // MARK: - CF 辅助

    /// 把 CopyServices 的结果摊成一组 service 指针。
    private static func pointers(in collection: CFTypeRef) -> [UnsafeRawPointer] {
        let typeID = CFGetTypeID(collection)

        if typeID == CFArrayGetTypeID() {
            let array = unsafeBitCast(collection, to: CFArray.self)
            let count = CFArrayGetCount(array)
            guard count > 0 else { return [] }
            var buffer = [UnsafeRawPointer?](repeating: nil, count: count)
            CFArrayGetValues(array, CFRangeMake(0, count), &buffer)
            return buffer.compactMap { $0 }
        }

        if typeID == CFSetGetTypeID() {
            let set = unsafeBitCast(collection, to: CFSet.self)
            let count = CFSetGetCount(set)
            guard count > 0 else { return [] }
            var buffer = [UnsafeRawPointer?](repeating: nil, count: count)
            CFSetGetValues(set, &buffer)
            return buffer.compactMap { $0 }
        }

        return []
    }

    /// 读 service 的 "Product" 属性（传感器名，例："PMU tdie1"）。
    private static func productName(of service: UnsafeRawPointer, using symbols: Symbols) -> String? {
        guard let propertyBox = symbols.copyProperty(service, "Product" as CFString) else {
            return nil
        }
        let property = propertyBox.takeRetainedValue()

        guard CFGetTypeID(property) == CFStringGetTypeID() else { return nil }
        let string = unsafeBitCast(property, to: CFString.self)

        var buffer = [CChar](repeating: 0, count: 256)
        guard CFStringGetCString(string, &buffer, 256, CFStringBuiltInEncodings.UTF8.rawValue) else {
            return nil
        }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 读单个传感器的温度（°C）。
    private static func temperature(of service: UnsafeRawPointer, using symbols: Symbols) -> Double? {
        guard let eventBox = symbols.copyEvent(
            service, eventTypeTemperature, 0, 0) else { return nil }
        let event = eventBox.takeRetainedValue()

        // 关键：返回值是 double。签名里写 Float 会拿到 0.0。
        return symbols.getFloatValue(Unmanaged.passUnretained(event).toOpaque(),
                                     fieldTemperatureLevel)
    }
}
