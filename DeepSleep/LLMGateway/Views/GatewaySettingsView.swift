//
//  GatewaySettingsView.swift
//  Deep Sleep
//
//  LLM 网关设置：端口 / 鉴权 / 日志 / 启停 + 健康检查。
//

import SwiftUI
import AppKit

struct GatewaySettingsView: View {

    @ObservedObject private var controller = GatewayController.shared
    @State private var portText: String = ""
    @State private var authToken: String = ""
    @State private var revealToken: Bool = false
    @State private var portError: String?
    @State private var healthResult: HealthResult?
    /// 是否弹出 Provider 列表。
    @State private var showProviders = false

    struct HealthResult: Identifiable {
        let id = UUID()
        let ok: Bool
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                configCard
                providerCard
                controlCard
                healthCard
            }
            .pageLayout()
        }
        .navigationTitle("LLM 网关")
        .onAppear { hydrate() }
        // 以前 load() 从来没被调用过，Provider 列表永远是空的。
        .task { await controller.ensureLoaded() }
        .sheet(isPresented: $showProviders) {
            // Provider 列表里有 NavigationLink（进 ProviderEditView），
            // sheet 里没有 NavigationStack 的话那个 link 推不动。
            NavigationStack {
                ProviderListView()
            }
        }
        .onChange(of: controller.gatewayConfig) { _ in hydrate() }
        .alert("端口无效",
               isPresented: Binding(
                get: { portError != nil },
                set: { if !$0 { portError = nil } }
               )
        ) {
            Button("好") { portError = nil }
        } message: {
            Text(portError ?? "")
        }
        .alert(healthResult?.ok == true ? "健康" : "异常",
               isPresented: Binding(
                get: { healthResult != nil },
                set: { if !$0 { healthResult = nil } }
               ),
               presenting: healthResult
        ) { _ in
            Button("好") { healthResult = nil }
        } message: { r in
            Text(r.message)
        }
    }

    // MARK: - Sections

    private var configCard: some View {
        SectionCard(
            title: "网关配置",
            subtitle: "监听 \(controller.gatewayConfig.bindAddress):\(controller.gatewayConfig.port)",
            symbol: "network"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("端口")
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit { commitPort() }
                    Spacer()
                    Button("应用") { commitPort() }
                }

                Toggle(isOn: Binding(
                    get: { controller.gatewayConfig.requireAuth },
                    set: { newValue in
                        var cfg = controller.gatewayConfig
                        cfg.requireAuth = newValue
                        if !newValue { cfg.authToken = nil }
                        controller.gatewayConfig = cfg
                    }
                )) {
                    Text("需要鉴权")
                }
                .toggleStyle(.switch)

                if controller.gatewayConfig.requireAuth {
                    HStack {
                        Text("Token")
                            .frame(width: 70, alignment: .leading)
                        Group {
                            if revealToken {
                                TextField("", text: $authToken)
                            } else {
                                SecureField("", text: $authToken)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            revealToken.toggle()
                        } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Spacer()
                        Button("保存 Token") {
                            var cfg = controller.gatewayConfig
                            cfg.authToken = authToken.isEmpty ? nil : authToken
                            controller.gatewayConfig = cfg
                        }
                        .disabled(authToken.isEmpty && controller.gatewayConfig.authToken == nil)
                    }
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { controller.gatewayConfig.logRequests },
                    set: { newValue in
                        var cfg = controller.gatewayConfig
                        cfg.logRequests = newValue
                        controller.gatewayConfig = cfg
                    }
                )) {
                    Text("记录请求日志")
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var providerCard: some View {
        SectionCard(
            title: "Provider",
            subtitle: controller.providers.isEmpty
                ? "还没有配置 Provider，网关没有可转发的目标"
                : "已配置 \(controller.providers.count) 个 Provider",
            symbol: "server.rack"
        ) {
            HStack(spacing: 10) {
                Button {
                    showProviders = true
                } label: {
                    Label(
                        "Provider（\(controller.providers.count) 个）",
                        systemImage: "chevron.right"
                    )
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 8)
            }
        }
    }

    private var controlCard: some View {
        SectionCard(
            title: "运行状态",
            subtitle: controller.isRunning ? "网关已在 127.0.0.1:\(controller.gatewayConfig.port) 监听" : "未启动",
            symbol: controller.isRunning ? "circle.fill" : "circle",
            accent: controller.isRunning ? .green : .secondary
        ) {
            HStack(spacing: 10) {
                if controller.isRunning {
                    Button(role: .destructive) {
                        controller.stopGateway()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task {
                            do {
                                try await controller.startGateway()
                            } catch {
                                healthResult = HealthResult(
                                    ok: false, message: "启动失败：\(error.localizedDescription)"
                                )
                            }
                        }
                    } label: {
                        Label("启动", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                StatusPill(
                    text: controller.isRunning ? "运行中" : "已停止",
                    isActive: controller.isRunning
                )
            }
        }
    }

    private var healthCard: some View {
        SectionCard(
            title: "健康检查",
            subtitle: "HTTP GET 127.0.0.1:\(controller.gatewayConfig.port)/health",
            symbol: "heart.text.square"
        ) {
            Button {
                Task { await runHealth() }
            } label: {
                Label("立即检查", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func hydrate() {
        portText = "\(controller.gatewayConfig.port)"
        authToken = controller.gatewayConfig.authToken ?? ""
        revealToken = false
    }

    private func commitPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
            portError = "端口必须是数字"
            return
        }
        guard (1...65535).contains(port) else {
            portError = "端口范围应为 1~65535"
            return
        }
        var cfg = controller.gatewayConfig
        cfg.port = port
        controller.gatewayConfig = cfg
    }

    private func runHealth() async {
        let url = URL(string: "http://127.0.0.1:\(controller.gatewayConfig.port)/health")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        if let token = controller.gatewayConfig.authToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            let ok = (200..<400).contains(status)
            healthResult = HealthResult(
                ok: ok,
                message: "HTTP \(status)\n\(body)"
            )
        } catch {
            healthResult = HealthResult(ok: false, message: error.localizedDescription)
        }
    }
}
