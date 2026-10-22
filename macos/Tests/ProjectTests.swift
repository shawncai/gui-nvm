import Foundation
import Darwin
import XCTest
@testable import GUINVMCore

final class ProjectTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let root: URL
        let service: ProjectService
        var nvmDir: String { root.appendingPathComponent("nvm").path }
        let installed = [
            NodeRelease(version: "v24.17.0", phase: "LTS", codename: "Krypton", lts: true, installed: true),
            NodeRelease(version: "v22.22.3", phase: "Maintenance LTS", codename: "Jod", lts: true, installed: true),
            NodeRelease(version: "v20.19.5", phase: "EOL", codename: "Iron", lts: true, installed: true)
        ]
        func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }
        func write(_ relative: String, _ text: String) throws {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: false, encoding: .utf8)
        }
        func record(_ relative: String) throws -> ProjectRecord { try service.record(path: path(relative), installed: installed, nvmDir: nvmDir) }
        func preview(_ relative: String, _ destination: String, _ requested: String) throws -> ConfigPreview {
            try service.preview(project: record(relative), destination: destination, requested: requested, installed: installed, nvmDir: nvmDir)
        }
    }

    private func fixture() throws -> Fixture {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gui-nvm-project-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: try SafeFile.directory(temporary.path), isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(root: root, service: ProjectService(semver: try Semver(resourceURL: SemverTests.resourceURL)))
        try fixture.write("nvm/alias/default", "22.22.3\n")
        return fixture
    }

    func testNearestDirectoryThenDeclarationPriorityAndInvalidStop() throws {
        let f = try fixture()
        try f.write("projects/.nvmrc", "22.22.3\n")
        try f.write("projects/web/package.json", "{\"name\":\"web-ui\",\"engines\":{\"node\":\">=20 <25\"}}")
        var record = try f.record("projects/web")
        XCTAssertEqual(record.name, "web-ui")
        XCTAssertEqual(record.source, "package.json")
        XCTAssertEqual(record.resolved, "v24.17.0")
        XCTAssertFalse(record.inherited)
        let firstRevision = record.revision
        try f.write("projects/web/.node-version", "20\n")
        record = try f.record("projects/web")
        XCTAssertEqual(record.source, ".node-version")
        XCTAssertEqual(record.status, "eol")
        XCTAssertNotEqual(record.revision, firstRevision)
        try f.write("projects/web/.nvmrc", "# comment\n22.22.3 # version\nmetadata=value\n")
        XCTAssertEqual(try f.record("projects/web").resolved, "v22.22.3")
        try f.write("projects/web/.nvmrc", "22\n24\n")
        record = try f.record("projects/web")
        XCTAssertEqual(record.status, "invalid")
        XCTAssertNil(record.resolved)
    }

    func testInheritedDeclarationAndLocalPreviewLeaveParentIntact() throws {
        let f = try fixture()
        try f.write("projects/.nvmrc", "22\n")
        try f.write("projects/web/package.json", "{\"engines\":{\"pnpm\":\">=8\"}}")
        let inherited = try f.record("projects/web")
        XCTAssertTrue(inherited.inherited)
        XCTAssertEqual(inherited.file, f.path("projects/.nvmrc"))
        let preview = try f.preview("projects/web", ".nvmrc", "24.17.0")
        XCTAssertEqual(preview.file, f.path("projects/web/.nvmrc"))
        XCTAssertNil(preview.before)
        XCTAssertEqual(try SafeFile.read(f.path("projects/.nvmrc")), "22\n")
        try f.write("projects/.nvmrc", "20\n")
        XCTAssertNotEqual(try f.record("projects/web").revision, inherited.revision)
    }

    func testAliasesRangesMissingAndSystemBehavior() throws {
        let f = try fixture()
        try f.write("projects/web/.nvmrc", "default\n")
        XCTAssertEqual(try f.record("projects/web").resolved, "v22.22.3")
        try f.write("projects/web/.nvmrc", "lts/*\n")
        XCTAssertEqual(try f.record("projects/web").resolved, "v24.17.0")
        try f.write("projects/web/.nvmrc", "lts/jod\n")
        XCTAssertEqual(try f.record("projects/web").resolved, "v22.22.3")
        try f.write("nvm/alias/loop", "loop\n")
        try f.write("projects/web/.nvmrc", "loop\n")
        XCTAssertEqual(try f.record("projects/web").status, "missing")
        try f.write("projects/web/.nvmrc", "system\n")
        XCTAssertEqual(try f.record("projects/web").resolved, "system")
        XCTAssertThrowsError(try f.preview("projects/web", ".nvmrc", "system"))
        try f.write("projects/web/.nvmrc", "99\n")
        XCTAssertEqual(try f.record("projects/web").status, "missing")
    }

    func testPreviewPreservesManifestAndRejectsShadowedMissingOrUnsafeValues() throws {
        let f = try fixture()
        let manifest = "{\n  \"name\": \"web\",\n  \"engines\": {\"pnpm\": \">=8\"},\n  \"scripts\": {\"dev\": \"vite\"}\n}\n"
        try f.write("projects/web/package.json", manifest)
        let preview = try f.preview("projects/web", "package.json", ">=22 <25")
        XCTAssertEqual(preview.resolved, "v24.17.0")
        XCTAssertEqual(preview.before, manifest)
        XCTAssertEqual(try SafeFile.read(preview.file), manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.after.utf8)) as? [String: Any])
        XCTAssertEqual(json["engines"] as? [String: String], ["pnpm": ">=8", "node": ">=22 <25"])
        XCTAssertEqual(json["scripts"] as? [String: String], ["dev": "vite"])
        for (destination, requested) in [("../outside", "22"), (".nvmrc", "99"), (".nvmrc", "22\n24"), (".node-version", ">=22"), ("package.json", "lts/*"), (".nvmrc", "$(touch bad)")] {
            XCTAssertThrowsError(try f.preview("projects/web", destination, requested), destination + requested)
        }
        try f.write("projects/web/.nvmrc", "22\n")
        XCTAssertThrowsError(try f.preview("projects/web", "package.json", "22"))
        XCTAssertThrowsError(try f.preview("projects/web", ".node-version", "22"))
    }

    func testPackageErrorsAndProjectCodeAreNeverExecuted() throws {
        let f = try fixture()
        let cases = ["{ invalid", "[]", "null", "{\"engines\":{\"node\":22}}", "{\"engines\":{\"node\":null}}", "{\"engines\":{\"node\":\"\"}}", "{\"engines\":{\"node\":\">=\"}}", "{\"engines\":{\"node\":\"22\\u0000\"}}"]
        for text in cases {
            try f.write("projects/web/package.json", text)
            XCTAssertEqual(try f.record("projects/web").status, "invalid", text)
        }
        try f.write("projects/web/index.js", "throw new Error('project code must not run')")
        try f.write("projects/web/package.json", "{\"main\":\"index.js\",\"scripts\":{\"preinstall\":\"touch must-not-exist\"},\"engines\":{\"node\":\"22.x\"}}")
        XCTAssertEqual(try f.record("projects/web").resolved, "v22.22.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path("projects/web/must-not-exist")))
        try f.write("projects/web/package.json", "{\"__proto__\":{\"engines\":{\"node\":\"22.x\"}}}")
        XCTAssertEqual(try f.record("projects/web").status, "unconfigured")
    }

    func testPreviewRejectsCompactManifestThatExceedsLimitAfterFormatting() throws {
        let f = try fixture()
        let values = String(repeating: "0,", count: 199_999) + "0"
        let manifest = "{\"name\":\"dense\",\"values\":[" + values + "]}"
        XCTAssertLessThan(Data(manifest.utf8).count, 1_048_576)
        try f.write("projects/web/package.json", manifest)
        XCTAssertThrowsError(try f.preview("projects/web", "package.json", "22")) { error in
            XCTAssertTrue(error.localizedDescription.contains("package.json 超过 1 MiB"))
        }
        XCTAssertEqual(try SafeFile.read(f.path("projects/web/package.json")), manifest)
    }

    func testAtomicWritesDetectChangesPreserveModeAndRejectSymlinksAndSpecialFiles() throws {
        let f = try fixture()
        try f.write("projects/web/.nvmrc", "22\n")
        let file = f.path("projects/web/.nvmrc")
        let expected = SafeFile.digest(try SafeFile.read(file))
        try f.write("projects/web/.nvmrc", "24\n")
        XCTAssertThrowsError(try SafeFile.write(file, text: "20\n", expected: expected))
        XCTAssertEqual(try SafeFile.read(file), "24\n")
        XCTAssertEqual(chmod(file, 0o640), 0)
        try SafeFile.write(file, text: "22\n", expected: SafeFile.digest("24\n"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
        let link = f.path("projects/web/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        XCTAssertThrowsError(try SafeFile.read(link))
        XCTAssertThrowsError(try SafeFile.write(link, text: "20\n"))
        XCTAssertEqual(try SafeFile.read(file), "22\n")
        let fifo = f.path("projects/web/fifo")
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertThrowsError(try SafeFile.read(fifo))
        XCTAssertThrowsError(try SafeFile.write(fifo, text: "22"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.path("projects/web")).contains { $0.hasPrefix(".gui-nvm-") })
    }

    func testMissingFileRevisionCannotMatchSentinelTextAndProjectIDsStayStable() throws {
        let f = try fixture()
        try f.write("projects/web/package.json", "{}")
        let preview = try f.preview("projects/web", ".nvmrc", "22")
        XCTAssertNil(preview.before)
        try f.write("projects/web/.nvmrc", "<absent>")
        XCTAssertNotEqual(preview.expected, SafeFile.digest("<absent>"))
        XCTAssertThrowsError(try SafeFile.write(preview.file, text: preview.after, expected: preview.expected))
        XCTAssertEqual(try SafeFile.read(preview.file), "<absent>")
        XCTAssertEqual(SafeFile.projectID("/projects/example"), "d5d3c44307e60784f1a5")
    }

    func testOversizedAndLinkedDeclarationsAreInvalidWithoutFallback() throws {
        let f = try fixture()
        try f.write("projects/web/package.json", "{\"engines\":{\"node\":\"22\"}}")
        try f.write("projects/web/.nvmrc", String(repeating: "2", count: 8193))
        XCTAssertEqual(try f.record("projects/web").status, "invalid")
        XCTAssertThrowsError(try SafeFile.read(f.path("projects/web/.nvmrc"), limit: 8192))
        try FileManager.default.removeItem(atPath: f.path("projects/web/.nvmrc"))
        try f.write("outside/version", "22\n")
        try FileManager.default.createSymbolicLink(atPath: f.path("projects/web/.nvmrc"), withDestinationPath: f.path("outside/version"))
        XCTAssertEqual(try f.record("projects/web").status, "invalid")
    }

    func testEightMiBCacheCanBeReadAndReplacedButLargerWritesAreRejected() throws {
        let f = try fixture()
        try f.write("cache/releases.json", "{}")
        let file = f.path("cache/releases.json")
        let limit = 8 * 1024 * 1024
        let contents = String(repeating: "x", count: limit)
        try SafeFile.write(file, text: contents, expected: SafeFile.digest("{}"), limit: limit)
        XCTAssertEqual(try SafeFile.read(file, limit: limit)?.utf8.count, limit)
        XCTAssertThrowsError(try SafeFile.read(file))
        XCTAssertThrowsError(try SafeFile.write(file, text: contents + "x", limit: limit))
        try SafeFile.write(file, text: "{\"rows\":[]}", expected: SafeFile.digest(contents), limit: limit)
        XCTAssertEqual(try SafeFile.read(file), "{\"rows\":[]}")
    }

    func testChangedProjectDirectoryCannotBeWrittenThroughSymlink() throws {
        let f = try fixture()
        try f.write("projects/web/package.json", "{}")
        let original = try f.record("projects/web")
        try FileManager.default.moveItem(atPath: original.path, toPath: f.path("projects/moved"))
        try f.write("outside/.nvmrc", "20\n")
        try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: f.path("outside"))
        XCTAssertThrowsError(try f.service.preview(project: original, destination: ".nvmrc", requested: "22", installed: f.installed, nvmDir: f.nvmDir))
        XCTAssertEqual(try SafeFile.read(f.path("outside/.nvmrc")), "20\n")
    }

    func testScanIncludesNestedWorkspacesDeduplicatesAndSkipsDependenciesAndLinks() async throws {
        let f = try fixture()
        try f.write("projects/mono/package.json", "{}")
        try f.write("projects/mono/packages/ui/.node-version", "22\n")
        try f.write("projects/mono/node_modules/dependency/package.json", "{}")
        try f.write("projects/.hidden/package.json", "{}")
        try f.write("projects/build/package.json", "{}")
        try f.write("outside/package.json", "{}")
        try FileManager.default.createSymbolicLink(atPath: f.path("projects/link"), withDestinationPath: f.path("outside"))
        let result = try await ProjectScanner.discover(roots: [f.path("projects"), f.path("projects")])
        XCTAssertEqual(result.projects, [f.path("projects/mono"), f.path("projects/mono/packages/ui")])
        XCTAssertFalse(result.limited)
        let limited = try await ProjectScanner.discover(roots: [f.path("projects")], maxDirectories: 1)
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(limited.visited, 1)
        let missing = try await ProjectScanner.discover(roots: [f.path("missing")])
        XCTAssertEqual(missing.errors.first?.code, "ENOENT")
    }

    func testScanHonorsCancellation() async throws {
        let f = try fixture()
        try f.write("projects/web/package.json", "{}")
        let task = Task {
            try Task.checkCancellation()
            return try await ProjectScanner.discover(roots: [f.path("projects")])
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan should throw") }
        catch is CancellationError { }
    }
}
