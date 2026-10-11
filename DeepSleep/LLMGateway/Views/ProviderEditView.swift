//
//
//  ProviderEditView.swift
//  Deep Sleep
//
//  新建 / 编辑 Provider：表单 + 保存到 Keychain + GatewayDatabase。
//

import SwiftUI

struct ProviderEditView: View {

    /// 传入 nil 表示新建。
    let providerId: UUID?

    @ObservedObject private var controller = GatewayController.shared
    @Environment(\.dismiss) private var dismiss

    @State private var platform: LLMPlatform = .anthropicGlobal
    @State private var displayName: String = ""
    @State private var billingMode: BillingMode = .payAsYouGo
    @State private var apiKey: String = ""
    @State private var notes: String = ""
    @State private var revealKey: Bool = false
    @State private var saveError: String?
    @State private var isSaving: Bool = false

    @State private var testInFlight: Bool = false
    @State private var testResult: TestResult?

    struct TestResult: Identifiable {
        let id = UUID()
        let ok: Bool
        let summary: String
    }

    private var isEdit: Bool { providerId != nil }

    private var existing: ProviderConfig? {
        guard let id = providerId else { return nil }
        return controller.providers.first { $0.id == id }
    }

    var body: some View {
        Form {
            Section("基础") {
                Picker("平台", selection: $platform) {
                    ForEach(LLMPlatform.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                }
                .onChange(of: platform) { _ in
                    if !platform.needsBillingMode {
                        billingMode = .unlimited
                    } else if billingMode == .unlimited {
                        billingMode = .payAsYouGo
                    }
                    if displayName.isEmpty {
                        displayName = defaultDisplayName()
                    }
                }

                TextField("显示名称", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            if platform.needsBillingMode {
                Section("计费") {
                    Picker("计费模式", selection: $billingMode) {
                        ForEach(applicableBillingModes, id: \.self) { m in
                            Text(billingTitle(m)).tag(m)
                        }
                    }
                }
            }

            if platform.needsAPIKey {
                Section("API Key") {
                    HStack {
                        Group {
                            if revealKey {
                                TextField("sk-...", text: $apiKey)
                            } else {
                                SecureField("sk-...", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealKey ? "隐藏" : "显示")
                    }
                    if isEdit {
                        Text("留空表示不修改原 Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("备注") {
                TextField("可选", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }

            if let testResult {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? .green : .red)
                        Text(testResult.summary)
                            .font(.callout)
                    }
                } header: {
                    Text("测试连接结果")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isEdit ? "编辑 Provider" : "添加 Provider")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                if isEdit {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(testInFlight)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("保存")
                    }
                }
                .disabled(!canSave || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { hydrate() }
        .alert("保存失败",
               isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
               )
        ) {
            Button("好") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Derived state

    private var applicableBillingModes: [BillingMode] {
        switch platform {
        case .anthropicGlobal, .anthropicCN, .openai,
             .minimaxGlobal, .minimaxCN, .moonshot, .gemini:
            return [.payAsYouGo, .subscription, .codingPlan]
        default:
            return [.payAsYouGo, .unlimited]
        }
    }

    private var canSave: Bool {
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if platform.needsAPIKey && !isEdit && apiKey.isEmpty { return false }
        return true
    }

    private func billingTitle(_ mode: BillingMode) -> String {
        switch mode {
        case .payAsYouGo:   return "按量付费"
        case .subscription: return "订阅"
        case .codingPlan:   return "Coding Plan"
        case .unlimited:    return "无限"
        }
    }

    private func defaultDisplayName() -> String {
        platform.title
    }

    // MARK: - Lifecycle

    private func hydrate() {
        guard let cfg = existing else {
            if displayName.isEmpty { displayName = defaultDisplayName() }
            return
        }
        platform = cfg.platform
        displayName = cfg.displayName
        billingMode = cfg.billingMode
        notes = cfg.notes ?? ""
    }

    // MARK: - Actions

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let notesValue = trimmedNotes.isEmpty ? nil : trimmedNotes
            let keyAlias = displayName.trimmingCharacters(in: .whitespaces)

            if let cfg = existing {
                var updated = cfg
                updated.platform = platform
                updated.displayName = keyAlias
                updated.billingMode = billingMode
                updated.notes = notesValue
                try await controller.updateProvider(updated)
                if platform.needsAPIKey && !apiKey.isEmpty {
                    try KeychainStore.save(key: apiKey, account: keyAlias)
                }
            } else {
                if platform.needsAPIKey {
                    try KeychainStore.save(key: apiKey, account: keyAlias)
                }
                let cfg = ProviderConfig(
                    platform: platform,
                    displayName: keyAlias,
                    billingMode: billingMode,
                    apiKeyRef: platform.needsAPIKey ? keyAlias : "none",
                    enabled: true,
                    notes: notesValue
                )
                try await controller.addProvider(cfg)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func runTest() async {
        guard let cfg = existing else { return }
        testInFlight = true
        defer { testInFlight = false }
        do {
            let snapshot = try await controller.refreshQuota(providerId: cfg.id)
            let summary: String
            if let amount = snapshot.balanceAmount {
                summary = "余额 \(amount) \(snapshot.balanceCurrency ?? "")"
            } else if let five = snapshot.fiveHourUsed, let total = snapshot.fiveHourTotal {
                summary = "5h 已用 \(Int(five))/\(Int(total))"
            } else {
                summary = "连接成功"
            }
            testResult = TestResult(ok: true, summary: summary)
        } catch {
            testResult = TestResult(ok: false, summary: error.localizedDescription)
        }
    }
}
