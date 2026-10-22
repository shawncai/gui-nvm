import AppKit
import SwiftUI
import GUINVMCore

enum AppTheme {
    static let secondary = Color(white: 0.42)
    static let sidebar = Color(white: 0.955)
    static let line = Color(white: 0.89)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let accent = Color("AccentColor")
}

/// The native table supplies its own active/inactive selection foreground.
/// Secondary labels must inherit that foreground while their row is selected.
struct SelectionForeground: ViewModifier {
    let selected: Bool
    let unselected: Color
    @ViewBuilder func body(content: Content) -> some View {
        if selected { content }
        else { content.foregroundStyle(unselected) }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 13).frame(minHeight: 30)
            .foregroundStyle(enabled ? .white : Color(white: 0.60))
            .background(enabled ? Color(white: configuration.isPressed ? 0.25 : 0.10) : Color(white: 0.91), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 290)
        } detail: {
            VStack(spacing: 0) {
                header
                if let error = model.connectionError { InlineMessage(text: error, isError: true, actionTitle: "重试") { Task { await model.retry() } } }
                ForEach(model.notices, id: \.self) { notice in
                    InlineMessage(text: notice, actionTitle: "关闭") { model.dismissedNotices.insert(notice) }
                }
                if model.loading { ProgressView("读取本机环境…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    switch model.route {
                    case .projects: ProjectsView(model: model)
                    case .versions: VersionsView(model: model)
                    case .tasks: TasksView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                footer
            }
            .background(.white)
            .inspector(isPresented: Binding(get: { model.route == .projects && model.selectedProject != nil }, set: { if !$0 { model.selectedProjectID = nil } })) {
                if let project = model.selectedProject {
                    ProjectInspector(model: model, project: project).id(project.id)
                        .inspectorColumnWidth(min: 330, ideal: 370, max: 460)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .font(.system(size: 14))
        .tint(AppTheme.accent)
        .toolbar { ToolbarItem(placement: .principal) { Text("gui-nvm").font(.system(size: 13, weight: .semibold)) } }
        .sheet(item: $model.confirmation) { confirmation in ConfirmationView(model: model, confirmation: confirmation) }
        .alert("操作未完成", isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } })) {
            Button("好", role: .cancel) { model.operationError = nil }
        } message: { Text(model.operationError ?? "") }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                    Text(toast).textSelection(.enabled)
                    Button { model.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭通知")
                }
                .font(.system(size: 13)).padding(12).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(.white).padding(.bottom, 45)
                .accessibilityIdentifier("operationToast")
            }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.focusSearch() } label: {
                HStack { Image(systemName: "magnifyingglass"); Text("搜索…"); Spacer(); Text("⌘ K").font(.system(size: 11)).foregroundStyle(AppTheme.secondary) }
                    .padding(9).background(.white, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.line))
            }.buttonStyle(.plain).padding(.top, 10).accessibilityLabel("搜索项目或版本")
            VStack(spacing: 4) {
                ForEach([AppRoute.projects, .versions, .tasks]) { route in
                    sidebarItem(route)
                }
            }
            HStack {
                Text("扫描目录").font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.secondary)
                Spacer()
                Button { model.chooseDirectory(for: "root") } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("添加扫描目录").accessibilityLabel("添加扫描目录")
            }.padding(.horizontal, 9).padding(.top, 12)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.snapshot.roots, id: \.self) { root in
                        Button {
                            model.rootFilter = model.rootFilter == root ? "" : root
                            model.navigate(.projects)
                        } label: {
                            HStack(spacing: 8) { Image(systemName: "folder"); Text(displayPath(root)).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0) }
                                .font(.system(size: 13)).padding(9).background(model.rootFilter == root ? Color(white: 0.88) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).help(root)
                    }
                }
            }
            Spacer(minLength: 0)
            sidebarItem(.settings)
        }.padding(.horizontal, 13).padding(.bottom, 14).frame(maxHeight: .infinity).background(AppTheme.sidebar)
    }
    private func sidebarItem(_ route: AppRoute) -> some View {
        Button { model.navigate(route) } label: {
            HStack(spacing: 10) {
                Image(systemName: route.symbol).frame(width: 20)
                Text(route.title)
                Spacer()
                if let count = count(for: route) { Text(String(count)).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppTheme.secondary) }
            }.padding(.horizontal, 9).frame(height: 38)
                .background(model.route == route ? Color(white: 0.88) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityIdentifier("navigation-\(route.rawValue)")
    }
    private func count(for route: AppRoute) -> Int? {
        switch route { case .projects: return model.snapshot.projects.count; case .versions: return model.snapshot.runtime.installed.count; case .tasks: let n = model.snapshot.runtime.tasks.filter { $0.state == "running" }.count; return n > 0 ? n : nil; case .settings: return nil }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button("gui-nvm") { model.navigate(.projects) }.buttonStyle(.plain).fontWeight(.semibold)
            Text("/").foregroundStyle(.tertiary); Text("本机").foregroundStyle(AppTheme.secondary)
            Text("/").foregroundStyle(.tertiary); Text(model.route.title)
            Spacer()
            Circle().fill(model.connectionError == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(model.loading ? "连接中" : model.connectionError == nil ? "nvm 已连接" : "读取失败").foregroundStyle(AppTheme.secondary)
            Text("默认 \(model.snapshot.runtime.defaultVersion.value.isEmpty ? "未设置" : model.snapshot.runtime.defaultVersion.value)").foregroundStyle(AppTheme.secondary).padding(.leading, 5)
        }.font(.system(size: 12)).padding(.horizontal, 22).frame(height: 43).overlay(alignment: .bottom) { Divider() }
    }
    private var footer: some View {
        HStack { Spacer(); Text("本机版本 \(model.snapshot.runtime.installed.count) · \(model.snapshot.projects.count) 个项目"); Text("|").foregroundStyle(.tertiary); Text(Date(), format: .dateTime.year().month().day()) }
            .font(.system(size: 11)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 20).frame(height: 32).overlay(alignment: .top) { Divider() }
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    var body: some View { HStack { Text(title).font(.system(size: 24, weight: .semibold)); Spacer(); actions() }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 22) }
}

struct InlineMessage: View {
    let text: String
    var isError = false
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.link) }
        }.font(.system(size: 12)).foregroundStyle(isError ? Color(red: 0.65, green: 0.22, blue: 0.14) : AppTheme.secondary)
            .padding(12).background(isError ? Color(red: 1, green: 0.96, blue: 0.94) : Color(white: 0.97))
    }
}

struct EmptyState: View {
    let title: String
    var symbol = "folder"
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(AppTheme.secondary)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.bordered) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

struct StatusBadge: View {
    let status: String
    var selected = false
    private var title: String { ["ready": "就绪", "missing": "未安装", "eol": "已停止支持", "unconfigured": "待配置", "invalid": "配置无效"][status] ?? status }
    private var color: Color { status == "ready" ? Color(red: 0.19, green: 0.43, blue: 0.28) : ["missing", "invalid"].contains(status) ? Color(red: 0.64, green: 0.35, blue: 0.10) : AppTheme.secondary }
    var body: some View { HStack(spacing: 6) { Circle().frame(width: 5, height: 5); Text(title) }.font(.system(size: 12)).modifier(SelectionForeground(selected: selected, unselected: color)) }
}

struct ConfirmationView: View {
    @ObservedObject var model: AppModel
    let confirmation: ActionConfirmation
    private var isInstall: Bool { confirmation.kind == .install }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(isInstall ? "安装 Node" : "设置默认版本").font(.system(size: 20, weight: .semibold))
            Text(confirmation.version).font(.system(size: 24, weight: .medium, design: .monospaced))
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow { Text("架构").foregroundStyle(AppTheme.secondary); Text(model.architecture) }
                GridRow { Text(isInstall ? "安装目录" : "配置文件").foregroundStyle(AppTheme.secondary); Text(displayPath(model.snapshot.nvmDir) + (isInstall ? "/versions/node/\(confirmation.version)" : "/alias/default")).font(AppTheme.mono).textSelection(.enabled) }
                if !confirmation.description.isEmpty { GridRow { Text("支持状态").foregroundStyle(AppTheme.secondary); Text(confirmation.description) } }
            }.font(.system(size: 13))
            HStack { Spacer(); Button("取消") { model.confirmation = nil }.keyboardShortcut(.cancelAction).disabled(model.busy); Button(model.busy ? "处理中…" : isInstall ? "安装" : "设为默认") { Task { await model.executeConfirmation(confirmation) } }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy).keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 520).interactiveDismissDisabled(model.busy)
    }
}
