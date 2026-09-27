//
//  Version.swift
//  Deep Sleep
//
//  版本号的解析与比较。
//
//  为什么值得单独写一个文件而不是直接比字符串：`"1.10.0" < "1.9.0"` 在字符串
//  比较下是 **true** —— 必须按数字段逐段比较才是对的。这类错误在自动更新里
//  代价很高：方向比错就会「有新版本却认为没有」，或者更糟 ——
//  「认为有更新但装不上」，于是每次启动都重新下载安装，永远停不下来。
//
//  另一个同等重要的约定：**解析失败时返回 nil，调用方必须把它当作
//  「无法判断」而不是「有更新」**。宁可漏掉一次更新，也不能陷入更新循环。
//

import Foundation

public enum SemanticVersion {

    /// 解析 `v1.2.3` / `1.2.3` / `1.2.3-beta.1` 这类字符串，得到数字段。
    /// 无法解析时返回 nil。
    public static func parse(_ text: String) -> [Int]? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // 丢掉预发布与构建元数据（`-beta.1` / `+build7`），只比数字段。
        if let cut = trimmed.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            trimmed = String(trimmed[trimmed.startIndex..<cut])
        }
        guard !trimmed.isEmpty else { return nil }

        var numbers: [Int] = []
        for field in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            // 空段与非法字符一律判为无法解析（`1..2`、`1.x`、`1.` 都算）。
            guard !field.isEmpty, let value = Int(field), value >= 0 else { return nil }
            numbers.append(value)
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// 比较两个版本，返回 -1 / 0 / 1。任一方无法解析时返回 nil。
    ///
    /// 段数不同时按零补齐：`1.1` 与 `1.1.0` 视为相等，
    /// 这样 release tag 写成 `v1.1` 或 `v1.1.0` 都不影响判断。
    public static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// 是否应该用 `candidate` 替换 `current`。
    ///
    /// 只有**严格更新**才返回 true：
    ///   - 相等不更新 —— 重复安装没有意义，而且一旦把「相等」也当作需要更新，
    ///     就会每次启动都重装一遍，永远停不下来；
    ///   - 更旧不更新 —— 防止把用户降级回去，那同样会形成循环；
    ///   - 任一方解析不了也不更新 —— 判断不了就不要动。
    public static func isUpgrade(from current: String, to candidate: String) -> Bool {
        guard let result = compare(candidate, current) else { return false }
        return result > 0
    }
}
