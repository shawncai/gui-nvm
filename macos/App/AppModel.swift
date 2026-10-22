import AppKit
import SwiftUI
import GUINVMCore

enum AppRoute: String, CaseIterable, Identifiable {
    case projects, versions, tasks, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .projects: return "项目"; case .versions: return "Node 版本"; case .tasks: return "安装任务"; case .settings: return "设置" }
    }
    var symbol: String {
        switch self { case .projects: return "doc.text"; case .versions: return "hexagon"; case .tasks: return "arrow.down.circle"; case .settings: return "gearshape" }
    }
}

struct ActionConfirmation: Identifiable {
    enum Kind { case install, defaultVersion }
    let id = UUID()
    let kind: Kind
    let version: String
    let description: String
    let expected: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var snapshot = AppSnapshot()
    @Published var route: AppRoute = .projects
    @Published var selectedProjectID: String?
    @Published var search = ""
    @Published var projectFilter = "all"
    @Published var rootFilter = ""
    @Published var focusSearchRevision = 0
    @Published var loading = true
    @Published var connectionError: String?
    @Published var operationError: String?
    @Published var toast: String?
    @Published var busy = false
    @Published var catalogSyncRequested = false
    @Published var confirmation: ActionConfirmation?
    @Published var dismissedNotices = Set<String>()
    private(set) var store: AppStore?
    private var initialized = false
    private var refreshing = false
    private var shuttingDown = false
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    var selectedProject: ProjectRecord? { snapshot.projects.first { $0.id == selectedProjectID } }
    var visibleProjects: [ProjectRecord] {
        snapshot.projects.filter { project in
            let matchesText = search.isEmpty || "\(project.name) \(project.path) \(project.requested)".localizedCaseInsensitiveContains(search)
            let matchesStatus = projectFilter == "all" || (projectFilter == "attention" ? ["eol", "invalid"].contains(project.status) : project.status == projectFilter)
            let matchesRoot = rootFilter.isEmpty || project.path == rootFilter || project.path.hasPrefix(rootFilter + "/")
            return matchesText && matchesStatus && matchesRoot
        }
    }
    var notices: [String] { snapshot.notices.filter { !dismissedNotices.contains($0) } }
    var hasRunningInstall: Bool { snapshot.runtime.tasks.contains { $0.state == "running" } }
    var architecture: String {
        #if arch(arm64)
        return "macOS · arm64"
        #else
        return "macOS · x64"
        #endif
    }

    func initialize() async {
        guard !initialized, !shuttingDown else { return }
        initialized = true
        do {
            let environment = ProcessInfo.processInfo.environment
            let directory: (String) -> URL? = { name in
                guard let value = environment[name], !value.isEmpty else { return nil }
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            let service = try AppStore(resourceURL: Bundle.main.resourceURL!, dataDir: directory("GUI_NVM_DATA_DIR"), legacyDir: directory("GUI_NVM_LEGACY_DIR"), nvmDir: environment["GUI_NVM_NVM_DIR"])
            store = service
            try await service.initialize(sync: environment["GUI_NVM_NO_SYNC"] != "1")
            guard !shuttingDown else { await service.close(); return }
            await refresh()
        } catch {
            await store?.close(); store = nil; initialized = false
            connectionError = error.localizedDescription
        }
        guard !shuttingDown else { return }
        loading = false
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                guard let self else { return }
                if NSApplication.shared.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) { await self.refresh() }
            }
        }
    }

    func refresh() async {
        guard !refreshing, !shuttingDown, let store else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            snapshot = try await store.snapshot()
            connectionError = nil
            if let selectedProjectID, !snapshot.projects.contains(where: { $0.id == selectedProjectID }) { self.selectedProjectID = nil }
        } catch { connectionError = error.localizedDescription }
    }

    func retry() async {
        if store == nil { initialized = false; refreshTask?.cancel(); await initialize() }
        else { await refresh() }
    }

    func navigate(_ route: AppRoute) { self.route = route; search = "" }
    func focusSearch() {
        if route != .projects && route != .versions { navigate(.projects) }
        focusSearchRevision += 1
    }
    func notify(_ text: String) {
        toastTask?.cancel(); toast = text
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4.5)) } catch { return }
            self?.toast = nil
        }
    }
    func perform(_ success: String? = nil, operation: () async throws -> Void) async -> Bool {
        guard !shuttingDown else { return false }
        busy = true
        defer { busy = false }
        do {
            try await operation()
            await refresh()
            if let success { notify(success) }
            return true
        } catch { operationError = error.localizedDescription; return false }
    }
    func chooseDirectory(for purpose: String) {
        guard !shuttingDown else { return }
        let panel = NSOpenPanel()
        panel.title = purpose == "root" ? "添加扫描目录" : purpose == "nvm" ? "选择 nvm 安装目录" : "添加项目"
        panel.prompt = purpose == "root" ? "扫描此目录" : purpose == "nvm" ? "使用此目录" : "添加此项目"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = purpose == "nvm"
        panel.showsHiddenFiles = purpose == "nvm"
        if purpose == "nvm", !snapshot.nvmDir.isEmpty { panel.directoryURL = URL(fileURLWithPath: snapshot.nvmDir) }
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        Task {
            _ = await perform(purpose == "root" ? "扫描目录已添加" : purpose == "nvm" ? "nvm 目录已更新" : "项目已添加") {
                if purpose == "root" { try await store.addRoot(url.path); self.navigate(.projects) }
                else if purpose == "nvm" { try await store.setNVMDirectory(url.path) }
                else { self.selectedProjectID = try await store.addProject(url.path); self.navigate(.projects) }
            }
        }
    }
    func toggleScan() {
        guard let store, !shuttingDown else { return }
        Task {
            if snapshot.scan.state == "running" { await store.cancelScan() }
            else { await store.startScan() }
            await refresh()
        }
    }
    func syncCatalog() {
        guard let store, !catalogSyncRequested, !shuttingDown else { return }
        catalogSyncRequested = true
        Task { await store.syncCatalog(); await refresh(); catalogSyncRequested = false; if snapshot.runtime.catalogError == nil { notify("版本库已同步") } }
    }
    func confirmInstall(_ release: NodeRelease) {
        confirmation = ActionConfirmation(kind: .install, version: release.version, description: release.description, expected: "")
    }
    func confirmDefault(_ version: String) {
        confirmation = ActionConfirmation(kind: .defaultVersion, version: version, description: "", expected: snapshot.runtime.defaultVersion.expected)
    }
    func executeConfirmation(_ item: ActionConfirmation) async {
        guard let store else { return }
        let succeeded = await perform(item.kind == .install ? "安装任务已创建" : "默认版本已更新") {
            if item.kind == .install { _ = try await store.install(version: item.version) }
            else { try await store.setDefault(version: item.version, expected: item.expected) }
        }
        if succeeded {
            confirmation = nil
            if item.kind == .install { navigate(.tasks) }
        }
    }
    func cancelInstall(_ task: InstallTask) {
        guard let store else { return }
        Task { _ = await perform { try await store.cancelInstall(id: task.id) } }
    }
    func reveal(_ project: ProjectRecord) {
        do {
            guard try SafeFile.directory(project.path) == project.path else { throw AppError("项目目录已变化，请重新扫描") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path, isDirectory: true)])
        } catch { operationError = error.localizedDescription }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notify("路径已复制") }
    func shutdown() async { shuttingDown = true; refreshTask?.cancel(); toastTask?.cancel(); await store?.close(); store = nil }
}

func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
func shortVersion(_ value: String) -> String { value.hasPrefix("v") ? String(value.dropFirst()) : value }
func phaseLabel(_ release: NodeRelease) -> String { release.phase == "Maintenance LTS" ? "LTS" : release.phase }
