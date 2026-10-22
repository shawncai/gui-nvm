import Foundation
import CryptoKit
import Darwin

public enum SafeFile {
    public static func digest(_ text: String?) -> String {
        var tagged = Data([text == nil ? 0 : 1])
        if let text { tagged.append(contentsOf: text.utf8) }
        return hash(tagged)
    }

    public static func projectID(_ path: String) -> String { String(hash(Data(path.utf8)).prefix(20)) }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func directory(_ path: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.contains("\0") else {
            throw AppError("目录路径无效")
        }
        let expanded: String
        if path == "~" { expanded = FileManager.default.homeDirectoryForCurrentUser.path }
        else if path.hasPrefix("~/") { expanded = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path }
        else { expanded = path }
        guard let resolved = realpath(expanded, nil) else { throw failure("无法访问目录", path: expanded) }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0 else { throw failure("无法读取目录", path: expanded) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AppError("请选择目录：\(expanded)") }
        return String(cString: resolved)
    }

    public static func read(_ path: String, limit: Int = 1_048_576) throws -> String? {
        guard !path.contains("\0"), limit >= 0, limit < Int.max else { throw AppError("文件路径或大小限制无效") }
        return try readAt(AT_FDCWD, name: path, displayPath: path, limit: limit)?.text
    }

    public static func write(_ path: String, text: String, expected: String? = nil, limit: Int = 1_048_576) throws {
        guard !path.contains("\0"), limit >= 0, limit < Int.max else { throw AppError("文件路径或大小限制无效") }
        guard text.utf8.count <= limit else { throw AppError("文件超过大小限制：\(path)") }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw AppError("文件路径无效") }
        let parent = url.deletingLastPathComponent().path
        let directoryFD = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw failure("无法打开写入目录", path: parent) }
        defer { close(directoryFD) }

        let before = try readAt(directoryFD, name: name, displayPath: path, limit: limit)
        let revision = digest(before?.text)
        if let expected, expected != revision { throw AppError("文件已被外部修改，请刷新后重试") }

        let temporary = ".gui-nvm-\(UUID().uuidString).tmp"
        let mode = before?.mode ?? mode_t(0o600)
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw failure("无法创建临时文件", path: path) }
        defer {
            close(descriptor)
            unlinkat(directoryFD, temporary, 0)
        }
        guard fchmod(descriptor, mode) == 0 else { throw failure("无法保留文件权限", path: path) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("文件写入失败", path: path)
                }
                guard count > 0 else { throw AppError("文件写入未完成：\(path)") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure("无法同步文件", path: path) }

        // Read the destination through the same directory descriptor immediately
        // before replacement, refusing symlinks introduced during the write.
        let latest = try readAt(directoryFD, name: name, displayPath: path, limit: limit)
        guard digest(latest?.text) == revision else { throw AppError("文件已被外部修改，请刷新后重试") }
        var heldDirectory = stat()
        var currentDirectory = stat()
        guard fstat(directoryFD, &heldDirectory) == 0,
              lstat(parent, &currentDirectory) == 0,
              (currentDirectory.st_mode & S_IFMT) == S_IFDIR,
              heldDirectory.st_dev == currentDirectory.st_dev,
              heldDirectory.st_ino == currentDirectory.st_ino else {
            throw AppError("写入目录已变化，请重新预览")
        }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw failure("无法保存文件", path: path) }
        _ = fsync(directoryFD)
    }

    private struct Contents {
        let text: String
        let mode: mode_t
    }

    private static func readAt(_ directoryFD: Int32, name: String, displayPath: String, limit: Int) throws -> Contents? {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw AppError("不能读取或覆盖符号链接文件：\(displayPath)") }
            throw failure("无法读取文件", path: displayPath)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("无法检查文件", path: displayPath) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
            throw AppError("文件类型或大小不受支持：\(displayPath)")
        }
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        var size = 0
        try buffer.withUnsafeMutableBytes { bytes in
            while size < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: size), bytes.count - size)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("文件读取失败", path: displayPath)
                }
                if count == 0 { break }
                size += count
            }
        }
        guard size <= limit else { throw AppError("文件超过大小限制：\(displayPath)") }
        return Contents(text: String(decoding: buffer.prefix(size), as: UTF8.self), mode: info.st_mode & 0o777)
    }

    private static func failure(_ message: String, path: String, code: Int32 = errno) -> AppError {
        AppError("\(message)：\(path)（\(String(cString: strerror(code)))）")
    }
}
