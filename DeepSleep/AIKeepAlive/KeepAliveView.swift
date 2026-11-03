//
//  KeepAliveView.swift
//  Deep Sleep
//
//  AI 保活功能页：任务列表 + 新建 / 编辑表单。
//
//  这一页是独立的功能页，不挂侧边栏 —— 挂载到工具箱是后续阶段的事。
//  入口：把 `KeepAliveView()` 放进任何 NavigationStack / sheet 里即可。
//
//  安全：API Key 用 SecureField 输入，落 Keychain。列表里只显示「已配置 / 未配置」。
//
//  2026-11 界面换新：
//    - 间距、圆角走 DS.Space / DS.Radius。
//    - 任务列表每条压成一行：名称 / 接口 / 频率 / 下次执行 / 开关。
//    - 引擎状态用 StatusPill + 文字双编码（运行中 / 已暂停 / 未配置 / 引擎未就绪）。
//    - 新建与编辑走 sheet：detail 列里没有 NavigationStack，不能用
//      NavigationLink 推栈。
//

import SwiftUI

/// 编辑器目标：告诉 sheet 这次是新建还是编辑哪一条。
///
/// 每次点击都造一个新实例，`id` 随之变化 —— sheet 内容跟着重建，
/// 不会残留上一条任务填过的表单。
struct KeepAliveEditorTarget: Identifiable {

    let id = UUID()

    /// 要编辑的任务。`nil` 表示新建。
    let task: KeepAliveTask?
}

struct KeepAliveView: View {

    @ObservedObject private var engine = KeepAliveEngine.shared

    /// 编辑器当前要处理的任务。`nil` 表示编辑器不显示。
    ///
    /// 之前这里是 `showEditor` + `editingTask` 两个状态配 `.sheet(isPresented:)`：
    /// 首次点「编辑」时，sheet 的内容闭包是在 `editingTask` 仍为 nil 的那一轮
    /// 渲染里求值的，而 `KeepAliveTaskEditor` 的 `task` 是构造时定型的 `let`
    /// —— 于是打开的是新建页；关掉再点一次时 `editingTask` 已经有值，
    /// 才表现得「第二次才正常」。
    /// 改成 `.sheet(item:)`：目标对象与 sheet 一起创建，值不会错。
    @State private var editorTarget: KeepAliveEditorTarget?

    /// 需要重新输入 API Key 的任务 id。
    ///
    /// 这不是 `@Published` 的状态（钥匙串访问状态在另一个模块里），
    /// 所以靠下面的定时刷新同步 —— 状态本身很少变，20 秒一次足够。
    @State private var reauthorizationTaskIDs: Set<UUID> = []

    /// 待确认的删除。`nil` 表示没有删除在等确认。
    @State private var pendingDelete: TlDeleteRequest?

    /// 最近一次「一键授权」的结果。`nil` 表示还没跑过。
    @State private var authorizationReport: KeepAliveAuthorizationReport?
    /// 是否正在授权。授权期间按钮要禁用 —— 连点会叠出好几个系统授权框。
    @State private var isAuthorizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "AI 保活",
                subtitle: "每天定时给订阅制 AI 服务发一条极短请求。能否延长使用窗口由服务方决定，需要自己实测。"
                        + "请求很短，但仍会记进该服务的用量统计。",
                symbol: "bolt.horizontal.circle",
                accent: .teal
            ) {
                HStack(spacing: DS.Space.sm) {
                    StatusPill(text: engineStatusText,
                               isActive: engineStatusIsRunning,
                               color: engineStatusColor)
                    StatusPill(text: "共 \(engine.tasks.count) 条，启用 \(engine.tasks.filter(\.isEnabled).count) 条",
                               isActive: !engine.tasks.isEmpty,
                               color: engine.tasks.isEmpty ? DS.Tone.idle : DS.Tone.info)
                    Spacer(minLength: DS.Space.sm)
                    // 一键授权：不需要先等到失败才点 —— 应用更新之后主动点一次，
                    // 比等某条任务定时触发时才弹框省事。
                    Button {
                        runAuthorization()
                    } label: {
                        Label(isAuthorizing ? "正在授权…" : "一键授权 Key",
                              systemImage: isAuthorizing ? "hourglass" : "key.horizontal.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAuthorizing || engine.tasks.isEmpty)
                    .help("逐条读取钥匙串里的 API Key（不发任何请求）。"
                          + "每个系统弹框里选「始终允许」，之后定时运行就不会再问。")
                }
            }

            if let report = authorizationReport {
                authorizationResultNotice(report)
            }

            if !reauthorizationTaskIDs.isEmpty {
                reauthorizationNotice
            }

            SectionCard(
                title: "保活任务",
                subtitle: nil,
                symbol: "list.bullet.rectangle",
                accessory: AnyView(
                    Button {
                        editorTarget = KeepAliveEditorTarget(task: nil)
                    } label: {
                        Label("新建任务", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                )
            ) {
                if engine.tasks.isEmpty {
                    EmptyStateView(
                        title: "还没有保活任务",
                        message: "新建一条，填上服务地址、模型名和 API Key，再定下每天要发请求的时刻。",
                        systemImage: "bolt.slash",
                        actionTitle: "新建任务",
                        action: { editorTarget = KeepAliveEditorTarget(task: nil) }
                    )
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(engine.tasks) { task in
                            KeepAliveTaskRow(
                                task: task,
                                needsReauthorization: reauthorizationTaskIDs.contains(task.id),
                                onToggle: { engine.setEnabled(task.id, $0) },
                                onEdit: {
                                    editorTarget = KeepAliveEditorTarget(task: task)
                                },
                                onTrigger: { engine.triggerNow(id: task.id) },
                                onRestoreTemplate: { engine.restoreDefaultTemplate(id: task.id) },
                                onDelete: {
                                    // 删除会连带删掉钥匙串里的 API Key —— 删了就找不回来，
                                    // 所以先问一句。
                                    pendingDelete = TlDeleteRequest(
                                        title: "删除保活任务？",
                                        message: "「\(task.name)」会被删掉，钥匙串里对应的 API Key 也会一并删除。"
                                            + "删掉之后想恢复，只能重新填一次 Key。",
                                        perform: { engine.remove(id: task.id) }
                                    )
                                }
                            )
                            if task.id != engine.tasks.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .pageLayout()
        .deleteConfirmation($pendingDelete)
        .task {
            // 钥匙串的授权状态不在 @Published 里，这里定期同步一次。
            while !Task.isCancelled {
                refreshReauthorizationState()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .sheet(item: $editorTarget) { target in
            KeepAliveTaskEditor(task: target.task) { saved in
                engine.upsert(saved)
                editorTarget = nil
            } onCancel: {
                editorTarget = nil
            }
        }
    }

    // MARK: - 一键授权

    /// 逐条把 API Key 重新授权一遍。
    ///
    /// 用户点一次按钮，系统会为每条 Key 弹一次授权框（如果这个版本还没被信任），
    /// 用户在每个框里点「始终允许」，之后这个版本的定时任务就不再弹框。
    ///
    /// **不发任何网络请求** —— 只读钥匙串。
    private func runAuthorization() {
        guard !isAuthorizing else { return }
        let targets = engine.tasks.map { (name: $0.name, account: $0.apiKeyRef) }
        guard !targets.isEmpty else { return }

        isAuthorizing = true
        authorizationReport = nil

        // 必须离开主线程：每一条都可能弹系统授权框并等用户操作，
        // 跑在主线程上整个界面会僵住。
        Task {
            // 只把 targets 交给后台 —— 不捕获 self，避免跨 actor 传递整个 View。
            let report = await Task.detached(priority: .userInitiated) {
                KeepAliveKeychainAuthorizer.authorizeAll(targets)
            }.value

            // 授权到位的任务解除「跳过」标记 ——
            // 不解的话调度器仍然会主动跳过，等于白授权。
            for item in report.items where item.outcome.isSettled {
                KeepAliveKeychainAccess.shared.clear(item.account)
            }
            authorizationReport = report
            isAuthorizing = false
            refreshReauthorizationState()
        }
    }

    /// 授权结果条。
    ///
    /// 成功的部分只说「已就绪」，失败的逐条列出要用户做什么 ——
    /// 用户点完一堆系统弹框之后，需要知道哪几条还没成。
    private func authorizationResultNotice(_ report: KeepAliveAuthorizationReport) -> some View {
        let allSettled = report.allSettled
        let pending = report.items.filter { !$0.outcome.isSettled }
        return HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: allSettled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(allSettled ? DS.Tone.good : DS.Tone.caution)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(report.summary)
                    .foregroundStyle(.primary)
                ForEach(pending) { item in
                    Text("\(item.taskName)：\(item.outcome.title)")
                        .foregroundStyle(.secondary)
                }
                if let hint = pending.first?.outcome.hint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.md)
        .insetPanel()
    }

    // MARK: - 钥匙串重新授权

    /// 从钥匙串的授权状态里算出哪些任务需要用户重新输入 API Key。
    private func refreshReauthorizationState() {
        let denied = Set(KeepAliveKeychainAccess.shared.deniedAccounts())
        guard !denied.isEmpty else {
            if !reauthorizationTaskIDs.isEmpty { reauthorizationTaskIDs = [] }
            return
        }
        let ids = Set(engine.tasks.filter { denied.contains($0.apiKeyRef) }.map(\.id))
        if ids != reauthorizationTaskIDs { reauthorizationTaskIDs = ids }
    }

    /// 需要重新授权时的提示条。
    ///
    /// 关键是把「只需要做一次」和「在此之前不会再弹框」说清楚：
    /// 用户最担心的是反复被打扰，所以这两句必须写出来。
    private var reauthorizationNotice: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Tone.caution)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("有 \(reauthorizationTaskIDs.count) 条任务的 API Key 需要重新授权。")
                    .foregroundStyle(.primary)
                Text("应用更新之后，系统钥匙串会认不出这是同一个应用，于是拒绝读取。"
                     + "点上面的「一键授权 Key」，在每个系统弹框里选「始终允许」——"
                     + "只做这一次，之后更新不会再问。在这之前这些任务不会发请求，也不会再弹授权框。")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.md)
        .insetPanel()
    }

    // MARK: - 引擎状态

    /// 引擎状态文案。颜色 + 文字双编码，光看颜色分不出「暂停」和「没配」。
    private var engineStatusText: String {
        switch engine.status {
        case .running:
            return "调度运行中"
        case .paused:
            return "调度已暂停"
        case .notConfigured:
            return "未配置任务"
        case .unavailable(let reason):
            return "引擎未就绪：\(reason)"
        }
    }

    private var engineStatusColor: Color {
        switch engine.status {
        case .running:      return DS.Tone.good
        case .paused:       return DS.Tone.idle
        case .notConfigured: return DS.Tone.caution
        case .unavailable:  return DS.Tone.critical
        }
    }

    /// 状态灯是否亮。只有「调度运行中」算亮着。
    private var engineStatusIsRunning: Bool {
        if case .running = engine.status { return true }
        return false
    }
}

// MARK: - 任务行

/// 一条保活任务，压成一行：名称 / 接口 / 频率 / 下次执行 / 开关。
struct KeepAliveTaskRow: View {

    let task: KeepAliveTask
    /// 这条任务的 API Key 需要重新输入（钥匙串拒绝了访问）。
    var needsReauthorization: Bool = false
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onTrigger: () -> Void
    let onRestoreTemplate: () -> Void
    let onDelete: () -> Void

    private var title: String {
        task.name.isEmpty ? (task.model.isEmpty ? "未命名任务" : task.model) : task.name
    }

    /// 接口地址。空的话显示占位文案，不显示空白。
    private var endpointText: String {
        task.baseURL.isEmpty ? "未填地址" : task.baseURL
    }

    /// 频率：每天几次 + 哪几天。
    private var frequencyText: String {
        let times = task.schedule.times.count
        let countText = times == 0 ? "未设时刻" : "每天 \(times) 次"
        return "\(countText) · \(task.schedule.weekdayDescription)"
    }

    /// 下次执行时刻。引擎只在 15 秒粒度上判定，界面显示的是计划时刻。
    private var nextRunText: String {
        guard let next = task.schedule.nextSlot(after: Date()) else { return "未排期" }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.sm) {
                    Text(title).font(.body.weight(.medium))
                    Tag(text: task.format.title, color: .teal)
                    if !task.isEnabled {
                        Tag(text: "已停用", color: DS.Tone.idle)
                    }
                    if needsReauthorization {
                        Tag(text: "需重新授权", color: DS.Tone.caution)
                    }
                }

                Text("接口 \(endpointText) · \(frequencyText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let last = task.lastRunAt {
                    Text("上次：\(Self.formatTimestamp(last))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let result = task.lastResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(result.hasPrefix("失败") ? DS.Tone.critical : .secondary)
                }
            }

            Spacer(minLength: DS.Space.sm)

            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                Text("下次执行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(nextRunText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Menu {
                Button {
                    onTrigger()
                } label: {
                    Label("立即发送一次", systemImage: "paperplane")
                }
                Button {
                    onRestoreTemplate()
                } label: {
                    Label("恢复默认请求内容", systemImage: "arrow.uturn.backward")
                }
                Button {
                    onEdit()
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
        }
        .padding(.vertical, DS.Space.xs)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 编辑器

struct KeepAliveTaskEditor: View {

    /// 传 nil 表示新建。
    let task: KeepAliveTask?
    let onSave: (KeepAliveTask) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var format: KeepAliveFormat = .openAI
    @State private var model: String = ""
    @State private var apiKey: String = ""
    @State private var revealKey: Bool = false
    @State private var times: [KeepAliveTime] = KeepAliveSchedule.defaultTimes
    @State private var weekdays: Set<Int> = KeepAliveSchedule.defaultWeekdays
    @State private var requestTemplate: String = KeepAliveDefaults.defaultRequestTemplate
    @State private var isEnabled: Bool = true

    @State private var isFetchingModels = false
    @State private var fetchedModels: [String] = []
    @State private var fetchMessage: String?
    @State private var saveError: String?

    private var isEdit: Bool { task != nil }

    /// 新建时用 id 生成 Keychain account 名；编辑时沿用原来的。
    /// 这条任务的 API Key 需要重新输入（钥匙串拒绝了访问）。
    private var needsReauthorization: Bool {
        KeepAliveKeychainAccess.shared.needsReauthorization(apiKeyRef)
    }

    private var apiKeyRef: String {
        if let task { return task.apiKeyRef }
        return KeepAliveStore.keychainAccount(for: draftID)
    }

    /// 新建任务的 id。先定下来，Keychain account 名与它对应。
    @State private var draftID: UUID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(isEdit ? "编辑保活任务" : "新建保活任务")
                .font(.title3.weight(.semibold))

            LabeledContent("名称") {
                TextField("例如：Claude Code", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                LabeledContent("服务地址") {
                    TextField("https://api.anthropic.com", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("末尾有没有 /v1 都行，会自动补齐。")
                    .caption2()
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                LabeledContent("请求格式") {
                    Picker("", selection: $format) {
                        ForEach(KeepAliveFormat.allCases, id: \.self) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text(format.detail)
                    .caption2()
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text("模型名").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        fetchModels()
                    } label: {
                        if isFetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新模型列表", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isFetchingModels)
                }

                // 模型名始终可以手填：服务端不一定实现 /models 接口，
                // 或者用户就是想填一个列表里没有的模型名。
                TextField("claude-sonnet-4-5", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if !fetchedModels.isEmpty {
                    Picker("", selection: $model) {
                        ForEach(fetchedModels, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()
                    Text("拉到 \(fetchedModels.count) 个模型，可直接选。")
                        .caption2()
                }

                if let msg = fetchMessage {
                    Text(msg)
                        .caption2()
                        .foregroundStyle(msg.hasPrefix("失败") ? DS.Tone.critical : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                LabeledContent("API Key") {
                    HStack(spacing: DS.Space.sm) {
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
                }
                if isEdit {
                    if needsReauthorization {
                        // 钥匙串拒绝了访问 —— 这次不能「留空表示不修改」，
                        // 必须重新填一次，所以要把话说死。
                        Text("钥匙串拒绝了访问这条 Key（应用更新后常见）。请把 API Key 重新输入一次再保存 —— 只需要这一次。")
                            .caption2()
                            .foregroundStyle(DS.Tone.caution)
                    } else {
                        Text("留空表示不修改原 Key。")
                            .caption2()
                    }
                }
            }

            // -------------------------------------------------- 时刻
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text("发送时刻").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("每天 \(times.count) 次")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if times.isEmpty {
                    Text("还没设时刻。任务不会自动发送。")
                        .caption2()
                        .foregroundStyle(DS.Tone.caution)
                } else {
                    // 每个时刻一行：时间 + 删除。
                    ForEach(times) { time in
                        HStack(spacing: DS.Space.sm) {
                            DatePicker(
                                "",
                                selection: binding(for: time),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .datePickerStyle(.field)

                            Spacer()

                            Button {
                                removeTime(time)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("删掉这个时刻")
                        }
                    }
                }

                Button {
                    addTime()
                } label: {
                    Label("加一个时刻", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(times.count >= KeepAliveDefaults.maxTimesPerDay)

                Text("到点后最多 15 秒内发出。时刻按本机时区算。")
                    .caption2()
            }

            // -------------------------------------------------- 星期
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("运行日").font(.caption).foregroundStyle(.secondary)

                HStack(spacing: DS.Space.xs) {
                    ForEach(KeepAliveSchedule.weekdayOrder, id: \.self) { weekday in
                        let selected = weekdays.contains(weekday)
                        Button {
                            toggleWeekday(weekday)
                        } label: {
                            Text(KeepAliveSchedule.shortWeekdayName(weekday))
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .frame(width: 28, height: 26)
                                .background(
                                    selected ? DS.Tone.info : Color.secondary.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                )
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help(KeepAliveSchedule.fullWeekdayName(weekday))
                    }
                    Spacer()
                }

                HStack(spacing: DS.Space.sm) {
                    Button("工作日") { weekdays = [2, 3, 4, 5, 6] }
                        .controlSize(.small)
                    Button("每天") { weekdays = KeepAliveSchedule.allWeekdays }
                        .controlSize(.small)
                    Button("清空") { weekdays = [] }
                        .controlSize(.small)
                    Spacer()
                }

                Text(weekdays.isEmpty
                     ? "没选任何一天，这条任务不会自动发送。"
                     : "只在选中的日子发送。")
                    .caption2()
                    .foregroundStyle(weekdays.isEmpty ? DS.Tone.caution : .secondary)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text("请求内容").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        requestTemplate = KeepAliveDefaults.defaultRequestTemplate
                    } label: {
                        Label("恢复默认模板", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                }
                TextField("测试消息，直接回复‘ping’即可", text: $requestTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Text("默认模板：\(KeepAliveDefaults.defaultRequestTemplate)")
                    .caption2()
            }

            Toggle(isOn: $isEnabled) {
                Text("启用").font(.body)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(DS.Tone.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 540)
        .onAppear { loadExisting() }
    }

    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !requestTemplate.trimmingCharacters(in: .whitespaces).isEmpty
            && (isEdit || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func loadExisting() {
        guard let task else {
            name = ""
            baseURL = ""
            format = .openAI
            model = ""
            apiKey = ""
            times = KeepAliveSchedule.defaultTimes
            weekdays = KeepAliveSchedule.defaultWeekdays
            requestTemplate = KeepAliveDefaults.defaultRequestTemplate
            isEnabled = true
            return
        }
        draftID = task.id
        name = task.name
        baseURL = task.baseURL
        format = task.format
        model = task.model
        apiKey = ""
        times = task.schedule.times
        weekdays = task.schedule.weekdays
        requestTemplate = task.requestTemplate
        isEnabled = task.isEnabled
    }

    // MARK: - 时刻与星期的操作

    /// DatePicker 要一个 Date；内部只取时与分。
    private func binding(for time: KeepAliveTime) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                let updated = KeepAliveTime(
                    hour: comps.hour ?? time.hour,
                    minute: comps.minute ?? time.minute
                )
                times.removeAll { $0 == time }
                times.append(updated)
                times.sort()
            }
        )
    }

    /// 加一个时刻。默认接在最后一个时刻后面，隔 4 小时。
    private func addTime() {
        guard times.count < KeepAliveDefaults.maxTimesPerDay else { return }
        let base = times.last.map(\.minutesFromMidnight) ?? (9 * 60)
        let next = (base + 4 * 60) % (24 * 60)
        let candidate = KeepAliveTime(minutesFromMidnight: next)
        // 与已有时刻撞了就往后挪一分钟。
        var probe = candidate
        var guardCount = 0
        while times.contains(probe) && guardCount < 24 * 60 {
            probe = KeepAliveTime(minutesFromMidnight: (probe.minutesFromMidnight + 1) % (24 * 60))
            guardCount += 1
        }
        times.append(probe)
        times.sort()
    }

    private func removeTime(_ time: KeepAliveTime) {
        times.removeAll { $0 == time }
    }

    private func toggleWeekday(_ weekday: Int) {
        if weekdays.contains(weekday) {
            weekdays.remove(weekday)
        } else {
            weekdays.insert(weekday)
        }
    }

    // MARK: - 动作

    private func fetchModels() {
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isFetchingModels = true
        fetchMessage = nil
        Task {
            // 输入框为空（编辑已有任务时就是这样）就用钥匙串里已存的那把。
            var key = typedKey
            if key.isEmpty {
                key = (try? await KeepAliveStore.readAPIKey(account: apiKeyRef)) ?? ""
            }
            guard !key.isEmpty else {
                fetchMessage = "失败：先填 API Key"
                isFetchingModels = false
                return
            }
            let result = await KeepAliveClient.listModels(
                baseURL: baseURL,
                format: format,
                apiKey: key
            )
            fetchedModels = result.models
            fetchMessage = result.models.isEmpty
                ? "失败：\(result.summary)"
                : result.summary
            isFetchingModels = false
        }
    }

    private func save() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            Task {
                do {
                    try await KeepAliveStore.writeAPIKey(trimmedKey, account: apiKeyRef)
                } catch {
                    saveError = "写入钥匙串失败：\(error.localizedDescription)"
                    return
                }
                commitSave()
            }
            return
        }
        commitSave()
    }

    /// 真正落盘任务配置。Key 已写进钥匙串之后才走到这里。
    private func commitSave() {
        let existing = task
        var saved = KeepAliveTask(
            id: existing?.id ?? draftID,
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            format: format,
            model: model.trimmingCharacters(in: .whitespaces),
            apiKeyRef: apiKeyRef,
            schedule: KeepAliveSchedule(times: times, weekdays: weekdays),
            requestTemplate: requestTemplate,
            isEnabled: isEnabled,
            lastRunAt: existing?.lastRunAt,
            lastResult: existing?.lastResult,
            createdAt: existing?.createdAt ?? Date()
        )
        saved = saved.clamped
        onSave(saved)
    }
}
