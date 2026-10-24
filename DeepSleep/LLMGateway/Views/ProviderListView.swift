//
//  ProviderListView.swift
//  Deep Sleep
//
//  Provider 列表：增删改入口。
//

import SwiftUI

struct ProviderListView: View {

    @ObservedObject private var controller = GatewayController.shared
    @State private var addingNew = false
    @State private var pendingDelete: ProviderConfig?
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            if controller.providers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(controller.providers) { provider in
                        NavigationLink {
                            ProviderEditView(providerId: provider.id)
                        } label: {
                            ProviderRow(provider: provider) {
                                Task { await toggle(provider) }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = provider
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = provider
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("模型 Provider")
        .task { await controller.ensureLoaded() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingNew = true
                } label: {
                    Label("添加 Provider", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $addingNew) {
            NavigationStack {
                ProviderEditView(providerId: nil)
            }
        }
        .alert("删除 Provider？",
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete
        ) { provider in
            Button("删除", role: .destructive) {
                Task { await performDelete(provider) }
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: { provider in
            Text("「\(provider.displayName)」(\(provider.platform.title)) 的 API Key、调用记录和配额历史都会一并删除。此操作不可撤销。")
        }
        .alert("删除失败",
               isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
               )
        ) {
            Button("好") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("点击右上角 + 添加你的第一个 Provider")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func toggle(_ provider: ProviderConfig) async {
        var updated = provider
        updated.enabled.toggle()
        do {
            try await controller.updateProvider(updated)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func performDelete(_ provider: ProviderConfig) async {
        do {
            try await controller.removeProvider(id: provider.id)
        } catch {
            deleteError = error.localizedDescription
        }
        pendingDelete = nil
    }
}

// MARK: - Row

private struct ProviderRow: View {
    let provider: ProviderConfig
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.platform.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(provider.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    (provider.enabled ? Color.accentColor : Color.secondary)
                        .opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(provider.platform.title)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Key …\(keyTail)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if !provider.enabled {
                        Text("已停用")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(.secondary.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { provider.enabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }

    private var keyTail: String {
        let ref = provider.apiKeyRef
        if ref.isEmpty { return "----" }
        return String(ref.suffix(4))
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
