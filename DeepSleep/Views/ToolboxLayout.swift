//
//  ToolboxLayout.swift
//  Deep Sleep
//
//  工具箱的排序状态：置顶组 + 未置顶组，以及它的持久化。
//
//  这个文件**不 import SwiftUI** —— 纯数据 + 纯规则。
// 这么做是为了让 scripts/test-toolbox-layout.swift 能直接编译**真实源码**
// 来测这套规则，而不是抄一份副本（副本会漂移）。
// 界面上用到的东西（SF Symbol、badge、对应哪个 SidebarItem）都在
// ToolboxView.swift 里，用 extension 补上。
//

import Foundation

// MARK: - 工具 ID

/// 工具箱里的一个工具。
///
/// rawValue 是持久化用的 ID（存进 `toolbox.layout.v1`），不要随便改。
/// 声明顺序 = canonical 顺序 = 「重置排序」的还原目标。
enum ToolboxTool: String, CaseIterable, Identifiable, Hashable {
    case nice
    case hosts
    case quarantine
    case aiKeepAlive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nice:           return "进程优先级"
        case .hosts:          return "Hosts 编辑"
        case .quarantine:     return "Quarantine"
        case .aiKeepAlive:    return "AI 保活"
        }
    }

    /// 副标题。最多两行（卡片高度固定两行，见 ToolCard）。
    var desc: String {
        switch self {
        case .nice:           return "查看并调整任意用户进程的优先级（nice）。"
        case .hosts:          return "读写 /etc/hosts，并管理「谁能改 hosts」白名单。"
        case .quarantine:     return "扫描并清除 macOS 的 quarantine 扩展属性。"
        case .aiKeepAlive:    return "按计划给指定接口发一次请求，避免会话闲置失效。"
        }
    }

    /// SF Symbol。都是 macOS 26 实测存在的名字。
    var symbol: String {
        switch self {
        case .nice:           return "gauge.with.dots.needle.bottom.50percent"
        case .hosts:          return "doc.text.fill"
        case .quarantine:     return "lock.shield.fill"
        case .aiKeepAlive:    return "bolt.heart.fill"
        }
    }
}

// MARK: - 布局与置顶

/// 工具箱的排序状态：置顶组 + 未置顶组。
///
/// 规则：
///  - 置顶：从 rest 移除 → 追加到 pinned 末尾；
///  - 取消置顶：从 pinned 移除 → 追加到 rest 末尾；
///  - 显示顺序 = pinned ++ rest（组内按操作顺序）；
///  - 读入时丢掉不认识的 ID，缺失的 ID 按 canonical 顺序补到 rest 末尾。
struct ToolboxLayout: Codable, Equatable {

    /// 置顶的工具 ID。
    var pinned: [String]
    /// 未置顶的工具 ID。
    var rest: [String]

    /// 归一化构造：去重、丢弃未知 ID、补齐缺失 ID。
    init(pinned: [String], rest: [String]) {
        var seen = Set<String>()
        var normalizedPinned: [String] = []
        for id in pinned where ToolboxTool(rawValue: id) != nil && !seen.contains(id) {
            seen.insert(id)
            normalizedPinned.append(id)
        }
        var normalizedRest: [String] = []
        for id in rest where ToolboxTool(rawValue: id) != nil && !seen.contains(id) {
            seen.insert(id)
            normalizedRest.append(id)
        }
        // 存储里缺的工具（新加的工具）按 canonical 顺序补到未置顶组末尾。
        for tool in ToolboxTool.allCases where !seen.contains(tool.rawValue) {
            seen.insert(tool.rawValue)
            normalizedRest.append(tool.rawValue)
        }
        self.pinned = normalizedPinned
        self.rest = normalizedRest
    }

    /// 默认布局：无置顶，canonical 顺序。
    static let `default` = ToolboxLayout(
        pinned: [],
        rest: ToolboxTool.allCases.map(\.rawValue)
    )

    /// 是否已经是默认布局（「重置排序」按钮据此置灰）。
    var isDefault: Bool { self == ToolboxLayout.default }

    /// 显示顺序。
    var orderedTools: [ToolboxTool] {
        (pinned + rest).compactMap { ToolboxTool(rawValue: $0) }
    }

    func isPinned(_ tool: ToolboxTool) -> Bool {
        pinned.contains(tool.rawValue)
    }

    /// 切换置顶状态，返回新的布局。
    func togglingPin(_ tool: ToolboxTool) -> ToolboxLayout {
        let id = tool.rawValue
        if pinned.contains(id) {
            var newPinned = pinned
            newPinned.removeAll { $0 == id }
            var newRest = rest
            newRest.removeAll { $0 == id }
            newRest.append(id)
            return ToolboxLayout(pinned: newPinned, rest: newRest)
        }
        var newPinned = pinned
        newPinned.append(id)
        var newRest = rest
        newRest.removeAll { $0 == id }
        return ToolboxLayout(pinned: newPinned, rest: newRest)
    }

    // MARK: - Codable

    /// 自定义解码：**解码后必须过一遍归一化**。
    ///
    /// 合成的 `init(from:)` 不会调用 `init(pinned:rest:)` —— 它直接把
    /// 磁盘上的两个数组塞进成员。存储被手改过（未知 ID、重复 ID）、
    /// 或者版本升级后新增了工具，解出来的就是脏数据。
    ///
    /// 这条路径不能只靠 `ToolboxStore.load()` 里显式重建来兜底 ——
    /// 那是「调用方恰好记得重建」，不是「类型本身自洽」。
    /// 任何人对 ToolboxLayout 解码都该拿到归一化后的结果。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pinned = try container.decode([String].self, forKey: .pinned)
        let rest = try container.decode([String].self, forKey: .rest)
        self.init(pinned: pinned, rest: rest)
    }
}

// MARK: - 持久化

/// 工具箱布局的持久化：UserDefaults 存 JSON Data。
///
/// 做法与 `appRestartTargets.v1` / `weeklyRestartConfig.v1` 同一路子。
enum ToolboxStore {

    /// UserDefaults key。带 `.v1` 后缀是为了以后改结构时可以并存两版。
    static let storageKey = "toolbox.layout.v1"

    static func load() -> ToolboxLayout {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ToolboxLayout.self, from: data) else {
            return .default
        }
        // 解码出来的内容要重新过一遍归一化：手改过、或新增过工具。
        return ToolboxLayout(pinned: decoded.pinned, rest: decoded.rest)
    }

    static func save(_ layout: ToolboxLayout) {
        guard let data = encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 编码器。**必须用 `.sortedKeys`**。
    ///
    /// `JSONEncoder` 对 struct 的键序不固定 —— 同一个值多次编码能产出
    /// 好几种字节。键序不定的话，每次置顶操作写进 UserDefaults 的
    /// 字节都不同，内容却等价，白白多占磁盘也没法 diff。
    private static func encode(_ layout: ToolboxLayout) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(layout)
    }
}
