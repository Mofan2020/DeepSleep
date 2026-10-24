//
//  KeepAliveView.swift
//  Deep Sleep
//
//  AI 保活功能页：任务列表 + 新建 / 编辑表单。
//
//  这一页是独立的功能页，不挂侧边栏 —— 挂载到工具箱是后续阶段的事。
// 入口：把 `KeepAliveView()` 放进任何 NavigationStack / sheet 里即可。
//
//  安全：API Key 用 SecureField 输入，落 Keychain。列表里只显示「已配置 / 未配置」。
//

import SwiftUI

struct KeepAliveView: View {

    @ObservedObject private var engine = KeepAliveEngine.shared

    @State private var showEditor = false
    @State private var editingTask: KeepAliveTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "AI 保活",
                subtitle: "在每天固定时刻给订阅制 AI 服务发一条超短请求，把「按最后一次使用起算」的滚动窗口钉成固定窗口。Deep Sleep 退出后保活停止。",
                symbol: "bolt.horizontal.circle",
                accent: .teal
            ) {
                HStack(spacing: 10) {
                    StatusPill(text: engine.isRunning ? "调度运行中" : "调度已停止", isActive: engine.isRunning)
                    StatusPill(
                        text: "共 \(engine.tasks.count) 条，启用 \(engine.tasks.filter(\.isEnabled).count) 条",
                        isActive: !engine.tasks.isEmpty
                    )
                    Spacer()
                }
            }

            SectionCard(
                title: "保活任务",
                subtitle: engine.tasks.isEmpty ? "还没有任务。点下方「新建任务」配置一条。" : nil,
                symbol: "list.bullet.rectangle"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if engine.tasks.isEmpty {
                        Text("暂无任务")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.tasks) { task in
                            KeepAliveTaskRow(
                                task: task,
                                onToggle: { engine.setEnabled(task.id, $0) },
                                onEdit: {
                                    editingTask = task
                                    showEditor = true
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

                    Divider()

                    HStack(spacing: 10) {
                        Button {
                            editingTask = nil
                            showEditor = true
                        } label: {
                            Label("新建任务", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)

                        Spacer()
                    }
                }
            }

            SectionCard(
                title: "说明",
                symbol: "info.circle"
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    BulletLine("时刻按本机时区算，到点后最多 15 秒内发出。")
                    BulletLine("选中的星期之外不发，那几天的窗口会自然重置。")
                    BulletLine("滚动窗口的重置规则由服务端决定，本地无法验证；能否真的延长窗口需要你自己实测。")
                    BulletLine("请求固定 max_tokens=1，消耗极低，但仍会记入该服务的用量统计。")
                    BulletLine("API Key 存在系统钥匙串里，不写入偏好设置，也不会出现在日志中。")
                }
            }
        }
        .pageLayout()
        .sheet(isPresented: $showEditor) {
            KeepAliveTaskEditor(task: editingTask) { saved in
                engine.upsert(saved)
                editingTask = nil
                showEditor = false
            } onCancel: {
                editingTask = nil
                showEditor = false
            }
        }
    }
}

// MARK: - 任务行

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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    Tag(text: task.format.title, color: .teal)
                    if !task.isEnabled {
                        Tag(text: "已停用", color: .secondary)
                    }
                }

                Text("\(task.baseURL.isEmpty ? "未填地址" : task.baseURL) · \(task.model.isEmpty ? "未选模型" : task.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(task.scheduleDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let last = task.lastRunAt {
                    Text("上次：\(Self.formatTimestamp(last))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let result = task.lastResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(result.hasPrefix("失败") ? Color.red : Color.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    onTrigger()
                } label: {
                    Image(systemName: "paperplane")
                }
                .buttonStyle(.borderless)
                .help("立即发送一次")

                Button {
                    onRestoreTemplate()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("恢复默认请求内容")

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
        }
        .padding(.vertical, 3)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "编辑保活任务" : "新建保活任务")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("例如：Claude Code", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("服务地址").font(.caption).foregroundStyle(.secondary)
                TextField("https://api.anthropic.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("末尾有没有 /v1 都行，会自动补齐。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("请求格式").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $format) {
                    ForEach(KeepAliveFormat.allCases, id: \.self) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(format.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let msg = fetchMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(msg.hasPrefix("失败") ? Color.red : Color.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key").font(.caption).foregroundStyle(.secondary)
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
                    Text("留空表示不修改原 Key。Key 存在系统钥匙串里。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // -------------------------------------------------- 时刻
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("发送时刻").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("每天 \(times.count) 次")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if times.isEmpty {
                    Text("还没设时刻。任务不会自动发送。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    // 每个时刻一行：时间 + 删除。
                    ForEach(times) { time in
                        HStack(spacing: 8) {
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // -------------------------------------------------- 星期
            VStack(alignment: .leading, spacing: 6) {
                Text("运行日").font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(KeepAliveSchedule.weekdayOrder, id: \.self) { weekday in
                        let selected = weekdays.contains(weekday)
                        Button {
                            toggleWeekday(weekday)
                        } label: {
                            Text(KeepAliveSchedule.shortWeekdayName(weekday))
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .frame(width: 28, height: 26)
                                .background(
                                    selected ? Color.accentColor : Color.secondary.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help(KeepAliveSchedule.fullWeekdayName(weekday))
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
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
                    .font(.caption2)
                    .foregroundStyle(weekdays.isEmpty ? Color.orange : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $isEnabled) {
                Text("启用").font(.body)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
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
        .padding(22)
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
