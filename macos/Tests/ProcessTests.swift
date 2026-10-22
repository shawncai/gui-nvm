import XCTest
import Darwin
@testable import GUINVMCore

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ value: String) { lock.lock(); text += value; lock.unlock() }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return text }
}

final class ProcessTests: XCTestCase {
    func testArgumentsOutputAndExitStatus() async throws {
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "printf '%s' \"$1\"; printf 'problem' >&2; exit 7", "test", "a; b $(not-a-command)"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "a; b $(not-a-command)")
        XCTAssertEqual(result.stderr, "problem")
    }

    func testCancellationKillsRealChildProcess() async throws {
        let output = ProcessOutput()
        let operation = Task {
            try await ProcessRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; sleep 60 & child=$!; echo \"$child\"; wait \"$child\""],
                                        timeout: 10, terminationGrace: 0.15, onOutput: { output.append($0) })
        }
        var child: pid_t?
        for _ in 0..<100 {
            child = Int32(output.read().trimmingCharacters(in: .whitespacesAndNewlines))
            if child != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let child else { operation.cancel(); _ = try? await operation.value; XCTFail("没有收到子进程 PID"); return }
        XCTAssertEqual(kill(child, 0), 0)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("取消应抛出 CancellationError") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            if kill(child, 0) != 0 && errno == ESRCH { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(kill(child, 0), -1, "真正的 sleep 子进程仍然存在")
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutAndOutputLimit() async throws {
        do {
            _ = try await ProcessRunner.run("/bin/sleep", arguments: ["60"], timeout: 0.05, terminationGrace: 0.05)
            XCTFail("应触发超时")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        do {
            _ = try await ProcessRunner.run("/usr/bin/yes", timeout: 2, outputLimit: 1024, terminationGrace: 0.05)
            XCTFail("应触发输出限制")
        } catch { XCTAssertTrue(error.localizedDescription.contains("输出超过限制")) }
    }

    func testProxyParserUsesEnabledValidProxy() {
        XCTAssertEqual(Network.systemProxy("HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 7890\n"), "http://127.0.0.1:7890")
        XCTAssertNil(Network.systemProxy("HTTPSEnable : 1\nHTTPSProxy : host;echo\nHTTPSPort : 7890\n"))
        XCTAssertNil(Network.systemProxy("HTTPSEnable : 1\nHTTPSProxy : localhost\nHTTPSPort : 65536\n"))
    }
}
