//
//  LogView.swift
//  Deep Sleep
//
//  运行日志页。
//

import SwiftUI

struct LogView: View {

    @EnvironmentObject private var controller: SleepController

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        SectionCard(
            title: "运行日志",
            subtitle: "记录本应用的全部电源操作。助手侧的日志位于 \(HelperConstants.logPath)。",
            symbol: "text.alignleft"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(controller.log.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        controller.clearLog()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(controller.log.isEmpty)
                }

                if controller.log.isEmpty {
                    Text("暂无日志")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(controller.log.reversed()) { entry in
                            HStack(alignment: .top, spacing: 9) {
                                Text(Self.timeFormatter.string(from: entry.date))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 62, alignment: .leading)
                                Text(entry.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}
