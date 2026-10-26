import Foundation

public struct AppError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct NodeRelease: Codable, Identifiable, Equatable, Sendable {
    public var id: String { version }
    public var version: String
    public var date: String
    public var phase: String
    public var description: String
    public var codename: String
    public var supportEnd: String?
    public var lts: Bool
    public var installed: Bool
    public var compatible: Bool
    public var files: [String]
    public init(version: String, date: String = "", phase: String = "Unknown", description: String = "支持状态待同步", codename: String = "", supportEnd: String? = nil, lts: Bool = false, installed: Bool = false, compatible: Bool = true, files: [String] = []) {
        self.version = version; self.date = date; self.phase = phase; self.description = description
        self.codename = codename; self.supportEnd = supportEnd; self.lts = lts
        self.installed = installed; self.compatible = compatible; self.files = files
    }
}

public struct ProjectRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var requested: String
    public var resolved: String?
    public var source: String
    public var file: String?
    public var inherited: Bool
    public var status: String
    public var error: String?
    public var revision: String
    public init(id: String, name: String, path: String, requested: String = "", resolved: String? = nil, source: String = "", file: String? = nil, inherited: Bool = false, status: String = "unconfigured", error: String? = nil, revision: String = "") {
        self.id = id; self.name = name; self.path = path; self.requested = requested; self.resolved = resolved
        self.source = source; self.file = file; self.inherited = inherited; self.status = status; self.error = error; self.revision = revision
    }
}

public struct ConfigPreview: Equatable, Sendable {
    public let projectID: String
    public let file: String
    public let before: String?
    public let after: String
    public let expected: String
    public let resolved: String
    public let requested: String
    public let destination: String
    public init(projectID: String, file: String, before: String?, after: String, expected: String, resolved: String, requested: String, destination: String) {
        self.projectID = projectID; self.file = file; self.before = before; self.after = after; self.expected = expected
        self.resolved = resolved; self.requested = requested; self.destination = destination
    }
}

public struct DefaultVersion: Equatable, Sendable {
    public var value: String
    public var expected: String
    public init(value: String = "", expected: String = "") { self.value = value; self.expected = expected }
}

public struct ScanIssue: Identifiable, Equatable, Sendable {
    public var id: String { path + code }
    public var path: String
    public var code: String
    public init(path: String, code: String) { self.path = path; self.code = code }
}

public struct ScanState: Equatable, Sendable {
    public var state = "idle"
    public var visited = 0
    public var found = 0
    public var errors: [ScanIssue] = []
    public var error: String?
    public init() {}
}

public struct ScanResult: Sendable {
    public let projects: [String]
    public let visited: Int
    public let errors: [ScanIssue]
    public let limited: Bool
    public init(projects: [String], visited: Int, errors: [ScanIssue], limited: Bool) {
        self.projects = projects; self.visited = visited; self.errors = errors; self.limited = limited
    }
}

public struct InstallTask: Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var state: String
    public var startedAt: Date
    public var endedAt: Date?
    public var log: String
    public var phase: String
    public var error: String?
    public var kind: String
    public var packageName: String?
    public var targetVersion: String?
    public init(id: String = UUID().uuidString, version: String, state: String = "running", startedAt: Date = Date(), endedAt: Date? = nil, log: String = "", phase: String = "下载并校验", error: String? = nil, kind: String = "nodeInstall", packageName: String? = nil, targetVersion: String? = nil) {
        self.id = id; self.version = version; self.state = state; self.startedAt = startedAt
        self.endedAt = endedAt; self.log = log; self.phase = phase; self.error = error
        self.kind = kind; self.packageName = packageName; self.targetVersion = targetVersion
    }
}

public enum GlobalPackageAction: String, Sendable {
    case remove, changeVersion
}

public struct GlobalPackageRecord: Identifiable, Equatable, Sendable {
    public var id: String { SafeFile.projectID(path) }
    public var nodeVersion: String
    public var name: String
    public var version: String
    public var path: String
    public var editable: Bool
    public var issue: String?
    public var revision: String
    public init(nodeVersion: String, name: String, version: String = "", path: String, editable: Bool = false, issue: String? = nil, revision: String = "") {
        self.nodeVersion = nodeVersion; self.name = name; self.version = version; self.path = path
        self.editable = editable; self.issue = issue; self.revision = revision
    }
}

public struct GlobalPackageSnapshot: Equatable, Sendable {
    public var rows: [GlobalPackageRecord] = []
    public var errors: [ScanIssue] = []
    public var scanning = false
    public var scannedAt: Date?
    public init() {}
}

public struct GlobalPackagePreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let nvmDir: String
    public let package: GlobalPackageRecord
    public let action: GlobalPackageAction
    public let targetVersion: String?
    public var allowScripts: Bool
    public init(id: UUID = UUID(), nvmDir: String, package: GlobalPackageRecord, action: GlobalPackageAction, targetVersion: String? = nil, allowScripts: Bool = false) {
        self.id = id; self.nvmDir = nvmDir; self.package = package; self.action = action
        self.targetVersion = targetVersion; self.allowScripts = allowScripts
    }
}

public struct RuntimeSnapshot: Sendable {
    public var installed: [NodeRelease] = []
    public var releases: [NodeRelease] = []
    public var defaultVersion = DefaultVersion()
    public var tasks: [InstallTask] = []
    public var catalogAt: String?
    public var catalogError: String?
    public var syncing = false
    public var globalPackages = GlobalPackageSnapshot()
    public init() {}
}

public struct AppSnapshot: Sendable {
    public var nvmDir = ""
    public var roots: [String] = []
    public var projects: [ProjectRecord] = []
    public var scan = ScanState()
    public var runtime = RuntimeSnapshot()
    public var notices: [String] = []
    public init() {}
}
