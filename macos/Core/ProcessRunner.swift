import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Owns one process group. The group leader remains unreaped until every scheduled
/// signal has been sent, so cancellation never targets a recycled process ID.
public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String] = [],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           directory: String? = nil, timeout: TimeInterval = 120,
                           outputLimit: Int = 8 * 1024 * 1024, terminationGrace: TimeInterval = 3,
                           onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ProcessResult {
        let execution = ProcessExecution(executable, arguments, environment, directory, timeout,
                                         outputLimit, terminationGrace, onOutput)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        }, onCancel: { execution.cancel() })
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let directory: String?
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let grace: TimeInterval
    private let onOutput: @Sendable (String) -> Void
    private var pid: pid_t = 0
    private var finished = false
    private var stoppedAt: Date?
    private var failure: String?
    private var cancelled = false
    private var stdout = Data()
    private var stderr = Data()

    init(_ executable: String, _ arguments: [String], _ environment: [String: String],
         _ directory: String?, _ timeout: TimeInterval, _ outputLimit: Int,
         _ grace: TimeInterval, _ onOutput: @escaping @Sendable (String) -> Void) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.directory = directory; self.timeout = timeout; self.outputLimit = max(1, outputLimit)
        self.grace = max(0.05, grace); self.onOutput = onOutput
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        cancelled = true
        stopLocked(nil)
    }

    private func stopLocked(_ reason: String?) {
        if let reason, failure == nil { failure = reason }
        if stoppedAt == nil { stoppedAt = Date() }
        if pid > 1 { _ = Darwin.kill(-pid, SIGTERM) }
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try self.execute()) }
            catch { continuation.resume(throwing: error) }
        }
    }

    private func execute() throws -> ProcessResult {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard Darwin.pipe(&out) == 0 else { throw AppError("无法创建进程输出管道") }
        guard Darwin.pipe(&err) == 0 else {
            Darwin.close(out[0]); Darwin.close(out[1]); throw AppError("无法创建进程错误管道")
        }
        var owned = out + err
        defer { for fd in owned { Darwin.close(fd) } }
        for fd in owned { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AppError("无法初始化进程") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AppError("无法初始化进程属性") }
        defer { posix_spawnattr_destroy(&attributes) }
        func check(_ code: Int32) throws {
            if code != 0 { throw AppError("启动进程失败：\(String(cString: strerror(code)))") }
        }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))
        for fd in owned { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let directory { try check(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var empty = sigset_t(); sigemptyset(&empty)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGHUP] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigmask(&attributes, &empty))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        lock.lock()
        if cancelled { finished = true; lock.unlock(); throw CancellationError() }
        var child: pid_t = 0
        let code = posix_spawn(&child, executable, &actions, &attributes, &argv, &env)
        if code == 0 { pid = child }
        lock.unlock()
        try check(code)
        Darwin.close(out[1]); Darwin.close(err[1]); owned = [out[0], err[0]]
        let drains = DispatchGroup()
        for (fd, isError) in [(out[0], false), (err[0], true)] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { drains.leave() }
                var bytes = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    let chunk = Data(bytes.prefix(count))
                    self.lock.lock()
                    let room = max(0, self.outputLimit - self.stdout.count - self.stderr.count)
                    if isError { self.stderr.append(chunk.prefix(room)) } else { self.stdout.append(chunk.prefix(room)) }
                    if count > room { self.stopLocked("进程输出超过限制") }
                    self.lock.unlock()
                    if room > 0 { self.onOutput(String(decoding: chunk.prefix(room), as: UTF8.self)) }
                }
            }
        }
        let began = Date()
        var observedExit: Date?
        var waitFailure = false
        while true {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0 && info.si_pid == child && observedExit == nil { observedExit = Date() }
            if result != 0 && errno != EINTR { waitFailure = true; break }
            lock.lock()
            if Date().timeIntervalSince(began) > timeout && stoppedAt == nil { stopLocked("进程运行超时") }
            let stopTime = stoppedAt
            lock.unlock()
            if let stopTime {
                // Always finish escalation before reaping the group leader.
                if Date().timeIntervalSince(stopTime) >= grace {
                    _ = Darwin.kill(-child, SIGKILL)
                    break
                }
            } else if let observedExit {
                // An exited shell must not leave a background downloader behind.
                _ = Darwin.kill(-child, SIGTERM)
                if Date().timeIntervalSince(observedExit) >= 0.05 {
                    _ = Darwin.kill(-child, SIGKILL)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        var status: Int32 = 0
        // Serialize the final reap with cancel(): no signal may observe the old
        // PID after the kernel has made it available for reuse.
        lock.lock()
        if !waitFailure {
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
        finished = true; pid = 0; lock.unlock()
        drains.wait()
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if let failure { throw AppError(failure) }
        if waitFailure { throw AppError("无法读取进程退出状态") }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ProcessResult(status: exitCode, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }
}
