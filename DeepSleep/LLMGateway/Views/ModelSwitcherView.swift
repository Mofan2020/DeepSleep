//
//  ModelSwitcherView.swift
//  Deep Sleep
//
//  所有 Provider 的模型清单 + 默认模型选择。
//

import SwiftUI

struct ModelSwitcherView: View {

    @ObservedObject private var controller = GatewayController.shared
    @State private var grouped: [ProviderModels] = []
    @State private var loading: Bool = false
    @State private var savedProvider: String?
    @State private var savedModel: String?

    private static let defaultsKey = "defaultModel.providerId"

    struct ProviderModels: Identifiable {
        let id: UUID
        let provider: ProviderConfig
        let models: [ModelInfo]
        let error: String?
    }

    var body: some View {
        Group {
            if loading && grouped.isEmpty {
                ProgressView("加载模型列表…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.providers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(grouped) { group in
                        Section {
                            if let err = group.error {
                                Text(err)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            } else if group.models.isEmpty {
                                Text("暂无可用模型")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                ForEach(group.models) { model in
                                    ModelRow(
                                        provider: group.provider,
                                        model: model,
                                        isDefault: isDefault(provider: group.provider, model: model.name)
                                    ) {
                                        setDefault(provider: group.provider, model: model.name)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: group.provider.platform.symbolName)
                                Text(group.provider.displayName)
                                Spacer()
                                Text(group.provider.platform.title)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("模型切换")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .task { await loadAll() }
        .refreshable { await loadAll() }
        .alert("已设为默认模型",
               isPresented: Binding(
                get: { savedModel != nil },
                set: { if !$0 { savedModel = nil; savedProvider = nil } }
               )
        ) {
            Button("好") { savedModel = nil; savedProvider = nil }
        } message: {
            if let m = savedModel {
                Text("\(savedProvider ?? "") / \(m)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("还没有任何 Provider。先到「模型」标签页添加一个吧。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadAll() async {
        loading = true
        defer { loading = false }
        var result: [ProviderModels] = []
        for provider in controller.providers where provider.enabled {
            let group = await fetchModels(for: provider)
            result.append(group)
        }
        grouped = result
    }

    private func fetchModels(for provider: ProviderConfig) async -> ProviderModels {
        do {
            let key = try KeychainStore.load(account: provider.apiKeyRef)
            let prov = ProviderRegistry.shared.makeProvider(for: provider, apiKey: key ?? "")
            let models = try await prov.listModels()
            return ProviderModels(id: provider.id, provider: provider, models: models, error: nil)
        } catch {
            return ProviderModels(
                id: provider.id,
                provider: provider,
                models: [],
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Default

    private func currentDefault() -> (UUID, String)? {
        guard
            let pidStr = UserDefaults.standard.string(forKey: Self.defaultsKey),
            let pid = UUID(uuidString: pidStr),
            let model = UserDefaults.standard.string(forKey: "defaultModel.\(pidStr)")
        else { return nil }
        return (pid, model)
    }

    private func isDefault(provider: ProviderConfig, model: String) -> Bool {
        guard let def = currentDefault() else { return false }
        return def.0 == provider.id && def.1 == model
    }

    private func setDefault(provider: ProviderConfig, model: String) {
        UserDefaults.standard.set(provider.id.uuidString, forKey: Self.defaultsKey)
        UserDefaults.standard.set(model, forKey: "defaultModel.\(provider.id.uuidString)")
        savedProvider = provider.displayName
        savedModel = model
        // 触发 grouped 重渲染以更新绿勾。
        Task { await loadAll() }
    }
}

// MARK: - Row

private struct ModelRow: View {
    let provider: ProviderConfig
    let model: ModelInfo
    let isDefault: Bool
    let onSetDefault: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(model.displayName ?? model.name)
                        .font(.body.weight(.medium))
                    if isDefault {
                        Tag(text: "默认", color: .green)
                    }
                }
                Text(model.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if model.supportsVision {
                        Tag(text: "视觉", color: .blue)
                    }
                    if model.supportsTools {
                        Tag(text: "工具", color: .orange)
                    }
                    if let ctx = model.contextWindow {
                        Tag(text: "\(ctx / 1000)K", color: .gray)
                    }
                }
            }
            Spacer()
            Button {
                onSetDefault()
            } label: {
                Text(isDefault ? "当前默认" : "设为默认")
            }
            .buttonStyle(.bordered)
            .disabled(isDefault)
        }
        .padding(.vertical, 4)
    }
}

private extension LLMPlatform {
    var symbolName: String {
        switch self {
        case .anthropicGlobal, .anthropicCN: return "brain"
        case .openai:          return "sparkles"
        case .minimaxGlobal, .minimaxCN:     return "star.circle"
        case .deepseek:        return "magnifyingglass.circle"
        case .zhipu:           return "wand.and.stars"
        case .dashScope:       return "cloud"
        case .moonshot:        return "moon.stars"
        case .doubao:          return "leaf"
        case .qianfan:         return "globe.asia.australia.fill"
        case .gemini:          return "sparkle"
        case .grok:            return "bolt"
        case .mistral:         return "wind"
        case .cohere:          return "circle.hexagongrid"
        case .ollama:          return "server.rack"
        }
    }
}
