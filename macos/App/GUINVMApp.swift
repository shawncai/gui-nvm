import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await AppModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct GUINVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        Window("gui-nvm", id: "main") {
            MainView(model: model)
                .frame(minWidth: 1060, minHeight: 660)
                .preferredColorScheme(.light)
                .task { await model.initialize() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        }
        .defaultSize(width: 1380, height: 850)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.navigate(.settings) }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("添加项目…") { model.chooseDirectory(for: "project") }.keyboardShortcut("o")
                Button("添加扫描目录…") { model.chooseDirectory(for: "root") }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("导航") {
                ForEach(Array(AppRoute.allCases.enumerated()), id: \.element.id) { index, route in
                    Button(route.title) { model.navigate(route) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
                Button("搜索项目或版本") { model.focusSearch() }.keyboardShortcut("k")
                Button("刷新本机状态") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button(model.snapshot.scan.state == "running" ? "取消扫描" : "重新扫描") { model.toggleScan() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
