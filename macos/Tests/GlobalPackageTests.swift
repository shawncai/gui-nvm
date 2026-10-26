import XCTest
import Darwin
@testable import GUINVMCore

private actor PackageCommands {
    private var values: [GlobalPackageCommand] = []
    func append(_ command: GlobalPackageCommand) { values.append(command) }
    func snapshot() -> [GlobalPackageCommand] { values }
}

private final class PackageChildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); value += text; lock.unlock() }
    func pid() -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Every package operation uses an isolated fake nvm tree and an injected executor.
/// The tests never invoke npm or modify a package in the user's actual nvm directory.
final class GlobalPackageTests: XCTestCase {
    private let firstNode = "v22.22.3"
    private let secondNode = "v20.20.0"
    private let installNode = "v24.0.0"
    private var resources: URL { Bundle(for: Self.self).resourceURL! }

    private func temporary() throws -> URL {
        let parent = URL(fileURLWithPath: try SafeFile.directory(FileManager.default.temporaryDirectory.path))
        let root = parent.appendingPathComponent("gui-nvm-packages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func prefix(_ root: URL, _ version: String) -> URL {
        root.appendingPathComponent("nvm/versions/node/" + version)
    }

    @discardableResult
    private func node(_ root: URL, _ version: String, withNPM: Bool = true) throws -> URL {
        let path = prefix(root, version)
        let bin = path.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("node")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(version)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if withNPM {
            let npm = try package(root, node: version, name: "npm", version: "10.9.0")
            let npmBin = npm.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: npmBin, withIntermediateDirectories: true)
            try Data("// Isolated npm CLI fixture; never executed.\n".utf8).write(to: npmBin.appendingPathComponent("npm-cli.js"))
        }
        return path
    }

    @discardableResult
    private func package(_ root: URL, node: String, name: String, version: String) throws -> URL {
        let path = prefix(root, node).appendingPathComponent("lib/node_modules/" + name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Self.writeManifest(path, name: name, version: version)
        return path
    }

    private static func writeManifest(_ path: URL, name: String, version: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "version": version], options: [.sortedKeys])
        try data.write(to: path.appendingPathComponent("package.json"))
    }

    private func runtime(_ root: URL, installer: RuntimeService.Installer? = nil,
                         executor: RuntimeService.PackageExecutor? = nil) throws -> RuntimeService {
        let index = Data("[{\"version\":\"\(installNode)\",\"date\":\"2026-10-20\",\"files\":[\"osx-arm64-tar\",\"osx-x64-tar\"]}]".utf8)
        return try RuntimeService(resourceURL: resources, dataDir: root.appendingPathComponent("data"),
                                  nvmDir: root.appendingPathComponent("nvm").path,
                                  fetcher: { index }, installer: installer, packageExecutor: executor)
    }

    private func record(_ service: RuntimeService, name: String, node: String? = nil) async throws -> GlobalPackageRecord {
        let state = try await service.snapshot()
        return try XCTUnwrap(state.globalPackages.rows.first { $0.name == name && (node == nil || $0.nodeVersion == node) })
    }

    private func finished(_ service: RuntimeService, id: String) async throws -> InstallTask {
        for _ in 0..<400 {
            if let task = try await service.snapshot().tasks.first(where: { $0.id == id }), task.endedAt != nil { return task }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await service.close()
        throw AppError("隔离全局包任务未按时结束")
    }

    private func assertRejected<T>(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                   _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail(message, file: file, line: line) } catch {}
    }

    private func flag(_ key: String, in command: GlobalPackageCommand) -> String? {
        if let combined = command.arguments.first(where: { $0.hasPrefix(key + "=") }) {
            return String(combined.dropFirst(key.count + 1))
        }
        guard let index = command.arguments.firstIndex(of: key), index + 1 < command.arguments.count else { return nil }
        return command.arguments[index + 1]
    }

    func testScanSeparatesNodeVersionsAndKeepsProtectedDamagedAndLinkedRows() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode); try node(root, secondNode)
        try package(root, node: firstNode, name: "pnpm", version: "10.0.0")
        try package(root, node: secondNode, name: "pnpm", version: "9.0.0")
        try package(root, node: firstNode, name: "yarn", version: "1.22.22")
        try package(root, node: firstNode, name: "corepack", version: "0.34.0")
        let scoped = try package(root, node: firstNode, name: "@acme/cli", version: "2.3.4")
        let dependency = scoped.appendingPathComponent("node_modules/transitive")
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try Self.writeManifest(dependency, name: "transitive", version: "1.0.0")
        let damaged = try package(root, node: firstNode, name: "damaged", version: "1.0.0")
        try Data("{ invalid manifest".utf8).write(to: damaged.appendingPathComponent("package.json"))
        let outside = root.appendingPathComponent("linked-source")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Self.writeManifest(outside, name: "linked", version: "1.0.0")
        let link = prefix(root, firstNode).appendingPathComponent("lib/node_modules/linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkedScope = prefix(root, firstNode).appendingPathComponent("lib/node_modules/@linked-scope")
        try FileManager.default.createSymbolicLink(at: linkedScope, withDestinationURL: outside)

        let service = try runtime(root)
        await service.refreshGlobalPackages()
        let state = try await service.snapshot().globalPackages
        XCTAssertFalse(state.scanning)
        XCTAssertNotNil(state.scannedAt)
        XCTAssertEqual(state.rows.filter { $0.name == "pnpm" }.count, 2)
        XCTAssertEqual(Set(state.rows.map(\.id)).count, state.rows.count)
        XCTAssertEqual(state.rows.first { $0.name == "@acme/cli" }?.path, scoped.path)
        XCTAssertFalse(state.rows.contains { $0.name == "transitive" })
        XCTAssertTrue(state.errors.contains { $0.path == linkedScope.path }, "局部读取错误不应阻止其他包显示")
        XCTAssertTrue(state.rows.filter { ["pnpm", "yarn", "@acme/cli"].contains($0.name) }.allSatisfy(\.editable))
        for name in ["npm", "corepack", "damaged", "linked"] {
            let rows = state.rows.filter { $0.name == name }
            XCTAssertFalse(rows.isEmpty, "应展示只读包 \(name)")
            for row in rows {
                XCTAssertFalse(row.editable, "\(name) 应为只读")
                XCTAssertNotNil(row.issue, "\(name) 应说明只读原因")
                await assertRejected("核心服务必须阻止操作 \(name)") {
                    try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
                }
            }
        }
        await service.close()
    }

    func testEmptyDirectoryAndSnapshotCacheRefreshExplicitly() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode, withNPM: false)
        let service = try runtime(root)
        await service.refreshGlobalPackages()
        let empty = try await service.snapshot().globalPackages
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertTrue(empty.errors.isEmpty)
        let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let beforeRefresh = try await service.snapshot().globalPackages
        XCTAssertTrue(beforeRefresh.rows.isEmpty, "普通状态轮询不应重新读取包清单")
        await service.refreshGlobalPackages()
        let before = try await record(service, name: "example-cli")
        try Self.writeManifest(path, name: "example-cli", version: "2.0.0")
        let cached = try await record(service, name: "example-cli")
        XCTAssertEqual(cached, before)
        await service.refreshGlobalPackages()
        let after = try await record(service, name: "example-cli")
        XCTAssertEqual(after.version, "2.0.0")
        XCTAssertNotEqual(after.revision, before.revision)
        await service.close()
    }

    func testExactVersionValidationAndPreReleaseSupport() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        try package(root, node: firstNode, name: "example-cli", version: "0.9.0")
        let service = try runtime(root)
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "example-cli")
        for value in ["1.2.3", "1.2.3-beta.1", "1.2.3+build.7", "1.2.3-rc.1+build.7"] {
            let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: value)
            XCTAssertEqual(preview.targetVersion, value)
            XCTAssertFalse(preview.allowScripts)
        }
        for value in ["", "latest", "next", "v1.2.3", "^1.2.3", "~1.2.3", ">=1.2.3", "1.2", "01.2.3", "1.2.3-beta.01", "https://example.invalid/pkg.tgz", "file:/tmp/pkg", "1.2.3;touch /tmp/no", "1.2.3 --prefix /tmp", "1.2.3\n"] {
            await assertRejected("应拒绝非精确版本 \(value.debugDescription)") {
                try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: value)
            }
        }
        await assertRejected("调整版本必须提供目标版本") {
            try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion)
        }
        await service.close()
    }

    func testStalePreviewRejectsChangedMissingAndReplacedPackageDirectories() async throws {
        for mutation in ["manifest", "removed", "directory", "symlink"] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            try node(root, firstNode)
            let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
            let calls = PackageCommands()
            let service = try runtime(root, executor: { command, _ in
                await calls.append(command)
                return ProcessResult(status: 0, stdout: "", stderr: "")
            })
            await service.refreshGlobalPackages()
            let row = try await record(service, name: "example-cli")
            let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
            switch mutation {
            case "manifest": try Self.writeManifest(path, name: "example-cli", version: "2.0.0")
            case "removed": try FileManager.default.removeItem(at: path)
            case "directory":
                try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("original-package"))
                try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
            default:
                let moved = root.appendingPathComponent("linked-package")
                try FileManager.default.moveItem(at: path, to: moved)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
            }
            await assertRejected("确认后发生 \(mutation) 应要求刷新") {
                try await service.applyGlobalPackageChange(preview)
            }
            let executed = await calls.snapshot()
            XCTAssertTrue(executed.isEmpty, "失效预览不得启动 npm")
            await service.close()
        }
    }

    func testPreviewRejectsReplacedNodePrefixAndChangedNVMDirectory() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try node(root, firstNode)
        try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let service = try runtime(root)
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "example-cli")
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
        try FileManager.default.moveItem(at: installed, to: root.appendingPathComponent("original-node"))
        try node(root, firstNode)
        try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        await assertRejected("确认后替换 Node 安装目录应失败") { try await service.applyGlobalPackageChange(preview) }
        await service.refreshGlobalPackages()
        let updated = try await record(service, name: "example-cli")
        let newPreview = try await service.previewGlobalPackageChange(packageID: updated.id, action: .remove)
        try await service.setNVMDirectory(root.appendingPathComponent("different-nvm").path)
        await assertRejected("更换 nvm 目录后不得执行旧预览") { try await service.applyGlobalPackageChange(newPreview) }
        await service.close()
    }

    func testChangeVersionUsesTargetNodeAndSafeFlagsAndRefreshesOnlyItsPackage() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let targetPrefix = try node(root, firstNode)
        try node(root, secondNode)
        let changed = try package(root, node: firstNode, name: "@acme/cli", version: "1.0.0")
        let peer = try package(root, node: secondNode, name: "@acme/cli", version: "8.0.0")
        let peerBytes = try Data(contentsOf: peer.appendingPathComponent("package.json"))
        let calls = PackageCommands()
        let targetVersion = "2.0.0-rc.1"
        let service = try runtime(root, executor: { command, output in
            await calls.append(command)
            output("\u{001B}[32mupdated fixture\u{001B}[0m\n")
            try Self.writeManifest(changed, name: "@acme/cli", version: targetVersion)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        })
        await service.refreshGlobalPackages()
        let beforeDefault = try await service.snapshot().defaultVersion
        let row = try await record(service, name: "@acme/cli", node: firstNode)
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: targetVersion)
        let id = try await service.applyGlobalPackageChange(preview)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "complete", task.error ?? "")
        XCTAssertEqual(task.kind, "packageChangeVersion")
        XCTAssertEqual(task.packageName, "@acme/cli")
        XCTAssertEqual(task.targetVersion, targetVersion)
        XCTAssertEqual(task.version, firstNode)
        XCTAssertFalse(task.log.contains("\u{001B}"))
        let commands = await calls.snapshot()
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(command.executable, targetPrefix.appendingPathComponent("bin/node").path)
        XCTAssertEqual(command.arguments.first, targetPrefix.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js").path)
        XCTAssertTrue(command.arguments.contains("install"))
        XCTAssertTrue(command.arguments.contains("--global"))
        XCTAssertEqual(flag("--prefix", in: command), targetPrefix.path)
        XCTAssertEqual(flag("--force", in: command), "false")
        XCTAssertEqual(flag("--engine-strict", in: command), "true")
        XCTAssertEqual(flag("--ignore-scripts", in: command), "true")
        XCTAssertTrue(command.arguments.contains("@acme/cli@" + targetVersion))
        XCTAssertEqual(command.environment["PATH"]?.split(separator: ":").first.map(String.init), targetPrefix.appendingPathComponent("bin").path)
        XCTAssertNil(command.environment["NODE_OPTIONS"])
        let after = try await record(service, name: "@acme/cli", node: firstNode)
        XCTAssertEqual(after.version, targetVersion)
        XCTAssertEqual(try Data(contentsOf: peer.appendingPathComponent("package.json")), peerBytes)
        let afterDefault = try await service.snapshot().defaultVersion
        XCTAssertEqual(afterDefault, beforeDefault)
        await assertRejected("确认只能提交一次") { try await service.applyGlobalPackageChange(preview) }
        await service.close()
    }

    func testScriptPermissionIsSingleUseAndUninstallAlwaysDisablesScripts() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let calls = PackageCommands()
        let service = try runtime(root, executor: { command, _ in
            await calls.append(command)
            if command.arguments.contains("uninstall") { try FileManager.default.removeItem(at: path) }
            else {
                let spec = try XCTUnwrap(command.arguments.last)
                let version = try XCTUnwrap(spec.split(separator: "@").last).description
                try Self.writeManifest(path, name: "example-cli", version: version)
            }
            return ProcessResult(status: 0, stdout: "", stderr: "")
        })
        await service.refreshGlobalPackages()
        let original = try await record(service, name: "example-cli")
        var allowed = try await service.previewGlobalPackageChange(packageID: original.id, action: .changeVersion, targetVersion: "2.0.0")
        allowed.allowScripts = true
        let firstID = try await service.applyGlobalPackageChange(allowed)
        let firstTask = try await finished(service, id: firstID)
        XCTAssertEqual(firstTask.state, "complete", firstTask.error ?? "")
        let current = try await record(service, name: "example-cli")
        let next = try await service.previewGlobalPackageChange(packageID: current.id, action: .changeVersion, targetVersion: "1.0.0")
        XCTAssertFalse(next.allowScripts, "上一次脚本许可不能延续到下一次操作")
        let nextID = try await service.applyGlobalPackageChange(next)
        let nextTask = try await finished(service, id: nextID)
        XCTAssertEqual(nextTask.state, "complete", nextTask.error ?? "")
        let final = try await record(service, name: "example-cli")
        var removal = try await service.previewGlobalPackageChange(packageID: final.id, action: .remove)
        removal.allowScripts = true
        let removalID = try await service.applyGlobalPackageChange(removal)
        let removalTask = try await finished(service, id: removalID)
        XCTAssertEqual(removalTask.state, "complete", removalTask.error ?? "")
        XCTAssertEqual(removalTask.kind, "packageRemove")
        let commands = await calls.snapshot()
        XCTAssertEqual(commands.count, 3)
        if commands.count == 3 {
            XCTAssertEqual(flag("--ignore-scripts", in: commands[0]), "false")
            XCTAssertEqual(flag("--ignore-scripts", in: commands[1]), "true")
            XCTAssertEqual(flag("--ignore-scripts", in: commands[2]), "true")
            XCTAssertTrue(commands[2].arguments.contains("uninstall"))
            XCTAssertEqual(commands[2].arguments.last, "example-cli")
        }
        let snapshot = try await service.snapshot()
        XCTAssertFalse(snapshot.globalPackages.rows.contains { $0.name == "example-cli" })
        await service.close()
    }

    func testRemovingLastScopedPackageAllowsNPMToRemoveItsScopeDirectory() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        let path = try package(root, node: firstNode, name: "@acme/cli", version: "1.0.0")
        let service = try runtime(root, executor: { _, _ in
            try FileManager.default.removeItem(at: path.deletingLastPathComponent())
            return ProcessResult(status: 0, stdout: "", stderr: "")
        })
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "@acme/cli")
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
        let id = try await service.applyGlobalPackageChange(preview)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "complete", task.error ?? "")
        let snapshot = try await service.snapshot().globalPackages
        XCTAssertFalse(snapshot.rows.contains { $0.name == "@acme/cli" })
        XCTAssertTrue(snapshot.errors.isEmpty)
        await service.close()
    }

    func testMissingOrLinkedNPMEntryCannotExecutePackageChanges() async throws {
        for mutation in ["missing", "linked", "linked-parent"] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let installed = try node(root, firstNode)
            try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
            let cli = installed.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
            switch mutation {
            case "missing": try FileManager.default.removeItem(at: cli)
            case "linked":
                let outside = root.appendingPathComponent("external-npm-cli.js")
                try FileManager.default.moveItem(at: cli, to: outside)
                try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: outside)
            default:
                let bin = cli.deletingLastPathComponent()
                let outside = root.appendingPathComponent("external-npm-bin")
                try FileManager.default.moveItem(at: bin, to: outside)
                try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: outside)
            }
            let commands = PackageCommands()
            let service = try runtime(root, executor: { command, _ in
                await commands.append(command)
                return ProcessResult(status: 0, stdout: "", stderr: "")
            })
            await service.refreshGlobalPackages()
            let row = try await record(service, name: "example-cli")
            XCTAssertFalse(row.editable, "npm 入口不可用时应显示为只读")
            XCTAssertNotNil(row.issue)
            await assertRejected("npm 入口 \(mutation) 时不允许预览或执行") {
                let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
                return try await service.applyGlobalPackageChange(preview)
            }
            let executed = await commands.snapshot()
            XCTAssertTrue(executed.isEmpty)
            await service.close()
        }
    }

    func testCommandPreservesRegistryAuthAndScriptPolicyWhileOverridingUnsafeSettings() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try node(root, firstNode)
        try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let semver = try Semver(resourceURL: resources.appendingPathComponent("node-semver"))
        let row = GlobalPackages.record(nvmDir: root.appendingPathComponent("nvm").path, version: firstNode, name: "example-cli", semver: semver)
        let preview = GlobalPackagePreview(nvmDir: root.appendingPathComponent("nvm").path, package: row, action: .changeVersion, targetVersion: "2.0.0")
        let token = UUID().uuidString
        let source = ["PATH": "/unsafe/bin", "NODE_OPTIONS": "--require /unsafe/hook.js", "NODE_PATH": "/unsafe/modules",
                      "NPM_CONFIG_PREFIX": "/unsafe/prefix", "npm_config_ignore_scripts": "false",
                      "npm_config_force": "true", "npm_config_engine_strict": "false",
                      "NPM_CONFIG_REGISTRY": "https://registry.example.invalid", "NPM_TOKEN": token,
                      "npm_config_allow_scripts": "false", "HTTPS_PROXY": "http://127.0.0.1:7890"]
        let command = try GlobalPackages.command(preview, environment: source)
        XCTAssertEqual(command.environment["NPM_CONFIG_REGISTRY"], source["NPM_CONFIG_REGISTRY"])
        XCTAssertEqual(command.environment["NPM_TOKEN"], token)
        XCTAssertEqual(command.environment["HTTPS_PROXY"], source["HTTPS_PROXY"])
        XCTAssertEqual(command.environment["npm_config_allow_scripts"], "false", "不得放宽 npm 自身的额外脚本限制")
        XCTAssertNil(command.environment["NODE_OPTIONS"])
        XCTAssertNil(command.environment["NODE_PATH"])
        XCTAssertNil(command.environment["NPM_CONFIG_PREFIX"])
        XCTAssertEqual(flag("--prefix", in: command), installed.path)
        XCTAssertEqual(flag("--force", in: command), "false")
        XCTAssertEqual(flag("--engine-strict", in: command), "true")
        XCTAssertEqual(flag("--ignore-scripts", in: command), "true")
    }

    func testTaskLogsRedactCredentialsEvenWhenTheyArriveInSeparateChunks() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let secret = UUID().uuidString
        let service = try runtime(root, executor: { _, output in
            output("fetch https://fixture-user:")
            output(secret + "@registry.example.invalid/package\n")
            output("_authTo")
            output("ken=" + secret + "\n")
            try Self.writeManifest(path, name: "example-cli", version: "2.0.0")
            return ProcessResult(status: 0, stdout: "", stderr: "")
        })
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "example-cli")
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: "2.0.0")
        let id = try await service.applyGlobalPackageChange(preview)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "complete", task.error ?? "")
        XCTAssertFalse(task.log.contains(secret))
        XCTAssertFalse(task.log.contains("fixture-user"))
        XCTAssertTrue(task.log.contains("[REDACTED]"))
        XCTAssertTrue(task.log.contains("registry.example.invalid/package"))
        await service.close()
    }

    func testFailureRefreshesPartialChangesAndDoesNotClaimRollback() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let service = try runtime(root, executor: { _, output in
            try Self.writeManifest(path, name: "example-cli", version: "2.0.0")
            output("npm ERR! fixture failure\n")
            return ProcessResult(status: 7, stdout: "", stderr: "fixture failure")
        })
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "example-cli")
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: "2.0.0")
        let id = try await service.applyGlobalPackageChange(preview)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "failed")
        XCTAssertNotNil(task.error)
        XCTAssertTrue(task.error?.contains("可能已有部分变更") == true)
        let changed = try await record(service, name: "example-cli")
        XCTAssertEqual(changed.version, "2.0.0", "失败后仍应展示磁盘实际状态")
        await service.close()
    }

    func testReportedSuccessRequiresActualFilesystemResult() async throws {
        for action in [GlobalPackageAction.remove, .changeVersion] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            try node(root, firstNode)
            try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
            let service = try runtime(root, executor: { _, _ in ProcessResult(status: 0, stdout: "", stderr: "") })
            await service.refreshGlobalPackages()
            let row = try await record(service, name: "example-cli")
            let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: action, targetVersion: action == .changeVersion ? "2.0.0" : nil)
            let id = try await service.applyGlobalPackageChange(preview)
            let task = try await finished(service, id: id)
            XCTAssertEqual(task.state, "failed", "npm 退出成功但实际包未改变时不能报告成功")
            let unchanged = try await record(service, name: "example-cli")
            XCTAssertEqual(unchanged.version, "1.0.0")
            await service.close()
        }
    }

    func testCommandConflictAndIncompatibleEngineRemainFailuresWithoutForce() async throws {
        for code in ["EEXIST", "EBADENGINE"] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let installed = try node(root, firstNode)
            try package(root, node: firstNode, name: "pnpm", version: "9.0.0")
            let shim = installed.appendingPathComponent("bin/pnpm")
            let original = Data("corepack-owned fixture".utf8)
            try original.write(to: shim)
            let calls = PackageCommands()
            let service = try runtime(root, executor: { command, output in
                await calls.append(command)
                output("npm ERR! \(code)\n")
                return ProcessResult(status: 1, stdout: "", stderr: "npm ERR! \(code)")
            })
            await service.refreshGlobalPackages()
            let row = try await record(service, name: "pnpm")
            let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: "10.0.0")
            let id = try await service.applyGlobalPackageChange(preview)
            let task = try await finished(service, id: id)
            XCTAssertEqual(task.state, "failed")
            XCTAssertEqual(try Data(contentsOf: shim), original, "不得自动移除或覆盖冲突的命令")
            let commands = await calls.snapshot()
            XCTAssertEqual(commands.count, 1, "不应以 force 重试")
            if let command = commands.first {
                XCTAssertEqual(flag("--force", in: command), "false")
                XCTAssertEqual(flag("--engine-strict", in: command), "true")
            }
            await service.close()
        }
    }

    func testExistingBinAndManTargetsMustBeOwnedLinksOrAbsent() async throws {
        for kind in ["bin", "man"] {
            for placement in ["missing", "owned", "foreign", "regular", "linked-parent"] {
                let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
                let installed = try node(root, firstNode)
                let path = try package(root, node: firstNode, name: "pnpm", version: "9.0.0")
                let relativeSource = kind == "bin" ? "bin/pnpm.cjs" : "man/pnpm.1"
                let source = path.appendingPathComponent(relativeSource)
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("owned package fixture".utf8).write(to: source)
                var manifest: [String: Any] = ["name": "pnpm", "version": "9.0.0"]
                if kind == "bin" { manifest["bin"] = ["pnpm": relativeSource] }
                else { manifest["man"] = [relativeSource] }
                try JSONSerialization.data(withJSONObject: manifest).write(to: path.appendingPathComponent("package.json"))
                let destination = installed.appendingPathComponent(kind == "bin" ? "bin/pnpm" : "share/man/man1/pnpm.1")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch placement {
                case "owned", "linked-parent":
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
                    if placement == "linked-parent" {
                        let parent = destination.deletingLastPathComponent()
                        let moved = root.appendingPathComponent("external-command-directory")
                        try FileManager.default.moveItem(at: parent, to: moved)
                        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
                    }
                case "foreign":
                    let owner = kind == "bin"
                        ? try package(root, node: firstNode, name: "corepack", version: "0.34.0")
                        : installed.appendingPathComponent("lib/node_modules/npm")
                    let foreign = owner.appendingPathComponent(kind == "bin" ? "dist/pnpm.js" : "man/man1/npm.1")
                    try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("foreign tool fixture".utf8).write(to: foreign)
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: foreign)
                case "regular": try Data("unrelated command fixture".utf8).write(to: destination)
                default: break
                }
                let service = try runtime(root, executor: { _, _ in ProcessResult(status: 0, stdout: "", stderr: "") })
                await service.refreshGlobalPackages()
                let row = try await record(service, name: "pnpm")
                let allowed = placement == "owned" || placement == "missing"
                XCTAssertEqual(row.editable, allowed, "\(kind) / \(placement)")
                if allowed {
                    _ = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
                } else {
                    XCTAssertNotNil(row.issue)
                    await assertRejected("不能删除或重装不属于当前包的 \(kind) / \(placement)") {
                        try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
                    }
                    await assertRejected("调整版本同样必须保护 \(kind) / \(placement)") {
                        try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: "10.0.0")
                    }
                }
                await service.close()
            }
        }
    }

    func testPreviewRechecksCommandOwnershipBeforeExecution() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = try node(root, firstNode)
        let path = try package(root, node: firstNode, name: "@acme/cli", version: "1.0.0")
        let source = path.appendingPathComponent("cli.js")
        try Data("owned command fixture".utf8).write(to: source)
        try JSONSerialization.data(withJSONObject: ["name": "@acme/cli", "version": "1.0.0", "bin": "cli.js"])
            .write(to: path.appendingPathComponent("package.json"))
        let destination = installed.appendingPathComponent("bin/cli")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        let commands = PackageCommands()
        let service = try runtime(root, executor: { command, _ in
            await commands.append(command)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        })
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "@acme/cli")
        XCTAssertTrue(row.editable)
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
        try FileManager.default.removeItem(at: destination)
        let protectedNPM = installed.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: protectedNPM)
        await assertRejected("确认后命令被替换为 npm 链接时不能执行") {
            try await service.applyGlobalPackageChange(preview)
        }
        let executed = await commands.snapshot()
        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), protectedNPM.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedNPM.path))
        await service.close()
    }

    func testPackageAndNodeInstallationShareMutualExclusionAndDirectoryGuard() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let service = try runtime(root,
                                  installer: { _, _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                                  executor: { _, _ in
                                      try await Task.sleep(nanoseconds: 60_000_000_000)
                                      return ProcessResult(status: 0, stdout: "", stderr: "")
                                  })
        await service.syncCatalog()
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "example-cli")
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .remove)
        let packageID = try await service.applyGlobalPackageChange(preview)
        await assertRejected("包任务期间应阻止 Node 安装") { try await service.install(version: self.installNode) }
        await assertRejected("包任务期间应阻止并行包操作") { try await service.applyGlobalPackageChange(preview) }
        await assertRejected("包任务期间应阻止切换 nvm 目录") {
            try await service.setNVMDirectory(root.appendingPathComponent("other").path)
        }
        try await service.cancel(id: packageID)
        let cancelled = try await finished(service, id: packageID)
        XCTAssertEqual(cancelled.state, "cancelled")
        let refreshed = try await record(service, name: "example-cli")
        let next = try await service.previewGlobalPackageChange(packageID: refreshed.id, action: .remove)
        let nodeID = try await service.install(version: installNode)
        await assertRejected("Node 安装期间应阻止包操作") { try await service.applyGlobalPackageChange(next) }
        try await service.cancel(id: nodeID)
        let nodeTask = try await finished(service, id: nodeID)
        XCTAssertEqual(nodeTask.kind, "nodeInstall")
        XCTAssertEqual(nodeTask.state, "cancelled")
        await service.close()
    }

    func testPackageTimeoutFailsAndRefreshesState() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try node(root, firstNode)
        let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
        let service = try runtime(root, executor: { _, _ in
            try Self.writeManifest(path, name: "example-cli", version: "2.0.0")
            return try await ProcessRunner.run("/bin/sleep", arguments: ["60"], timeout: 0.05, terminationGrace: 0.05)
        })
        await service.refreshGlobalPackages()
        let row = try await record(service, name: "example-cli")
        let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: "2.0.0")
        let id = try await service.applyGlobalPackageChange(preview)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "failed")
        XCTAssertTrue(task.error?.contains("超时") == true)
        let refreshed = try await record(service, name: "example-cli")
        XCTAssertEqual(refreshed.version, "2.0.0")
        await service.close()
    }

    func testCancelAndCloseReapRunningPackageChildProcesses() async throws {
        for closeApplication in [false, true] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            try node(root, firstNode)
            let path = try package(root, node: firstNode, name: "example-cli", version: "1.0.0")
            let output = PackageChildOutput()
            let service = try runtime(root, executor: { _, _ in
                try Self.writeManifest(path, name: "example-cli", version: "2.0.0")
                return try await ProcessRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; sleep 60 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""],
                                                   timeout: 10, terminationGrace: 0.05, onOutput: { output.append($0) })
            })
            await service.refreshGlobalPackages()
            let row = try await record(service, name: "example-cli")
            let preview = try await service.previewGlobalPackageChange(packageID: row.id, action: .changeVersion, targetVersion: "2.0.0")
            let id = try await service.applyGlobalPackageChange(preview)
            var child: pid_t?
            for _ in 0..<150 {
                child = output.pid()
                if child != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let child else { await service.close(); XCTFail("未收到隔离任务的子进程 PID"); continue }
            XCTAssertEqual(kill(child, 0), 0)
            if closeApplication { await service.close() }
            else { try await service.cancel(id: id) }
            let task = try await finished(service, id: id)
            XCTAssertEqual(task.state, "cancelled")
            for _ in 0..<100 {
                if kill(child, 0) != 0 && errno == ESRCH { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(kill(child, 0), -1, "退出或取消后不能遗留子进程")
            XCTAssertEqual(errno, ESRCH)
            if !closeApplication {
                let refreshed = try await record(service, name: "example-cli")
                XCTAssertEqual(refreshed.version, "2.0.0", "取消后必须重读磁盘实际状态")
            }
            await service.close()
            await assertRejected("关闭后不得接受包操作") { try await service.applyGlobalPackageChange(preview) }
        }
    }
}
