//
//  GlobalHotkey.swift
//  Deep Sleep
//
//  全局快捷键（快速退出的触发方式）。
//
//  为什么用 Carbon 的 RegisterEventHotKey，而不是现代 API：
//    - `NSEvent.addGlobalMonitorForEvents` 需要「输入监控」权限，
//      装上之后还得让用户去系统设置里手动勾选，与「按下即杀」相冲突。
//    - Carbon 的热键注册不需要任何 TCC 授权，注册即刻生效。
//      API 虽然是 Carbon 时代的，但它是目前唯一无权限要求的系统级热键方案。
//  宿主的限制：热键活在 Deep Sleep 进程里，所以应用没在运行时快捷键不生效
//  （菜单栏常驻正是为了保证它在跑）。
//

import AppKit
import Carbon.HIToolbox

// MARK: - 组合键

/// 一个快捷键组合。可直接序列化到 UserDefaults。
struct HotkeyCombo: Codable, Equatable {
    /// 虚拟键码（`kVK_*`）。
    var keyCode: UInt32
    /// Carbon 的修饰键掩码（`cmdKey` / `optionKey` / `shiftKey` / `controlKey`）。
    var modifiers: UInt32

    /// 默认组合：⌘⌥⇧H。
    /// 不用 ⌃⌥⌘Q 之类的四修饰键：三修饰键已经足够不可能被误触。
    static let `default` = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_H),
        modifiers: UInt32(cmdKey | optionKey | shiftKey)
    )

    /// 没有任何修饰键的组合不注册 —— 那会吃掉用户正常打字的按键。
    var isValid: Bool { modifiers != 0 && keyCode != 0 }

    /// 修饰键的显示顺序按 macOS 惯例：⌃⌥⇧⌘。
    var modifierSymbols: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    var keyLabel: String { Self.keyLabel(forKeyCode: keyCode) }

    var displayText: String { modifierSymbols + keyLabel }

    /// 从一次真实按键事件生成组合。没有修饰键时返回 nil。
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: 键名

    /// 按键的显示名。
    /// 先用特殊键表，再用当前键盘布局翻译 —— 写死一张 A-Z 表在
    /// 非 US 布局上会显示错误的键名。
    static func keyLabel(forKeyCode keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:        return "空格"
        case kVK_Return:       return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab:          return "⇥"
        case kVK_Escape:       return "⎋"
        case kVK_Delete:       return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_Home:         return "↖"
        case kVK_End:          return "↘"
        case kVK_PageUp:       return "⇞"
        case kVK_PageDown:     return "⇟"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return "F\(Int(keyCode) - kVK_F1 + 1)"
        default:
            break
        }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "键码 \(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return "键码 \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

// MARK: - 注册

/// 全局热键的注册与回调。
///
/// 非 `@MainActor` 是刻意的：Carbon 的事件回调是 C 函数指针，无法携带
/// actor 隔离。隔离边界由实现内部保证 —— `onTrigger` 一律在主线程序上调用。
final class GlobalHotkey: @unchecked Sendable {

    static let shared = GlobalHotkey()

    /// 本应用的热键签名（'DSLP'）。回调时据此确认事件是自己的。
    static let signature: OSType = 0x44534C50

    /// 触发回调。**总是在主线程调用。**
    var onTrigger: (() -> Void)?

    private(set) var combo: HotkeyCombo?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// 注册组合键。
    /// - Returns: 失败原因；成功返回 nil。
    @discardableResult
    func register(_ combo: HotkeyCombo) -> String? {
        unregister()
        guard combo.isValid else {
            return "快捷键至少要有一个修饰键（⌘⌥⌃⇧ 之一）"
        }

        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                deepSleepHotkeyCallback,
                1,
                &eventType,
                nil,
                &handlerRef
            )
            guard status == noErr else {
                return "安装键盘事件处理器失败（OSStatus \(status)）"
            }
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        if status == eventHotKeyExistsErr {
            return "\(combo.displayText) 已被其他应用占用，请换一个组合"
        }
        guard status == noErr, let reference else {
            return "注册 \(combo.displayText) 失败（OSStatus \(status)）"
        }

        hotKeyRef = reference
        self.combo = combo
        return nil
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        self.combo = nil
    }

    /// 当前是否注册成功。
    var isRegistered: Bool { hotKeyRef != nil }
}

/// Carbon 的事件回调。必须是 C 函数指针，所以不能捕获任何上下文。
private let deepSleepHotkeyCallback: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == GlobalHotkey.signature else {
        return OSStatus(eventNotHandledErr)
    }

    // 回调本身已经在主线程（Carbon 应用事件目标跑在主 run loop 上），
    // 但仍显式抛回主队列：这样「onTrigger 在主线程」是一条不依赖
    // Carbon 实现细节的保证。
    DispatchQueue.main.async {
        GlobalHotkey.shared.onTrigger?()
    }
    return noErr
}
