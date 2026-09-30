//
//  DeepSleepAppShortcuts.swift
//  Deep Sleep
//
//  App Shortcuts：把上面那些 App Intent 附上「说出来就能跑」的中文短语。
//  这些短语是 Siri 认得的入口，也会出现在「快捷指令」App 的 Deep Sleep 分区里。
//
//  两条框架硬性规则：
//    1. 每条短语**必须**包含应用名占位符 `\(.applicationName)`，
//       否则编译期就会报错 —— 系统靠它做语音识别消歧。
//    2. 短语是编译期常量，不能由运行时数据拼出来。
//
//  于是短语不可避免地要写两遍：一遍是给编译器的类型化短语，一遍是给人看的
//  纯文本（界面区块、`--automation` 输出、文档都读后者）。
//  为了不让这两份漂移，`scripts/check-docs.py` 会逐条比对它们 ——
//  这是项目里「机器能查的，不让它靠人记」的同一条原则。
//

import AppIntents

/// 给人看的短语目录。
///
/// `phrases` 里的 `{应用名}` 是占位符：真实短语里它是系统注入的应用名
/// （也就是「Deep Sleep」）。界面与文档直接展示这一份。
enum DeepSleepShortcutCatalog {

    /// 与类型化短语里的 `\(.applicationName)` 对应的展示占位符。
    static let appNamePlaceholder = "{应用名}"

    struct Entry: Identifiable {
        let title: String
        let symbol: String
        let phrases: [String]
        var id: String { title }
    }

    static let entries: [Entry] = [
        Entry(title: "保持清醒", symbol: "moon.zzz.fill", phrases: [
            "用 {应用名} 保持清醒",
            "用 {应用名} 阻止睡眠",
            "用 {应用名} 保持屏幕常亮"
        ]),
        Entry(title: "允许睡眠", symbol: "zzz", phrases: [
            "用 {应用名} 允许睡眠",
            "用 {应用名} 释放保持"
        ]),
        Entry(title: "查询保持状态", symbol: "questionmark.circle", phrases: [
            "用 {应用名} 查询睡眠状态",
            "用 {应用名} 查看保持状态"
        ]),
        Entry(title: "立即睡眠", symbol: "powersleep", phrases: [
            "用 {应用名} 立即睡眠"
        ]),
        Entry(title: "排定唤醒", symbol: "alarm", phrases: [
            "用 {应用名} 排定唤醒",
            "用 {应用名} 定时唤醒"
        ]),
        Entry(title: "取消定时唤醒", symbol: "alarm.slash", phrases: [
            "用 {应用名} 取消唤醒"
        ]),
        Entry(title: "完全禁止睡眠", symbol: "lock.shield", phrases: [
            "用 {应用名} 完全禁止睡眠",
            "用 {应用名} 恢复系统睡眠"
        ]),
        Entry(title: "强制退出选定的应用", symbol: "xmark.circle", phrases: [
            "用 {应用名} 强制退出选定的应用",
            "用 {应用名} 快速退出",
            "用 {应用名} 结束选定的应用"
        ])
    ]

    /// 把展示用短语还原成实际可说的句子。
    static func spoken(_ phrase: String, appName: String = "Deep Sleep") -> String {
        phrase.replacingOccurrences(of: appNamePlaceholder, with: appName)
    }
}

/// App Shortcuts 的提供者。短语与 `DeepSleepShortcutCatalog` 一一对应。
struct DeepSleepAppShortcuts: AppShortcutsProvider {

    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: HoldAwakeIntent(),
            phrases: [
                "用 \(.applicationName) 保持清醒",
                "用 \(.applicationName) 阻止睡眠",
                "用 \(.applicationName) 保持屏幕常亮"
            ],
            shortTitle: "保持清醒",
            systemImageName: "moon.zzz.fill"
        )

        AppShortcut(
            intent: ReleaseAwakeIntent(),
            phrases: [
                "用 \(.applicationName) 允许睡眠",
                "用 \(.applicationName) 释放保持"
            ],
            shortTitle: "允许睡眠",
            systemImageName: "zzz"
        )

        AppShortcut(
            intent: AwakeStatusIntent(),
            phrases: [
                "用 \(.applicationName) 查询睡眠状态",
                "用 \(.applicationName) 查看保持状态"
            ],
            shortTitle: "查询保持状态",
            systemImageName: "questionmark.circle"
        )

        AppShortcut(
            intent: SleepNowIntent(),
            phrases: [
                "用 \(.applicationName) 立即睡眠"
            ],
            shortTitle: "立即睡眠",
            systemImageName: "powersleep"
        )

        AppShortcut(
            intent: ScheduleWakeIntent(),
            phrases: [
                "用 \(.applicationName) 排定唤醒",
                "用 \(.applicationName) 定时唤醒"
            ],
            shortTitle: "排定唤醒",
            systemImageName: "alarm"
        )

        AppShortcut(
            intent: CancelScheduledWakeIntent(),
            phrases: [
                "用 \(.applicationName) 取消唤醒"
            ],
            shortTitle: "取消定时唤醒",
            systemImageName: "alarm.slash"
        )

        AppShortcut(
            intent: SetSleepDisabledIntent(),
            phrases: [
                "用 \(.applicationName) 完全禁止睡眠",
                "用 \(.applicationName) 恢复系统睡眠"
            ],
            shortTitle: "完全禁止睡眠",
            systemImageName: "lock.shield"
        )

        AppShortcut(
            intent: QuickQuitAppsIntent(),
            phrases: [
                "用 \(.applicationName) 强制退出选定的应用",
                "用 \(.applicationName) 快速退出",
                "用 \(.applicationName) 结束选定的应用"
            ],
            shortTitle: "强制退出选定的应用",
            systemImageName: "xmark.circle"
        )
    }
}
