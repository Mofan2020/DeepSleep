//
//  DiagnosticsView.swift
//  Deep Sleep
//
//  设备诊断页：跑一次全面体检，按分组展示结论与处理建议。
//
//  界面约定：
//    - 顶部一句话结论 + 严重度配色；有问题的问题排在最前面。
//    - 正常项默认折叠 —— 一屏全是「正常」等于没信息量。
//    - 检测要跑几秒（几十条命令），必须有明确的运行中状态，不能像卡死。
//    - 每条检查项给三样东西：检查项 / 结果 / 说明（怎么办 + 原始细节）。
//
//  数据流：
//    DeviceDiagnostics.collectReport()  →  Shared/DiagnosticModel.swift 判定
//    → DiagnosticReport（分组 + 每项的严重度 / 建议）→ 本页渲染。
//
//  只读诊断：不改任何系统设置，不请求管理员权限.
//

import SwiftUI
// NSPasteboard 在 AppKit 里。SwiftUI 不保证把它带进来，显式导入。
import AppKit

struct DiagnosticsView: View {

    /// 上一次的报告存在 UserDefaults 里：工具箱的页面是靠切 selection 进入的，
    /// 切走再切回来整个 View 会重建，不存的话每次都要重跑几秒。
    private static let storageKey = "diagnostics.lastReport.v1"

    @State private var report: DiagnosticReport?
    @State private var isRunning = false
    @State private var showHealthyItems = false
    @State private var copiedAt: Date?
    @State private var lastError: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            headerCard

            if isRunning {
                runningCard
            }

            if let report {
                ForEach(report.sections) { section in
                    sectionCard(section)
                }
            }

            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.Tone.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .pageLayout()
        .task {
            // 先把手上的旧报告放出来，再决定要不要重跑。
            if report == nil { report = loadArchivedReport() }
            if report == nil { await runDiagnostics() }
        }
    }

    // MARK: - 顶部结论

    private var headerCard: some View {
        SectionCard(
            title: "设备诊断",
            subtitle: headerSubtitle,
            symbol: "stethoscope",
            accent: headlineColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if let report {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: headlineSymbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(headlineColor)
                        Text(report.headline)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(headlineColor)
                        Spacer(minLength: DS.Space.sm)
                        if report.problemCount > 0 {
                            Tag(text: "严重 \(report.criticalCount)", color: DS.Tone.critical)
                            Tag(text: "注意 \(report.warningCount)", color: DS.Tone.caution)
                        } else {
                            Tag(text: "全部正常", color: DS.Tone.good)
                        }
                    }

                    Text(report.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label("重新检测", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.regular)
                        .disabled(isRunning)

                        Button {
                            copyReport()
                        } label: {
                            Label(copiedAt == nil ? "复制报告全文" : "已复制", systemImage: "doc.on.doc")
                        }
                        .controlSize(.regular)
                        .disabled(isRunning)

                        Spacer(minLength: DS.Space.sm)

                        Toggle("显示正常项", isOn: $showHealthyItems)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                } else if !isRunning {
                    EmptyStateView(
                        title: "还没有检测结果",
                        message: "跑一次只读体检，看看硬件、系统、能耗与配置有没有问题。",
                        systemImage: "stethoscope",
                        actionTitle: "开始检测",
                        action: { Task { await runDiagnostics() } }
                    )
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isRunning { return "正在采集本机状态，请稍候……" }
        guard let report else { return "只读检查硬件、系统、能耗与配置，不会改动任何设置。" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "检测完成于 \(f.string(from: report.generatedAt)) · 共 \(report.allItems.count) 项检查 · 只读，不会改动任何设置。"
    }

    private var headlineColor: Color {
        guard let report else { return .accentColor }
        if report.criticalCount > 0 { return DS.Tone.critical }
        if report.warningCount > 0 { return DS.Tone.caution }
        return DS.Tone.good
    }

    private var headlineSymbol: String {
        guard let report else { return "stethoscope" }
        if report.criticalCount > 0 { return "xmark.octagon.fill" }
        if report.warningCount > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    // MARK: - 运行中

    private var runningCard: some View {
        SectionCard(
            title: "检测中",
            subtitle: "正在读取硬件、系统、能耗与安全配置状态……",
            symbol: "hourglass",
            accent: .accentColor
        ) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ProgressView()
                    .controlSize(.small)
                Text("要跑几十条系统命令，通常几秒钟。温度与进程列表需要特权助手配合，助手不可用时会标成「无法读取」；个别项目需要管理员权限，这类会写成「无法读取」而不是故障。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 分组

    private func sectionCard(_ section: DiagnosticSection) -> some View {
        let problems = section.problems
        let normal = section.normalItems

        return SectionCard(
            title: section.title,
            subtitle: sectionSubtitle(problems: problems.count, normal: normal.count),
            symbol: section.icon,
            accent: sectionAccent(problems)
        ) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if problems.isEmpty && normal.isEmpty {
                    Text("这一组没有采集到任何内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(problems) { item in
                    DiagnosticItemRow(item: item)
                }

                if !normal.isEmpty {
                    if showHealthyItems {
                        Divider()
                        SubsectionHeader(title: "正常项", symbol: "checkmark.circle")
                        ForEach(normal) { item in
                            DiagnosticItemRow(item: item)
                        }
                    } else {
                        Button {
                            withAnimation(reduceMotion ? nil : DS.Animation.quick) {
                                showHealthyItems = true
                            }
                        } label: {
                            Label("展开 \(normal.count) 项正常检查", systemImage: "chevron.down")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sectionSubtitle(problems: Int, normal: Int) -> String {
        if problems == 0 {
            return "\(normal) 项检查全部正常。"
        }
        return "\(problems) 项需要处理 · \(normal) 项正常"
    }

    private func sectionAccent(_ problems: [DiagnosticItem]) -> Color {
        if problems.contains(where: { $0.severity == .critical }) { return DS.Tone.critical }
        if problems.contains(where: { $0.severity == .warning }) { return DS.Tone.caution }
        return DS.Tone.good
    }

    // MARK: - 动作

    private func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        copiedAt = nil
        defer { isRunning = false }
        // `collectReport()` 不抛错 —— 采集失败时它自己降级（拿不到的项标成
        // 不可用）。所以这里没有 do/catch：写了反而是编译器警告里的
        // 「catch 块永远不会执行」。
        let result = await DeviceDiagnostics.collectReport()
        report = result
        saveArchivedReport(result)
    }

    /// 读上次的报告。存档损坏或格式对不上时返回 nil —— 直接重跑一次，
    /// 不要让一份读不出来的旧存档把界面卡在错误状态。
    private func loadArchivedReport() -> DiagnosticReport? {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return nil }
        return DiagnosticReportArchive.decode(data)
    }

    private func saveArchivedReport(_ report: DiagnosticReport) {
        guard let data = DiagnosticReportArchive.encode(report) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func copyReport() {
        guard let report else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.plainText, forType: .string)
        copiedAt = Date()
        // 2 秒后把「已复制」变回「复制报告全文」。
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedAt != nil { copiedAt = nil }
        }
    }
}

// MARK: - 单条检查项

/// 一条检查项：检查项 + 结果 + 说明（怎么处理 / 原始细节）。
///
/// 正常项用次要色弱化，问题项用严重度色突出 —— 一屏里「正常」不该跟
/// 「需要处理」抢注意力。严重度同时写成文字（正常 / 注意 / 严重），
/// 不能只靠颜色区分。
private struct DiagnosticItemRow: View {

    let item: DiagnosticItem

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: item.severity.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.severity == .info ? Color.secondary : Color.primary)
                Spacer(minLength: DS.Space.sm)
                Text(item.severity.label)
                    .font(.caption2)
                    .foregroundStyle(accent)
                Text(item.value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(item.severity == .info ? Color.secondary : accent)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let suggestion = item.suggestion, !suggestion.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.8))
                        .padding(.top, DS.Space.xxs)
                    Text(suggestion)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, DS.Space.xl)
            }

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.Space.xl)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetPanel()
    }

    private var accent: Color {
        switch item.severity {
        case .info:     return DS.Tone.idle
        case .warning:  return DS.Tone.caution
        case .critical: return DS.Tone.critical
        }
    }
}
