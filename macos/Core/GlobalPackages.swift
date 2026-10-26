import Foundation
import Darwin

public struct GlobalPackageCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String
    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.directory = directory
    }
}

/// Reads only the top-level packages inside the selected nvm prefixes. pnpm's
/// separate shared global store is deliberately not part of this inventory.
enum GlobalPackages {
    private static let manifestLimit = 1024 * 1024
    private static let maximumPackages = 10_000

    static func validName(_ name: String) -> Bool {
        name.utf8.count <= 214 && name.range(of: "^(?:@[A-Za-z0-9][A-Za-z0-9._-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*\\z", options: .regularExpression) != nil
    }

    static func prefix(nvmDir: String, version: String) throws -> String {
        guard version.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil, version.count <= 64 else {
            throw AppError("Node 版本号无效")
        }
        return (nvmDir as NSString).appendingPathComponent("versions/node/" + version)
    }

    static func scan(nvmDir: String, versions: [String], semver: Semver) -> GlobalPackageSnapshot {
        var result = GlobalPackageSnapshot()
        for version in versions {
            if Task.isCancelled { break }
            do {
                let root = try prefix(nvmDir: nvmDir, version: version) + "/lib/node_modules"
                guard try directoryIfPresent(root) != nil else { continue }
                let names = try FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasPrefix(".") }.sorted()
                for name in names {
                    if Task.isCancelled { return result }
                    if name.hasPrefix("@") {
                        let scope = root + "/" + name
                        do {
                            _ = try directory(scope)
                            for child in try FileManager.default.contentsOfDirectory(atPath: scope).filter({ !$0.hasPrefix(".") }).sorted() {
                                if Task.isCancelled { return result }
                                guard result.rows.count < maximumPackages else { throw AppError("全局包数量超过扫描上限") }
                                result.rows.append(record(nvmDir: nvmDir, version: version, name: name + "/" + child, semver: semver))
                            }
                        } catch { result.errors.append(ScanIssue(path: scope, code: error.localizedDescription)) }
                    } else {
                        guard result.rows.count < maximumPackages else { throw AppError("全局包数量超过扫描上限") }
                        result.rows.append(record(nvmDir: nvmDir, version: version, name: name, semver: semver))
                    }
                }
            } catch { result.errors.append(ScanIssue(path: (try? prefix(nvmDir: nvmDir, version: version)) ?? nvmDir, code: error.localizedDescription)) }
        }
        result.scannedAt = Date()
        return result
    }

    static func record(nvmDir: String, version: String, name: String, semver: Semver) -> GlobalPackageRecord {
        let path = ((try? prefix(nvmDir: nvmDir, version: version)) ?? nvmDir) + "/lib/node_modules/" + name
        var result = GlobalPackageRecord(nodeVersion: version, name: name, path: path)
        do {
            guard validName(name) else { throw AppError("包名格式不支持") }
            let package = try directory(path)
            let manifest = try readManifest(package)
            guard let value = try JSONSerialization.jsonObject(with: Data(manifest.text.utf8)) as? [String: Any],
                  let manifestName = value["name"] as? String, manifestName == name,
                  let packageVersion = value["version"] as? String, semver.isExactVersion(packageVersion) else {
                throw AppError("package.json 中的包名或版本无效")
            }
            result.version = packageVersion
            result.revision = SafeFile.digest(package.identity + "\n" + manifest.identity + "\n" + manifest.text)
            if ["npm", "corepack"].contains(name.lowercased()) { result.issue = "Node 自带工具链，暂不支持修改" }
            else {
                try checkRuntime(root: prefix(nvmDir: nvmDir, version: version))
                try checkOwnedLinks(value, packagePath: path, prefix: prefix(nvmDir: nvmDir, version: version))
                result.editable = true
            }
        } catch { result.issue = error.localizedDescription }
        return result
    }

    static func checkedRecord(_ record: GlobalPackageRecord, nvmDir: String, semver: Semver) throws -> GlobalPackageRecord {
        guard validName(record.name), record.path == (try prefix(nvmDir: nvmDir, version: record.nodeVersion)) + "/lib/node_modules/" + record.name else {
            throw AppError("全局包路径无效，请刷新")
        }
        let current = self.record(nvmDir: nvmDir, version: record.nodeVersion, name: record.name, semver: semver)
        guard current.editable else { throw AppError(current.issue ?? "此全局包不可修改") }
        guard !record.revision.isEmpty, current.revision == record.revision,
              current.version == record.version, current.path == record.path else {
            throw AppError("全局包已被外部修改，请刷新后重新确认")
        }
        return current
    }

    static func command(_ preview: GlobalPackagePreview, environment source: [String: String]) throws -> GlobalPackageCommand {
        let root = try prefix(nvmDir: preview.nvmDir, version: preview.package.nodeVersion)
        try checkRuntime(root: root)
        var environment = source.filter { key, _ in
            let key = key.lowercased().replacingOccurrences(of: "-", with: "_")
            return !["node_options", "node_path", "npm_config_prefix", "npm_config_global", "npm_config_location",
                     "npm_config_force", "npm_config_node_options", "npm_config_ignore_scripts", "npm_config_engine_strict"].contains(key)
        }
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = root + "/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        environment["NVM_DIR"] = preview.nvmDir
        environment["TERM"] = "dumb"; environment["NO_COLOR"] = "1"
        let scripts = preview.action == .changeVersion && preview.allowScripts
        var arguments = [root + "/lib/node_modules/npm/bin/npm-cli.js",
                         preview.action == .remove ? "uninstall" : "install",
                         "--global", "--prefix", root, "--location=global", "--force=false", "--engine-strict=true",
                         "--ignore-scripts=" + (scripts ? "false" : "true"), "--node-options=", "--no-audit", "--no-fund", "--"]
        arguments.append(preview.package.name + (preview.action == .changeVersion ? "@" + (preview.targetVersion ?? "") : ""))
        return GlobalPackageCommand(executable: root + "/bin/node", arguments: arguments, environment: environment, directory: root)
    }

    static func packageExists(_ preview: GlobalPackagePreview) throws -> Bool {
        // npm may also remove the empty @scope after its final package. The
        // selected Node prefix must still exist, but missing descendants mean
        // the package was removed successfully.
        _ = try directory(prefix(nvmDir: preview.nvmDir, version: preview.package.nodeVersion))
        guard let parent = try directoryIfPresent((preview.package.path as NSString).deletingLastPathComponent) else { return false }
        var info = stat()
        if fstatat(parent.fd, (preview.package.path as NSString).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw AppError("无法验证全局包操作结果，请刷新")
    }

    private final class Directory {
        let fd: Int32
        let identity: String
        init(_ fd: Int32, _ identity: String) { self.fd = fd; self.identity = identity }
        deinit { Darwin.close(fd) }
    }

    private struct MissingDirectory: LocalizedError {
        var errorDescription: String? { "包或目录已不存在，请刷新" }
    }

    /// Walk with openat so neither a symlink in an ancestor nor a package link
    /// can redirect a manifest read to another user's/project's directory.
    private static func directory(_ path: String) throws -> Directory {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw AppError("全局包目录无效") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppError("无法访问全局包目录") }
        var identity = ""
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            Darwin.close(fd)
            guard next >= 0 else {
                if code == ELOOP || code == ENOTDIR { throw AppError("链接包或目录含符号链接，仅供查看") }
                if code == ENOENT { throw MissingDirectory() }
                throw AppError("无法读取全局包目录：\(String(cString: strerror(code)))")
            }
            fd = next
            var info = stat()
            guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw AppError("无法检查全局包目录") }
            identity += "\(info.st_dev):\(info.st_ino)/"
        }
        return Directory(fd, identity)
    }

    private static func directoryIfPresent(_ path: String) throws -> Directory? {
        // Missing lib/node_modules is a valid empty Node installation. A present
        // symlink is not treated as an empty directory.
        do { return try directory(path) }
        catch is MissingDirectory { return nil }
    }

    private static func checkRuntime(root: String) throws {
        do {
            let bin = try directory(root + "/bin")
            try regularFile("node", in: bin, executable: true)
            let npm = try directory(root + "/lib/node_modules/npm/bin")
            try regularFile("npm-cli.js", in: npm)
        } catch { throw AppError("目标 Node 或 npm 不可用、缺失或包含链接，不能修改全局包") }
    }

    /// npm removes the bin/man paths named by the old manifest without checking
    /// who currently owns those links. Refuse the operation when another package
    /// (including Corepack) has since taken over one of those commands.
    private static func checkOwnedLinks(_ manifest: [String: Any], packagePath: String, prefix: String) throws {
        var bins: [String] = []
        if let bin = manifest["bin"] as? String, !bin.isEmpty {
            bins = [manifest["name"] as? String ?? ""]
        } else if let bin = manifest["bin"] as? [String: Any] {
            bins = bin.compactMap { $0.value is String ? $0.key : nil }
        } else if let bin = manifest["bin"] as? [String] { bins = bin }
        for name in Set(bins) {
            // Match npm-normalize-package-bin's basename normalization; inputs
            // are manifest data and never become a shell command or raw path.
            let normalized = name.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: ":", with: "/")
            let base = (normalized as NSString).lastPathComponent
            guard !base.isEmpty, base != ".", base != "..", !base.contains("\0") else { throw AppError("全局包 bin 配置无效") }
            try checkOwnedLink(parent: prefix + "/bin", name: base, packagePath: packagePath)
        }
        let manuals: [String]
        if let man = manifest["man"] as? String { manuals = [man] }
        else { manuals = manifest["man"] as? [String] ?? [] }
        for man in manuals {
            let base = (man as NSString).lastPathComponent
            guard base.range(of: "^.+\\.[0-9]+(?:\\.gz)?\\z", options: .regularExpression) != nil, !base.contains("\0") else {
                throw AppError("全局包 man 配置无效")
            }
            let uncompressed = base.hasSuffix(".gz") ? String(base.dropLast(3)) : base
            let section = (uncompressed as NSString).pathExtension
            try checkOwnedLink(parent: prefix + "/share/man/man" + section, name: base, packagePath: packagePath)
        }
    }

    private static func checkOwnedLink(parent: String, name: String, packagePath: String) throws {
        guard let directory = try directoryIfPresent(parent) else { return }
        var info = stat()
        if fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw AppError("无法检查全局命令或手册：\(name)")
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK else { throw AppError("命令或手册冲突：\(name) 不是本包链接") }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = bytes.withUnsafeMutableBytes { buffer in
            readlinkat(directory.fd, name, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), buffer.count)
        }
        guard count > 0, count < bytes.count else { throw AppError("无法检查全局命令或手册链接：\(name)") }
        let link = String(decoding: bytes.prefix(count), as: UTF8.self)
        let destination = link.hasPrefix("/") ? link : parent + "/" + link
        var components: [String] = []
        for component in destination.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(String(component)) }
        }
        guard ("/" + components.joined(separator: "/")).hasPrefix(packagePath + "/") else {
            throw AppError("命令或手册冲突：\(name) 当前属于其他包，请先处理冲突")
        }
    }

    private static func regularFile(_ name: String, in parent: Directory, executable: Bool = false) throws {
        var info = stat()
        guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, !executable || info.st_mode & 0o111 != 0 else {
            throw AppError("目标 Node 或 npm 不可用，不能执行全局包操作")
        }
    }

    private static func readManifest(_ directory: Directory) throws -> (text: String, identity: String) {
        let fd = openat(directory.fd, "package.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AppError("package.json 缺失、不可读或是符号链接") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= manifestLimit else {
            throw AppError("package.json 类型或大小不受支持")
        }
        var bytes = [UInt8](repeating: 0, count: manifestLimit + 1)
        var count = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while count < buffer.count {
                let size = Darwin.read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if size < 0 && errno == EINTR { continue }
                guard size >= 0 else { throw AppError("无法读取 package.json") }
                if size == 0 { break }
                count += size
            }
        }
        guard count <= manifestLimit else { throw AppError("package.json 超过大小限制") }
        return (String(decoding: bytes.prefix(count), as: UTF8.self), "\(info.st_dev):\(info.st_ino)")
    }
}

/// npm output can include registry credentials. Only expose complete, filtered
/// lines so a secret split between process output chunks is never published.
final class PackageLogFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var droppingLine = false
    private let secrets: [String]

    init(environment: [String: String], prefix: String) {
        var values = environment.filter { key, value in
            !value.isEmpty && key.range(of: "token|password|passwd|secret|auth", options: [.regularExpression, .caseInsensitive]) != nil
        }.map(\.value)
        let config = environment.first { $0.key.lowercased() == "npm_config_userconfig" }?.value
        let global = environment.first { $0.key.lowercased() == "npm_config_globalconfig" }?.value
        for path in [config ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npmrc").path, global ?? prefix + "/etc/npmrc"] {
            guard let text = try? SafeFile.read(path, limit: 1024 * 1024) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, pair[0].range(of: "_auth|password|token", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("${") { values.append(value) }
            }
        }
        secrets = Array(Set(values)).sorted { $0.count > $1.count }
    }

    func append(_ chunk: String, finish: Bool = false) -> String {
        lock.lock(); defer { lock.unlock() }
        pending += chunk
        var output = ""
        while let end = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            if !droppingLine { output += clean(line) + "\n" }
            droppingLine = false
        }
        if pending.count > 16_000 { pending = ""; droppingLine = true; output += "[过长日志行已省略]\n" }
        if finish {
            if !droppingLine { output += clean(pending) }
            pending = ""; droppingLine = false
        }
        return output
    }

    func redact(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return clean(text)
    }

    private func clean(_ text: String) -> String {
        var result = text
        for value in secrets { result = result.replacingOccurrences(of: value, with: "[REDACTED]") }
        result = result.replacingOccurrences(of: "(?i)(https?://)[^\\s/@]+(?::[^\\s/@]*)?@", with: "$1[REDACTED]@", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)((?:_authToken|_auth|_password|password|token|authorization)\\s*[:=]\\s*)[^\\r\\n]+", with: "$1[REDACTED]", options: .regularExpression)
        return result
    }
}
