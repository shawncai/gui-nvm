import Foundation
import XCTest
@testable import GUINVMCore

final class SemverTests: XCTestCase, @unchecked Sendable {
    static var resourceURL: URL {
        Bundle(for: Self.self).resourceURL!.appendingPathComponent("node-semver", isDirectory: true)
    }

    func testVendoredRangesMatchExistingResolverCases() throws {
        let semver = try Semver(resourceURL: Self.resourceURL)
        let versions = ["v16.16.0", "v20.19.5", "v22.20.0", "v22.22.3", "v24.17.0"].sorted { semver.rcompare($0, $1) < 0 }
        let cases = [
            (">=20 <23", "v22.22.3"), ("^20.0.0", "v20.19.5"), ("~22.20.0", "v22.20.0"),
            ("16 || 20", "v20.19.5"), ("22.x", "v22.22.3"), ("22.x+build.1", "v22.22.3"),
            ("22.22.3+build.1", "v22.22.3"), ("20.19.5 - 22.22.3", "v22.22.3"),
            ("*", "v24.17.0"), ("v22.22.3", "v22.22.3"), ("  >=22 <23  ", "v22.22.3")
        ]
        for (range, expected) in cases {
            XCTAssertNotNil(semver.validRange(range), range)
            XCTAssertEqual(versions.first { semver.satisfies($0, range) }, expected, range)
        }
        for invalid in ["lts/*", ">=", "$(touch injected)", String(repeating: "2", count: 4097)] {
            XCTAssertNil(semver.validRange(invalid), invalid)
        }
        XCTAssertFalse(semver.satisfies("v24.0.0-rc.1", ">=20"))
        XCTAssertFalse(semver.satisfies("v22.22.3", ">=99"))
        XCTAssertFalse(semver.satisfies("garbage", "*"))
        XCTAssertLessThan(semver.rcompare("v24.17.0", "v22.22.3"), 0)
    }

    func testManifestRewriteKeepsInsertionOrderIndentationAndOtherEngines() throws {
        let semver = try Semver(resourceURL: Self.resourceURL)
        let original = "{\n\t\"z\": 1,\n\t\"name\": \"中文项目\",\n\t\"engines\": {\n\t\t\"pnpm\": \">=8\"\n\t},\n\t\"scripts\": {\n\t\t\"dev\": \"vite\"\n\t}\n}\n"
        let result = try semver.rewriteManifest(original, requested: ">=22 <25")
        XCTAssertTrue(result.contains("\n\t\"z\": 1,"))
        XCTAssertTrue(result.contains("\n\t\t\"node\": \">=22 <25\""))
        XCTAssertTrue(result.hasSuffix("\n"))
        XCTAssertLessThan(try XCTUnwrap(result.range(of: "\"z\"")?.lowerBound), try XCTUnwrap(result.range(of: "\"name\"")?.lowerBound))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let engines = try XCTUnwrap(json["engines"] as? [String: String])
        XCTAssertEqual(engines, ["node": ">=22 <25", "pnpm": ">=8"])
        XCTAssertEqual(json["scripts"] as? [String: String], ["dev": "vite"])
        for invalid in ["{ invalid", "[]", "null", "22", "\"text\""] {
            XCTAssertThrowsError(try semver.rewriteManifest(invalid, requested: "22"))
        }
    }

    func testUntrustedJSONAndArgumentsRemainData() throws {
        let semver = try Semver(resourceURL: Self.resourceURL)
        let requested = "22\"; globalThis.injected = true; //"
        let result = try semver.rewriteManifest("{\"__proto__\":{\"engines\":{\"node\":\"20\"}}}", requested: requested)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual((json["engines"] as? [String: String])?["node"], requested)
        XCTAssertEqual((json["__proto__"] as? [String: [String: String]])?["engines"]?["node"], "20")
        XCTAssertTrue(semver.satisfies("v22.22.3", "22.x"))
    }

    func testContextIsSerializedAcrossConcurrentCallers() async throws {
        let semver = try Semver(resourceURL: Self.resourceURL)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask { semver.validRange("^22.0.0") != nil && semver.satisfies("v22.22.3", "^22.0.0") && semver.rcompare("v24.17.0", "v22.22.3") < 0 }
            }
            var values: [Bool] = []
            for await result in group { values.append(result) }
            return values
        }
        XCTAssertEqual(results.count, 100)
        XCTAssertTrue(results.allSatisfy { $0 })
    }

    func testCommonJSLoaderRejectsExternalAndEscapingModules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gui-nvm-semver-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for request in ["fs", "../outside"] {
            try "module.exports = require('\(request)');".write(to: root.appendingPathComponent("index.js"), atomically: false, encoding: .utf8)
            XCTAssertThrowsError(try Semver(resourceURL: root))
        }
    }
}
