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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            SectionCard(
                title: "AI 保活",
                subtitle: "在每天固定时刻给订阅制 AI 服务发一条超短请求，把「按最后一次使用起算」的滚动窗口钉成固定窗口。Deep Sleep 退出后保活停止。",
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
                }
            }

            SectionCard(
                title: "保活任务",
                subtitle: engine.tasks.isEmpty ? nil : "每条一行：接口、频率、下次执行。",
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
                                onToggle: { engine.setEnabled(task.id, $0) },
                                onEdit: {
                                    editorTarget = KeepAliveEditorTarget(task: task)
                                },
                                onTrigger: { engine.triggerNow(id: task.id) },
                                onRestoreTemplate: { engine.restoreDefaultTemplate(id: task.id) },
                                onDelete: { engine.remove(id: task.id) }
                            )
                            if task.id != engine.tasks.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            SectionCard(
                title: "说明",
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    BulletLine("时刻按本机时区算，到点后最多 15 秒内发出。")
                    BulletLine("选中的星期之外不发，那几天的窗口会自然重置。")
                    BulletLine("滚动窗口的重置规则由服务端决定，本地无法验证；能否真的延长窗口需要你自己实测。")
                    BulletLine("请求固定 max_tokens=1，消耗极低，但仍会记入该服务的用量统计。")
                    BulletLine("API Key 存在系统钥匙串里，不写入偏好设置，也不会出现在日志中。")
                }
            }
        }
        .pageLayout()
        .sheet(item: $editorTarget) { target in
            KeepAliveTaskEditor(task: target.task) { saved in
                engine.upsert(saved)
                editorTarget = nil
            } onCancel: {
                editorTarget = nil
            }
        }
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
                    Text("留空表示不修改原 Key。Key 存在系统钥匙串里。")
                        .caption2()
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
                     : "只在选中的日子发送。没选的日子窗口会自然重置。")
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
