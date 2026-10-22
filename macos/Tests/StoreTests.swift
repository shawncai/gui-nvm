import XCTest
@testable import GUINVMCore

final class StoreTests: XCTestCase {
    private var root: URL!
    private var resourceURL: URL { Bundle(for: Self.self).resourceURL! }
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: try SafeFile.directory(FileManager.default.temporaryDirectory.path)).appendingPathComponent("gui-nvm-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func json(_ value: Any, at url: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
    private func waitForScan(_ store: AppStore) async throws -> AppSnapshot {
        for _ in 0..<100 {
            let state = try await store.snapshot()
            if state.scan.state != "running" { return state }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError("scan did not finish")
    }
    func testImportsLegacyOnceAndKeepsNativeStateSeparate() async throws {
        let legacy = try directory("legacy"), native = try directory("native"), projects = try directory("projects")
        let nvm = try directory("nvm")
        let manual = try directory("manual")
        try "{\"name\":\"native-test\"}".write(to: manual.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let stateFile = legacy.appendingPathComponent("state.json")
        try json(["roots": [projects.path], "projects": [manual.path], "manualPaths": [manual.path]], at: stateFile)
        let original = try Data(contentsOf: stateFile)
        try json(["rows": [["version":"v22.22.3", "date":"2026-01-01", "files":["osx-arm64-tar"], "lts":"Jod"]], "at":"2026-10-21T00:00:00Z"], at: legacy.appendingPathComponent("releases.json"))
        let store = try AppStore(resourceURL: resourceURL, dataDir: native, legacyDir: legacy, nvmDir: nvm.path)
        try await store.initialize(sync: false)
        let state = try await waitForScan(store)
        XCTAssertEqual(state.roots, [projects.path])
        XCTAssertEqual(state.projects.map(\.path), [manual.path])
        XCTAssertEqual(state.runtime.releases.first?.version, "v22.22.3")
        XCTAssertEqual(try Data(contentsOf: stateFile), original)
        await store.close()
        try json(["roots": [root.path], "projects": [], "manualPaths": []], at: stateFile)
        let reopened = try AppStore(resourceURL: resourceURL, dataDir: native, legacyDir: legacy, nvmDir: nvm.path)
        try await reopened.initialize(sync: false)
        let reopenedState = try await waitForScan(reopened)
        XCTAssertEqual(reopenedState.roots, [projects.path])
        await reopened.close()
    }
    func testDamagedLegacyDataIsReportedAndNotOverwritten() async throws {
        let legacy = try directory("legacy"), native = try directory("native"), nvm = try directory("nvm")
        let stateFile = legacy.appendingPathComponent("state.json")
        try "broken".write(to: stateFile, atomically: true, encoding: .utf8)
        let store = try AppStore(resourceURL: resourceURL, dataDir: native, legacyDir: legacy, nvmDir: nvm.path)
        try await store.initialize(sync: false)
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.roots.isEmpty)
        XCTAssertTrue(snapshot.notices.contains { $0.contains("未导入旧项目清单") })
        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), "broken")
        await store.close()
    }
    func testSavedNVMDirectoryWinsAndCloseRejectsNewActions() async throws {
        let legacy = try directory("legacy"), native = try directory("native"), first = try directory("first"), second = try directory("second")
        let store = try AppStore(resourceURL: resourceURL, dataDir: native, legacyDir: legacy, nvmDir: first.path)
        try await store.initialize(sync: false)
        try await store.setNVMDirectory(second.path)
        await store.close()
        do { _ = try await store.addProject(root.path); XCTFail("closed store accepted mutation") } catch {}
        let reopened = try AppStore(resourceURL: resourceURL, dataDir: native, legacyDir: legacy, nvmDir: first.path)
        try await reopened.initialize(sync: false)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.nvmDir, second.path)
        await reopened.close()
    }
    func testPreviewSaveAndExternalChangeWithIndependentNVM() async throws {
        let legacy = try directory("legacy"), native = try directory("native"), nvm = try directory("nvm"), project = try directory("project")
        let bin = nvm.appendingPathComponent("versions/node/v22.22.3/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho v22.22.3\n".write(to: bin.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("node").path)
        try "{\"name\":\"native-test\"}".write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let store = try AppStore(resourceURL: resourceURL, dataDir: native, legacyDir: legacy, nvmDir: nvm.path)
        try await store.initialize(sync: false)
        let id = try await store.addProject(project.path)
        let preview = try await store.preview(id: id, destination: ".nvmrc", requested: "22.22.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.file))
        try "node\n".write(toFile: preview.file, atomically: true, encoding: .utf8)
        do { try await store.save(preview); XCTFail("overwrote concurrent edit") } catch {}
        XCTAssertEqual(try String(contentsOfFile: preview.file, encoding: .utf8), "node\n")
        let refreshed = try await store.preview(id: id, destination: ".nvmrc", requested: "22.22.3")
        try await store.save(refreshed)
        XCTAssertEqual(try String(contentsOfFile: refreshed.file, encoding: .utf8), "22.22.3\n")
        await store.close()
    }
}
