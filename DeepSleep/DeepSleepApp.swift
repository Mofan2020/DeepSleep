//
//  DeepSleepApp.swift
//  Deep Sleep
//

import SwiftUI

@main
struct DeepSleepApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SleepController.shared

    var body: some Scene {
        WindowGroup("Deep Sleep", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 940, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("刷新状态") {
                    Task {
                        await controller.refreshHelperState()
                        await controller.refreshPowerSettings()
                        await controller.refreshScheduledWake()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("释放全部保持") {
                    Task { await controller.releaseAllAssertions() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Deep Sleep", systemImage: "moon.zzz.fill") {
            MenuBarView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}
