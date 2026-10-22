import Foundation

public final class ProjectService: Sendable {
    private let semver: Semver
    private static let declarationNames = [".nvmrc", ".node-version", "package.json"]

    public init(semver: Semver) { self.semver = semver }

    public func record(path: String, installed: [NodeRelease], nvmDir: String) throws -> ProjectRecord {
        var result = ProjectRecord(id: SafeFile.projectID(path), name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        if let text = try? SafeFile.read((path as NSString).appendingPathComponent("package.json")),
           let data = text.data(using: .utf8),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = manifest["name"] as? String, name.utf16.count < 120 {
            result.name = name
        }
        var fingerprints: [String] = []
        do {
            guard try SafeFile.directory(path) == path else { throw AppError("项目路径已变化，请重新扫描") }
            let declaration = try findDeclaration(path: path, fingerprints: &fingerprints)
            if let declaration {
                let resolved = try resolve(declaration.requested, installed: installed, nvmDir: nvmDir)
                result.requested = declaration.requested
                result.resolved = resolved
                result.source = declaration.source
                result.file = declaration.file
                result.inherited = declaration.inherited
                result.status = resolved == nil ? "missing" : installed.first(where: { $0.version == resolved })?.phase == "EOL" ? "eol" : "ready"
                fingerprints.append("resolved:\(resolved ?? "<missing>")")
            }
        } catch {
            result.status = "invalid"
            result.error = error.localizedDescription
            fingerprints.append("error:\(error.localizedDescription)")
        }
        result.revision = SafeFile.digest(fingerprints.joined(separator: "\n"))
        return result
    }

    public func preview(project: ProjectRecord, destination: String, requested input: String, installed: [NodeRelease], nvmDir: String) throws -> ConfigPreview {
        guard Self.declarationNames.contains(destination) else { throw AppError("不支持的声明文件") }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.utf16.count <= 4096,
              !Self.hasUnsafeCharacters(input) else { throw AppError("版本值无效") }
        let requested = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if destination == "package.json" {
            guard semver.validRange(requested) != nil else { throw AppError("engines.node 需要有效的版本范围") }
        } else {
            guard requested.range(of: "^(v?[0-9]+(?:\\.[0-9]+){0,2}|lts/(?:\\*|[a-z]+)|[a-z][a-z0-9_-]*)$", options: [.regularExpression, .caseInsensitive]) != nil else {
                throw AppError("此文件只接受版本号或 nvm 别名")
            }
        }
        guard let resolved = try resolve(requested, installed: installed, nvmDir: nvmDir), resolved != "system" else {
            throw AppError("目标版本尚未安装，请先到 Node 版本库安装")
        }
        guard try SafeFile.directory(project.path) == project.path else { throw AppError("项目路径已变化，请重新扫描") }
        let file = (project.path as NSString).appendingPathComponent(destination)
        let before = try SafeFile.read(file)
        let after: String
        if destination == "package.json" {
            guard let before else { throw AppError("项目没有 package.json") }
            after = try semver.rewriteManifest(before, requested: requested)
        } else { after = requested + "\n" }
        guard Data(after.utf8).count <= 1_048_576 else {
            throw AppError("生成的 \(destination) 超过 1 MiB，无法保存；请先缩小文件")
        }
        let shadowing = destination == "package.json" ? [".nvmrc", ".node-version"] : destination == ".node-version" ? [".nvmrc"] : []
        for name in shadowing where try SafeFile.read((project.path as NSString).appendingPathComponent(name), limit: 8192) != nil {
            throw AppError("\(name) 的优先级更高，请修改该文件")
        }
        return ConfigPreview(projectID: project.id, file: file, before: before, after: after, expected: SafeFile.digest(before), resolved: resolved, requested: requested, destination: destination)
    }

    private struct Declaration {
        let requested: String
        let source: String
        let file: String
        let inherited: Bool
    }

    private func findDeclaration(path: String, fingerprints: inout [String]) throws -> Declaration? {
        var directory = path
        while true {
            for name in Self.declarationNames {
                let file = (directory as NSString).appendingPathComponent(name)
                let text: String?
                do { text = try SafeFile.read(file, limit: name == "package.json" ? 1_048_576 : 8192) }
                catch { fingerprints.append(file + ":error:" + error.localizedDescription); throw error }
                fingerprints.append(file + ":" + SafeFile.digest(text))
                guard let text else { continue }
                let requested: String
                if name == "package.json" {
                    let json: Any
                    do { json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
                    catch { throw AppError("package.json 格式错误") }
                    guard let manifest = json as? [String: Any] else { throw AppError("package.json 必须是对象") }
                    guard let engines = manifest["engines"] as? [String: Any], let value = engines["node"] else { continue }
                    guard let range = value as? String, range.utf16.count <= 4096,
                          !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !Self.hasUnsafeCharacters(range), semver.validRange(range) != nil else { throw AppError("engines.node 范围无效") }
                    requested = range
                } else { requested = try parseDeclaration(text) }
                return Declaration(requested: requested, source: name, file: file, inherited: directory != path)
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty { return nil }
            directory = parent
        }
    }

    private func parseDeclaration(_ text: String) throws -> String {
        let versions = text.components(separatedBy: "\n").map {
            String($0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && !$0.contains("=") }
        guard versions.count == 1, !Self.hasUnsafeCharacters(versions[0]),
              versions[0].rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw AppError("版本声明无效") }
        return versions[0]
    }

    private func resolve(_ requested: String, installed: [NodeRelease], nvmDir: String, depth: Int = 0) throws -> String? {
        guard !requested.isEmpty, depth <= 8 else { return nil }
        let sorted = installed.sorted { semver.rcompare($0.version, $1.version) < 0 }
        if requested == "node" || requested == "stable" { return sorted.first?.version }
        if requested == "system" { return "system" }
        if requested.hasPrefix("lts/") {
            let name = String(requested.dropFirst(4)).lowercased()
            return sorted.first { $0.lts && (name == "*" || $0.codename.lowercased() == name) }?.version
        }
        if requested.range(of: "^[a-z][a-z0-9_-]*$", options: [.regularExpression, .caseInsensitive]) != nil {
            let alias = (nvmDir as NSString).appendingPathComponent("alias/" + requested)
            guard let value = try SafeFile.read(alias, limit: 8192) else { return nil }
            return try resolve(value.trimmingCharacters(in: .whitespacesAndNewlines), installed: sorted, nvmDir: nvmDir, depth: depth + 1)
        }
        guard semver.validRange(requested) != nil else { return nil }
        return sorted.first { semver.satisfies($0.version, requested) }?.version
    }

    private static func hasUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
    }
}
