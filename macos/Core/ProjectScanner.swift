import Foundation
import Darwin

public enum ProjectScanner {
    public static let exclusions: Set<String> = [
        "node_modules", ".git", ".pnpm", ".yarn", "dist", "build", "target", "coverage", "output",
        ".next", ".nuxt", ".cache", "vendor", "Pods", "DerivedData", ".venv", "venv", "fixtures",
        "mocks", "Library", ".Trash"
    ]

    public static func discover(roots: [String], maxDirectories: Int = 50_000, onProgress: @Sendable (ScanState) -> Void = { _ in }) async throws -> ScanResult {
        var queue = roots
        var cursor = 0
        var seen: Set<String> = []
        var projects: Set<String> = []
        var errors: [ScanIssue] = []
        var visited = 0
        var limited = false
        while cursor < queue.count {
            try Task.checkCancellation()
            if visited >= maxDirectories { limited = true; break }
            let directory = queue[cursor]
            cursor += 1
            if !seen.insert(directory).inserted { continue }
            let entries: [Entry]
            do { entries = try contents(directory) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if errors.count < 100 {
                    let code = (error as? ReadError)?.code ?? EIO
                    errors.append(ScanIssue(path: directory, code: codeName(code)))
                }
                continue
            }
            visited += 1
            if entries.contains(where: { $0.isFile && ["package.json", ".nvmrc", ".node-version"].contains($0.name) }) {
                projects.insert(directory)
            }
            for entry in entries where entry.isDirectory && !entry.name.hasPrefix(".") && !exclusions.contains(entry.name) {
                queue.append((directory as NSString).appendingPathComponent(entry.name))
            }
            if visited % 25 == 0 {
                onProgress(state(visited: visited, found: projects.count, errors: errors))
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        onProgress(state(visited: visited, found: projects.count, errors: errors))
        return ScanResult(projects: projects.sorted(), visited: visited, errors: errors, limited: limited)
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
        let isFile: Bool
    }
    private struct ReadError: Error { let code: Int32 }

    private static func contents(_ path: String) throws -> [Entry] {
        guard !path.contains("\0") else { throw ReadError(code: EINVAL) }
        // Reject a directory that became a symlink after it was queued.
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ReadError(code: errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ReadError(code: ENOTDIR) }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReadError(code: errno) }
        guard let handle = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw ReadError(code: code)
        }
        defer { closedir(handle) }
        var result: [Entry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { throw ReadError(code: errno) }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var child = stat()
            guard fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            result.append(Entry(name: name, isDirectory: (child.st_mode & S_IFMT) == S_IFDIR, isFile: (child.st_mode & S_IFMT) == S_IFREG))
        }
        return result
    }

    private static func state(visited: Int, found: Int, errors: [ScanIssue]) -> ScanState {
        var result = ScanState()
        result.state = "running"
        result.visited = visited
        result.found = found
        result.errors = errors
        return result
    }

    private static func codeName(_ code: Int32) -> String {
        switch code {
        case EACCES: return "EACCES"
        case EPERM: return "EPERM"
        case ENOENT: return "ENOENT"
        case ENOTDIR: return "ENOTDIR"
        case ELOOP: return "ELOOP"
        default: return "POSIX_\(code)"
        }
    }
}
