import Foundation

/// Owns the native catalog of projects. Project files and Node installations remain shared with nvm.
public actor AppStore {
    private struct State: Codable {
        var schemaVersion = 1
        var nvmDir: String?
        var roots: [String] = []
        var projects: [String] = []
        var manualPaths: [String] = []
    }
    private struct Migration: Codable {
        var schemaVersion = 1
        var stateAttempted = false
        var cacheAttempted = false
    }
    private let dataDir: URL
    private let legacyDir: URL
    private let runtime: RuntimeService
    private let projectsService: ProjectService
    private var state = State()
    private var nvmDir: String
    private var notices: [String] = []
    private var scan = ScanState()
    private var scanTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var scanID: UUID?
    private var scanAgain = false
    private var closing = false
    private var initialized = false
    private var environmentChanging = false
    private var environmentRevision = 0

    public init(resourceURL: URL, dataDir: URL? = nil, legacyDir: URL? = nil, nvmDir: String? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = legacyDir ?? home.appendingPathComponent("Library/Application Support/gui-nvm", isDirectory: true)
        let native = URL(fileURLWithPath: try Self.canonicalLocation((dataDir ?? legacy.appendingPathComponent("native", isDirectory: true)).path))
        self.dataDir = native; self.legacyDir = legacy
        let supplied = nvmDir ?? ProcessInfo.processInfo.environment["NVM_DIR"] ?? home.appendingPathComponent(".nvm").path
        self.nvmDir = try Self.canonicalLocation(supplied)
        self.projectsService = try ProjectService(semver: Semver(resourceURL: resourceURL.appendingPathComponent("node-semver")))
        self.runtime = try RuntimeService(resourceURL: resourceURL, dataDir: native, nvmDir: self.nvmDir)
    }

    public func initialize(sync: Bool = true) async throws {
        guard !initialized else { return }
        try ensureOpen()
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let statePath = dataDir.appendingPathComponent("state.json").path
        if let contents = try SafeFile.read(statePath, limit: 32 * 1024 * 1024) {
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contents.utf8))
                guard state.schemaVersion == 1 else { throw AppError("不支持的状态版本") }
            } catch { throw AppError("原生应用状态无法读取：\(statePath)。原文件已保留。\(error.localizedDescription)") }
        }
        var migration = Migration()
        if let contents = try SafeFile.read(dataDir.appendingPathComponent("migration.json").path) {
            guard let decoded = try? JSONDecoder().decode(Migration.self, from: Data(contents.utf8)), decoded.schemaVersion == 1 else {
                throw AppError("迁移记录无法读取，已保留原文件，请检查 \(dataDir.path)/migration.json")
            }
            migration = decoded
        }
        if !migration.stateAttempted {
            if !FileManager.default.fileExists(atPath: statePath) {
                do {
                    if let contents = try SafeFile.read(legacyDir.appendingPathComponent("state.json").path) {
                        guard let old = try JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any] else { throw AppError("状态格式无效") }
                        state.roots = try legacyPaths(old["roots"], key: "roots")
                        state.projects = try legacyPaths(old["projects"], key: "projects")
                        state.manualPaths = try legacyPaths(old["manualPaths"], key: "manualPaths")
                    }
                } catch { notices.append("未导入旧项目清单：\(error.localizedDescription)"); state = State() }
            }
            migration.stateAttempted = true
        }
        if !migration.cacheAttempted {
            if !FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("releases.json").path) {
                do { try await runtime.importLegacyCache(from: legacyDir.appendingPathComponent("releases.json")) }
                catch { notices.append("未导入旧版本缓存：\(error.localizedDescription)") }
            }
            migration.cacheAttempted = true
        }
        state.roots = normalizedPaths(state.roots)
        state.projects = normalizedPaths(state.projects)
        state.manualPaths = normalizedPaths(state.manualPaths)
        try ensureOpen()
        if let saved = state.nvmDir, validAbsolutePath(saved) { nvmDir = try Self.canonicalLocation(saved) }
        try await runtime.setNVMDirectory(nvmDir)
        try ensureOpen()
        try await runtime.loadCache()
        try ensureOpen()
        try persist()
        try writeJSON(migration, to: dataDir.appendingPathComponent("migration.json"))
        initialized = true
        if !state.roots.isEmpty { startScan() }
        if sync { syncTask = Task { await self.runtime.syncCatalog() } }
    }

    public func snapshot() async throws -> AppSnapshot {
        guard !environmentChanging else { throw AppError("正在切换 nvm 目录") }
        let revision = environmentRevision
        let facts = try await runtime.snapshot()
        guard revision == environmentRevision, !environmentChanging else { throw AppError("nvm 目录已变化，请刷新") }
        var result = AppSnapshot()
        result.nvmDir = nvmDir; result.roots = state.roots; result.scan = scan; result.runtime = facts; result.notices = notices
        result.projects = try state.projects.map { try projectsService.record(path: $0, installed: facts.installed, nvmDir: nvmDir) }
        return result
    }

    public func addRoot(_ path: String) async throws {
        try ensureOpen()
        let canonical = try SafeFile.directory(path)
        if !state.roots.contains(canonical) { state.roots.append(canonical); try persist() }
        startScan()
    }

    @discardableResult public func addProject(_ path: String) async throws -> String {
        try ensureOpen()
        let canonical = try SafeFile.directory(path)
        var hasDeclaration = false
        for name in ["package.json", ".nvmrc", ".node-version"] {
            if try SafeFile.read(URL(fileURLWithPath: canonical).appendingPathComponent(name).path) != nil { hasDeclaration = true }
        }
        guard hasDeclaration else { throw AppError("目录中没有 Node 项目声明") }
        if !state.projects.contains(canonical) { state.projects.append(canonical) }
        if !state.manualPaths.contains(canonical) { state.manualPaths.append(canonical) }
        state.projects.sort(); try persist()
        return SafeFile.projectID(canonical)
    }

    public func startScan() {
        guard !closing else { return }
        if scanTask != nil { scanAgain = true; return }
        let id = UUID(); scanID = id
        scan = ScanState(); scan.state = "running"
        let roots = state.roots
        scanTask = Task {
            do {
                let result = try await ProjectScanner.discover(roots: roots, onProgress: { update in
                    Task { await self.scanProgress(update, id: id) }
                })
                try Task.checkCancellation()
                self.finishScan(result, id: id)
            } catch { self.failScan(error, id: id, cancelled: Task.isCancelled) }
        }
    }

    public func cancelScan() { scanAgain = false; scanTask?.cancel() }
    private func scanProgress(_ update: ScanState, id: UUID) {
        guard scanID == id, scan.state == "running" else { return }
        scan.visited = update.visited; scan.found = update.found; scan.errors = update.errors
    }
    private func finishScan(_ result: ScanResult, id: UUID) {
        guard scanID == id else { return }
        let manual = state.manualPaths.filter { (try? SafeFile.directory($0)) == $0 }
        state.projects = Array(Set(result.projects + manual)).sorted()
        scan.visited = result.visited; scan.found = result.projects.count; scan.errors = result.errors
        scan.state = result.limited ? "limited" : "complete"
        do { try persist() } catch { scan.state = "failed"; scan.error = error.localizedDescription }
        scanFinished()
    }
    private func failScan(_ error: Error, id: UUID, cancelled: Bool) {
        guard scanID == id else { return }
        scan.state = cancelled ? "cancelled" : "failed"; scan.error = cancelled ? nil : error.localizedDescription
        scanFinished()
    }
    private func scanFinished() {
        scanTask = nil; scanID = nil
        if scanAgain && !closing { scanAgain = false; startScan() }
    }

    public func preview(id: String, destination: String, requested: String) async throws -> ConfigPreview {
        try ensureOpen()
        guard !environmentChanging else { throw AppError("正在切换 nvm 目录") }
        let revision = environmentRevision
        guard let path = state.projects.first(where: { SafeFile.projectID($0) == id }) else { throw AppError("项目不存在，请重新扫描") }
        let facts = try await runtime.snapshot()
        try ensureOpen()
        guard revision == environmentRevision, !environmentChanging else { throw AppError("nvm 目录已变化，请重新预览") }
        let project = try projectsService.record(path: path, installed: facts.installed, nvmDir: nvmDir)
        return try projectsService.preview(project: project, destination: destination, requested: requested, installed: facts.installed, nvmDir: nvmDir)
    }

    public func save(_ preview: ConfigPreview) async throws {
        let current = try await self.preview(id: preview.projectID, destination: preview.destination, requested: preview.requested)
        guard current.file == preview.file, current.expected == preview.expected,
              current.resolved == preview.resolved, current.after == preview.after else { throw AppError("文件或目标版本已被外部修改，请重新预览") }
        try ensureOpen()
        try SafeFile.write(current.file, text: current.after, expected: preview.expected)
    }
    public func syncCatalog() async { if !closing { await runtime.syncCatalog() } }
    public func install(version: String) async throws -> String { try ensureOpen(); return try await runtime.install(version: version) }
    public func cancelInstall(id: String) async throws { try await runtime.cancel(id: id) }
    public func refreshGlobalPackages() async {
        guard !closing, !environmentChanging else { return }
        await runtime.refreshGlobalPackages()
    }
    public func previewGlobalPackageChange(packageID: String, action: GlobalPackageAction, targetVersion: String? = nil, allowScripts: Bool = false) async throws -> GlobalPackagePreview {
        try ensureOpen()
        let revision = environmentRevision
        let preview = try await runtime.previewGlobalPackageChange(packageID: packageID, action: action, targetVersion: targetVersion, allowScripts: allowScripts)
        try ensureOpen()
        guard revision == environmentRevision else { throw AppError("nvm 目录已变化，请重新预览") }
        return preview
    }
    public func applyGlobalPackageChange(_ preview: GlobalPackagePreview) async throws -> String {
        try ensureOpen()
        return try await runtime.applyGlobalPackageChange(preview)
    }
    public func setDefault(version: String, expected: String) async throws { try ensureOpen(); try await runtime.setDefault(version: version, expected: expected) }
    public func setNVMDirectory(_ path: String) async throws {
        try ensureOpen()
        guard !environmentChanging else { throw AppError("正在切换 nvm 目录") }
        let canonical = try SafeFile.directory(path)
        environmentChanging = true
        defer { environmentChanging = false }
        try await runtime.setNVMDirectory(canonical)
        guard !closing else { throw AppError("应用正在关闭") }
        nvmDir = canonical; state.nvmDir = canonical; environmentRevision += 1; try persist()
    }
    public func close() async {
        guard !closing else { return }
        closing = true; scanAgain = false
        let activeScan = scanTask
        activeScan?.cancel(); syncTask?.cancel()
        await runtime.close()
        await activeScan?.value
        await syncTask?.value
        syncTask = nil
    }
    private func ensureOpen() throws {
        if closing { throw AppError("应用正在关闭") }
        if environmentChanging { throw AppError("正在切换 nvm 目录") }
    }
    private func validAbsolutePath(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") }
    private func normalizedPaths(_ paths: [String]) -> [String] {
        Array(Set(paths.filter(validAbsolutePath).map { (try? SafeFile.directory($0)) ?? $0 })).sorted()
    }
    private static func canonicalLocation(_ path: String) throws -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { throw AppError("目录必须是绝对路径") }
        var cursor = URL(fileURLWithPath: expanded).standardizedFileURL.path
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: cursor) {
            guard cursor != "/", !cursor.isEmpty else { throw AppError("无法解析目录") }
            missing.insert((cursor as NSString).lastPathComponent, at: 0)
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        let canonical = try SafeFile.directory(cursor)
        return missing.reduce(canonical) { ($0 as NSString).appendingPathComponent($1) }
    }
    private func legacyPaths(_ value: Any?, key: String) throws -> [String] {
        guard let value else { return [] }
        guard let paths = value as? [String] else { throw AppError("\(key) 格式无效") }
        return Array(Set(paths.filter(validAbsolutePath))).sorted()
    }
    private func persist() throws { try writeJSON(state, to: dataDir.appendingPathComponent("state.json")) }
    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try SafeFile.write(url.path, text: String(decoding: data, as: UTF8.self) + "\n", limit: 32 * 1024 * 1024)
    }
}
