import Foundation
import Darwin

public actor RuntimeService {
    public typealias Fetcher = @Sendable () async throws -> Data
    public typealias Installer = @Sendable (_ version: String, _ staging: URL, _ log: @escaping @Sendable (String) -> Void) async throws -> Void
    private struct Schedule: Decodable { var end: String; var lts: String?; var maintenance: String?; var codename: String? }
    private let resourceURL: URL
    private let dataDir: URL
    private var nvmDir: String
    private let fetcher: Fetcher
    private let installer: Installer?
    private let schedule: [String: Schedule]
    private var catalog: [NodeRelease] = []
    private var catalogAt: String?
    private var catalogError: String?
    private var tasks: [InstallTask] = []
    private var activeID: String?
    private var active: Task<Void, Never>?
    private var syncOperation: Task<Void, Never>?
    private var closed = false

    public init(resourceURL: URL, dataDir: URL, nvmDir: String,
                fetcher: @escaping Fetcher = { try await Network.fetchIndex() }, installer: Installer? = nil) throws {
        self.resourceURL = resourceURL
        self.dataDir = URL(fileURLWithPath: try Self.normalizedDirectory(dataDir.path))
        self.nvmDir = try Self.normalizedDirectory(nvmDir)
        self.fetcher = fetcher; self.installer = installer
        guard let text = try SafeFile.read(resourceURL.appendingPathComponent("release-schedule.json").path) else { throw AppError("缺少 Node 支持周期资源") }
        self.schedule = try JSONDecoder().decode([String: Schedule].self, from: Data(text.utf8))
    }

    public func loadCache() throws {
        do {
            guard let text = try SafeFile.read(dataDir.appendingPathComponent("releases.json").path, limit: 8 * 1024 * 1024) else { return }
            try adoptCache(Data(text.utf8))
        } catch {
            catalogError = "版本缓存无效或无法读取，请重新同步：\(error.localizedDescription)"
        }
    }

    /// Reads the previous application's cache without changing that source.
    public func importLegacyCache(from url: URL) throws {
        guard catalog.isEmpty else { return }
        guard let text = try SafeFile.read(url.path, limit: 8 * 1024 * 1024) else { return }
        try adoptCache(Data(text.utf8))
        try persistCache()
    }

    private func adoptCache(_ data: Data) throws {
        guard let cache = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = cache["rows"] as? [[String: Any]] else { throw AppError("版本缓存格式无效") }
        let validated = try validateCatalog(rows)
        catalog = validated
        catalogAt = cache["at"] as? String
    }

    private func validateCatalog(_ rows: [[String: Any]]) throws -> [NodeRelease] {
        guard !rows.isEmpty, rows.count <= 10000 else { throw AppError("版本索引格式无效") }
        let result = rows.compactMap { row -> NodeRelease? in
            guard let version = row["version"] as? String, Self.validVersion(version),
                  let date = row["date"] as? String, date.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil,
                  let files = row["files"] as? [Any] else { return nil }
            return NodeRelease(version: version, date: date, files: files.compactMap { $0 as? String })
        }.sorted { Self.newer($0.version, $1.version) }
        guard !result.isEmpty else { throw AppError("版本索引为空") }
        return result
    }

    public func syncCatalog() async {
        if let syncOperation { await syncOperation.value; return }
        guard !closed else { return }
        let operation = Task { await self.performSync() }
        syncOperation = operation
        await operation.value
        syncOperation = nil
    }

    private func performSync() async {
        do {
            let data = try await fetcher()
            try Task.checkCancellation()
            guard data.count <= 8 * 1024 * 1024 else { throw AppError("版本索引过大") }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AppError("版本索引格式无效") }
            let next = try validateCatalog(rows)
            catalog = next; catalogAt = ISO8601DateFormatter().string(from: Date()); catalogError = nil
            try persistCache()
        } catch {
            if !Task.isCancelled { catalogError = "同步失败：\(error.localizedDescription)" }
        }
    }

    private func persistCache() throws {
        try Self.ensureDirectory(dataDir.path)
        let rows: [[String: Any]] = catalog.map { ["version": $0.version, "date": $0.date, "files": $0.files, "lts": false] }
        let value: [String: Any] = ["rows": rows, "at": catalogAt ?? ""]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try SafeFile.write(dataDir.appendingPathComponent("releases.json").path, text: String(decoding: data, as: UTF8.self), limit: 8 * 1024 * 1024)
    }

    public func snapshot() throws -> RuntimeSnapshot {
        let installed = try installedVersions()
        let versions = Set(installed.map(\.version))
        var result = RuntimeSnapshot()
        result.installed = installed
        result.releases = catalog.map {
            var release = phase($0)
            release.installed = versions.contains(release.version)
            release.compatible = release.files.contains(Self.architectureFile)
            return release
        }
        let text = try SafeFile.read(URL(fileURLWithPath: nvmDir).appendingPathComponent("alias/default").path, limit: 8192)
        result.defaultVersion = DefaultVersion(value: text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", expected: SafeFile.digest(text))
        result.tasks = tasks; result.catalogAt = catalogAt; result.catalogError = catalogError
        result.syncing = syncOperation != nil
        return result
    }

    private func installedVersions() throws -> [NodeRelease] {
        let parent = URL(fileURLWithPath: nvmDir).appendingPathComponent("versions/node")
        for path in [nvmDir, URL(fileURLWithPath: nvmDir).appendingPathComponent("versions").path] {
            var parentInfo = stat()
            if lstat(path, &parentInfo) == 0 && (parentInfo.st_mode & S_IFMT) != S_IFDIR {
                throw AppError("nvm 路径包含符号链接或不是目录")
            }
        }
        var info = stat()
        if lstat(parent.path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw AppError("无法读取已安装版本目录")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AppError("Node 版本目录不是普通目录") }
        let entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        return entries.compactMap { entry in
            guard Self.validVersion(entry.lastPathComponent), Self.isDirectory(entry.path),
                  Self.isExecutableFile(entry.appendingPathComponent("bin/node").path) else { return nil }
            var release = phase(NodeRelease(version: entry.lastPathComponent))
            release.installed = true
            return release
        }.sorted { Self.newer($0.version, $1.version) }
    }

    private func phase(_ release: NodeRelease) -> NodeRelease {
        var result = release
        let major = release.version.dropFirst().split(separator: ".").first.map(String.init) ?? ""
        guard let entry = schedule["v" + major] else { return result }
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        result.phase = today >= entry.end ? "EOL" : entry.maintenance.map { today >= $0 } == true ? "Maintenance LTS" : entry.lts.map { today >= $0 } == true ? "LTS" : "Current"
        result.description = ["EOL": "已停止支持", "Maintenance LTS": "维护期", "LTS": "长期支持", "Current": "新特性 · 非 LTS"][result.phase] ?? "支持状态待同步"
        result.codename = entry.codename ?? ""; result.supportEnd = entry.end
        result.lts = entry.lts.map { today >= $0 } ?? false
        return result
    }

    public func install(version: String) async throws -> String {
        guard !closed else { throw AppError("应用正在关闭") }
        guard Self.validVersion(version) else { throw AppError("版本号无效") }
        guard activeID == nil else { throw AppError("已有安装任务正在运行") }
        guard !(try installedVersions()).contains(where: { $0.version == version }) else { throw AppError("此版本已安装") }
        guard catalog.contains(where: { $0.version == version && $0.files.contains(Self.architectureFile) }) else { throw AppError("此版本没有适用本机架构的官方二进制包") }
        let task = InstallTask(version: version)
        tasks.insert(task, at: 0); tasks = Array(tasks.prefix(30)); activeID = task.id
        let operation = Task { await self.runInstall(id: task.id, version: version) }
        active = operation
        return task.id
    }

    private func runInstall(id: String, version: String) async {
        var staging: URL?
        do {
            try Task.checkCancellation()
            try Self.ensureDirectory(nvmDir)
            let work = URL(fileURLWithPath: nvmDir).appendingPathComponent(".gui-nvm-install-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            staging = work
            let log: @Sendable (String) -> Void = { chunk in Task { await self.appendLog(id, chunk) } }
            if let installer { try await installer(version, work, log) }
            else {
                var env = await Network.environment()
                try Task.checkCancellation()
                env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
                env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
                env["NVM_DIR"] = work.path; env["TERM"] = "dumb"; env["NVM_NO_COLORS"] = "1"
                let response = try await ProcessRunner.run("/bin/bash", arguments: ["--noprofile", "--norc", "-c",
                    "curl() { /usr/bin/curl -q --http1.1 \"$@\"; }; . \"$1\" --no-use; nvm install -b --skip-default-packages --no-progress \"$2\"", "gui-nvm-install",
                    resourceURL.appendingPathComponent("nvm.sh").path, version
                ], environment: env, directory: work.path, timeout: 30 * 60, outputLimit: 8 * 1024 * 1024, onOutput: log)
                guard response.status == 0 else { throw AppError("安装失败，请查看任务日志") }
            }
            try Task.checkCancellation()
            update(id) { $0.phase = "校验安装结果" }
            let source = work.appendingPathComponent("versions/node/" + version)
            guard Self.isDirectory(work.appendingPathComponent("versions").path),
                  Self.isDirectory(work.appendingPathComponent("versions/node").path),
                  Self.isDirectory(source.path), Self.isDirectory(source.appendingPathComponent("bin").path),
                  Self.isExecutableFile(source.appendingPathComponent("bin/node").path) else { throw AppError("安装结果校验失败") }
            let checked = try await ProcessRunner.run(source.appendingPathComponent("bin/node").path, arguments: ["--version"],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 10, outputLimit: 8192)
            guard checked.status == 0, checked.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == version else { throw AppError("Node 二进制版本校验失败") }
            try Task.checkCancellation()
            let parent = URL(fileURLWithPath: nvmDir).appendingPathComponent("versions/node")
            try Self.ensureDirectory(parent.path)
            let target = parent.appendingPathComponent(version)
            guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST || errno == ENOTEMPTY { throw AppError("目标版本已被其他进程安装，请刷新") }
                throw AppError("发布安装结果失败：\(String(cString: strerror(errno)))")
            }
            update(id) { $0.state = "complete"; $0.phase = "安装完成" }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let message = cancelled ? "安装已取消" : error.localizedDescription
            update(id) { $0.state = cancelled ? "cancelled" : "failed"; $0.error = message; $0.phase = message }
        }
        if let staging {
            do { try FileManager.default.removeItem(at: staging) }
            catch { appendLog(id, "\n临时目录清理失败：\(error.localizedDescription)") }
        }
        update(id) { $0.endedAt = Date() }
        if activeID == id { activeID = nil; active = nil }
    }

    public func cancel(id: String) throws {
        guard activeID == id, let active else { throw AppError("任务未在运行") }
        active.cancel()
        update(id) { $0.phase = "正在取消" }
    }

    public func setDefault(version: String, expected: String) throws {
        guard !closed else { throw AppError("应用正在关闭") }
        guard try installedVersions().contains(where: { $0.version == version }) else { throw AppError("只能选择已安装的 Node 版本") }
        let alias = URL(fileURLWithPath: nvmDir).appendingPathComponent("alias")
        try Self.ensureDirectory(alias.path)
        try SafeFile.write(alias.appendingPathComponent("default").path, text: version + "\n", expected: expected)
    }

    public func setNVMDirectory(_ path: String) throws {
        guard !closed else { throw AppError("应用正在关闭") }
        guard activeID == nil else { throw AppError("安装期间不能修改 nvm 目录") }
        nvmDir = try Self.normalizedDirectory(path)
    }

    public func close() async {
        closed = true
        let sync = syncOperation, install = active
        sync?.cancel(); install?.cancel()
        await sync?.value; await install?.value
    }

    private func update(_ id: String, _ change: (inout InstallTask) -> Void) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { change(&tasks[index]) }
    }
    private func appendLog(_ id: String, _ chunk: String) {
        let clean = chunk.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        update(id) { $0.log = String(($0.log + clean).suffix(16000)) }
    }
    private static var architectureFile: String {
        #if arch(arm64)
        return "osx-arm64-tar"
        #else
        return "osx-x64-tar"
        #endif
    }
    private static func validVersion(_ value: String) -> Bool {
        value.count <= 64 && value.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    }
    private static func newer(_ a: String, _ b: String) -> Bool {
        let x = a.dropFirst().split(separator: ".").map { UInt64($0) ?? 0 }
        let y = b.dropFirst().split(separator: ".").map { UInt64($0) ?? 0 }
        return y.lexicographicallyPrecedes(x)
    }
    private static func normalizedDirectory(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else { throw AppError("nvm 目录无效") }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded != "/" else { throw AppError("请选择有效的 nvm 目录") }
        // Foundation standardization may turn /private/var back into /var.
        // Resolve the existing ancestor with POSIX realpath, then append only
        // the missing path components without applying Foundation normalization.
        var parts: [String] = []
        for part in expanded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(String(part)) }
        }
        guard !parts.isEmpty else { throw AppError("请选择有效的 nvm 目录") }
        var candidate = "/" + parts.joined(separator: "/")
        var missing: [String] = []
        while true {
            if let pointer = realpath(candidate, nil) {
                defer { free(pointer) }
                let base = String(cString: pointer)
                guard isDirectory(base) else { throw AppError("请选择目录：\(candidate)") }
                return missing.isEmpty ? base : (base == "/" ? "" : base) + "/" + missing.joined(separator: "/")
            }
            let code = errno
            guard code == ENOENT, candidate != "/" else { throw AppError("无法访问目录：\(candidate)") }
            let component = (candidate as NSString).lastPathComponent
            missing.insert(component, at: 0)
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate.isEmpty { candidate = "/" }
        }
    }
    private static func isDirectory(_ path: String) -> Bool {
        var info = stat(); return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
    private static func isExecutableFile(_ path: String) -> Bool {
        var info = stat(); return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_mode & 0o111 != 0
    }
    private static func ensureDirectory(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw AppError("目录必须是绝对路径") }
        // URL("/").deletingLastPathComponent().path can be empty. Passing that
        // back to URL(fileURLWithPath:) resolves the working directory and loops.
        if path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { throw AppError("目录路径无效") }
            try ensureDirectory(parent)
        }
        var info = stat()
        let result = lstat(path, &info)
        let code = errno
        if result == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AppError("目录不可写或包含符号链接：\(path)") }
            return
        }
        guard code == ENOENT else { throw AppError("无法访问目录：\(path)") }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
}
