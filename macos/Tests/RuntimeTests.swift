import XCTest
@testable import GUINVMCore

final class RuntimeTests: XCTestCase {
    private let version = "v22.22.3"
    private var resources: URL {
        Bundle(for: RuntimeTests.self).resourceURL!
    }
    private var index: Data {
        Data("[{\"version\":\"v22.22.3\",\"date\":\"2026-10-20\",\"lts\":\"Jod\",\"files\":[\"osx-arm64-tar\",\"osx-x64-tar\"]}]".utf8)
    }
    private func temporary() throws -> URL {
        let base = URL(fileURLWithPath: try SafeFile.directory(FileManager.default.temporaryDirectory.path))
        let url = base.appendingPathComponent("gui-nvm-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func runtime(_ root: URL, installer: RuntimeService.Installer? = nil,
                         fetcher: RuntimeService.Fetcher? = nil) throws -> RuntimeService {
        let data = index
        return try RuntimeService(resourceURL: resources, dataDir: root.appendingPathComponent("data"),
                                  nvmDir: root.appendingPathComponent("nvm").path,
                                  fetcher: fetcher ?? { data }, installer: installer)
    }
    private static func fakeBinary(_ version: String, _ staging: URL) throws {
        let bin = staging.appendingPathComponent("versions/node/" + version + "/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(version)'\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
    }
    private func finished(_ runtime: RuntimeService, id: String) async throws -> InstallTask {
        for _ in 0..<300 {
            if let task = try await runtime.snapshot().tasks.first(where: { $0.id == id }), task.endedAt != nil { return task }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw AppError("测试安装未结束")
    }

    func testInstallPublishesVersionWithoutChangingDefault() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0\n".utf8).write(to: alias.appendingPathComponent("default"))
        let service = try runtime(root, installer: { version, staging, log in
            log("\u{001B}[31mred\u{001B}[0m")
            try Self.fakeBinary(version, staging)
        })
        await service.syncCatalog()
        let before = try await service.snapshot().defaultVersion
        let id = try await service.install(version: version)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "complete")
        XCTAssertEqual(task.log, "red")
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.installed.map(\.version), [version])
        XCTAssertEqual(snapshot.defaultVersion, before)
        let installed = try XCTUnwrap(snapshot.installed.first)
        XCTAssertFalse(installed.phase.isEmpty)
        try await service.setDefault(version: version, expected: before.expected)
        do { try await service.setDefault(version: version, expected: before.expected); XCTFail("旧校验值应失败") } catch {}
        await service.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("nvm").path).allSatisfy { !$0.hasPrefix(".gui-nvm-install-") })
    }

    func testConcurrentInstallBlockedAndCancellationCleansStaging() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try runtime(root, installer: { _, _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        await service.syncCatalog()
        let id = try await service.install(version: version)
        do { _ = try await service.install(version: version); XCTFail("应拒绝并行安装") } catch {}
        try await service.cancel(id: id)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nvm/versions/node/" + version).path))
        await service.close()
    }

    func testFailureDoesNotPublishAndExistingTargetIsNeverReplaced() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("nvm/versions/node/" + version)
        let service = try runtime(root, installer: { version, staging, _ in
            try Self.fakeBinary(version, staging)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: target.appendingPathComponent("owner"))
        })
        await service.syncCatalog()
        let id = try await service.install(version: version)
        let task = try await finished(service, id: id)
        XCTAssertEqual(task.state, "failed")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("owner")), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("bin/node").path))
        await service.close()
    }

    func testLegacyCacheAndFailedSyncKeepLastCatalog() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.json")
        let original = Data("{\"rows\":\(String(decoding: index, as: UTF8.self)),\"at\":\"2026-10-22T00:00:00Z\"}".utf8)
        try original.write(to: old)
        let service = try runtime(root, fetcher: { throw AppError("offline") })
        try await service.importLegacyCache(from: old)
        await service.syncCatalog()
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.releases.map(\.version), [version])
        XCTAssertTrue(snapshot.catalogError?.contains("offline") == true)
        XCTAssertEqual(try Data(contentsOf: old), original)
        await service.close()
        let reopened = try runtime(root)
        try await reopened.loadCache()
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.releases.map(\.version), [version])
        await reopened.close()
    }

    func testCreatesMissingNestedCacheAndNVMDirectories() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("new/one/two")
        let service = try runtime(nested, installer: { version, staging, _ in try Self.fakeBinary(version, staging) })
        await service.syncCatalog()
        let synced = try await service.snapshot()
        XCTAssertNil(synced.catalogError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("data/releases.json").path))
        let id = try await service.install(version: version)
        let result = try await finished(service, id: id)
        XCTAssertEqual(result.state, "complete", result.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("nvm/versions/node/" + version + "/bin/node").path))
        await service.close()
    }

    func testOversizedCacheIsReportedAndPreserved() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try runtime(root)
        try await service.loadCache()
        let missing = try await service.snapshot()
        XCTAssertNil(missing.catalogError)
        await service.syncCatalog()
        let cache = root.appendingPathComponent("data/releases.json")
        let oversized = Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)
        try oversized.write(to: cache)
        try await service.loadCache()
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.catalogError?.contains("缓存") == true)
        XCTAssertEqual(snapshot.releases.map(\.version), [version], "读取失败应保留内存中的可用索引")
        XCTAssertEqual(try Data(contentsOf: cache), oversized, "不得覆盖损坏缓存")
        await service.close()
    }

    func testSymlinkCacheIsReportedWithoutFollowingOrReplacingIt() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.json")
        let original = Data("leave this file unchanged".utf8)
        try original.write(to: target)
        let cache = data.appendingPathComponent("releases.json")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: target)
        let service = try runtime(root)
        try await service.loadCache()
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.catalogError?.contains("缓存") == true)
        XCTAssertTrue(snapshot.releases.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: cache.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), original)
        await service.close()
    }

    func testClosedRuntimeRejectsDirectoryChanges() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try runtime(root)
        await service.close()
        do {
            try await service.setNVMDirectory(root.appendingPathComponent("other").path)
            XCTFail("关闭后不能修改 nvm 目录")
        } catch { XCTAssertTrue(error.localizedDescription.contains("关闭")) }
    }

    func testRealOfficialInstallSmoke() async throws {
        guard ProcessInfo.processInfo.environment["GUI_NVM_NETWORK_SMOKE"] == "1" else {
            throw XCTSkip("设置 GUI_NVM_NETWORK_SMOKE=1 才运行官方网络安装验证")
        }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        let originalDefault = Data("v20.0.0\n".utf8)
        try originalDefault.write(to: alias.appendingPathComponent("default"))
        let service = try RuntimeService(resourceURL: resources, dataDir: root.appendingPathComponent("data"),
                                         nvmDir: root.appendingPathComponent("nvm").path)
        do {
            await service.syncCatalog()
            let catalog = try await service.snapshot()
            guard catalog.catalogError == nil, catalog.releases.contains(where: { $0.version == version && $0.compatible }) else {
                throw AppError(catalog.catalogError ?? "官方索引缺少测试版本")
            }
            let id = try await service.install(version: version)
            let deadline = Date().addingTimeInterval(300)
            var completed: InstallTask?
            while Date() < deadline {
                if let task = try await service.snapshot().tasks.first(where: { $0.id == id }), task.endedAt != nil {
                    completed = task; break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let completed else { throw AppError("官方安装验证超过 5 分钟") }
            guard completed.state == "complete" else {
                throw AppError((completed.error ?? "官方安装失败") + "\n" + completed.log)
            }
            XCTAssertTrue(completed.log.contains("Checksums matched"), completed.log)
            XCTAssertEqual(try Data(contentsOf: alias.appendingPathComponent("default")), originalDefault)
            let node = root.appendingPathComponent("nvm/versions/node/" + version + "/bin/node")
            let result = try await ProcessRunner.run(node.path, arguments: ["--version"],
                                                     environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 10)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), version)
            await service.close()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("nvm").path).allSatisfy { !$0.hasPrefix(".gui-nvm-install-") })
        } catch {
            await service.close()
            throw error
        }
    }
}
