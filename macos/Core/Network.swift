import Foundation

public enum Network {
    public static let indexURL = "https://nodejs.org/dist/index.json"
    private static let proxyNames = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy"]

    public static func systemProxy(_ text: String) -> String? {
        func value(_ key: String) -> String? {
            let pattern = "(?m)^\\s*" + key + " : ([^\\r\\n]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for scheme in ["HTTPS", "HTTP"] {
            guard value(scheme + "Enable") == "1", let host = value(scheme + "Proxy"),
                  host.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil,
                  let portText = value(scheme + "Port"),
                  portText.range(of: "^[0-9]+$", options: .regularExpression) != nil,
                  let port = Int(portText), (1...65535).contains(port) else { continue }
            return "http://\(host):\(port)"
        }
        return nil
    }

    public static func environment(source: [String: String] = ProcessInfo.processInfo.environment) async -> [String: String] {
        var result = source.filter { proxyNames.contains($0.key) && !$0.value.isEmpty }
        if result.keys.contains(where: { !$0.lowercased().hasPrefix("no_proxy") }) { return result }
        if let response = try? await ProcessRunner.run("/usr/sbin/scutil", arguments: ["--proxy"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 2, outputLimit: 32768),
           response.status == 0, let proxy = systemProxy(response.stdout) {
            for name in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"] { result[name] = proxy }
        }
        return result
    }

    public static func fetchIndex() async throws -> Data {
        var env = await environment()
        try Task.checkCancellation()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let result = try await ProcessRunner.run("/usr/bin/curl", arguments: [
            "-q", "--http1.1", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
            "--proto-redir", "=https", "--max-time", "20", indexURL
        ], environment: env, timeout: 22, outputLimit: 8 * 1024 * 1024)
        guard result.status == 0 else { throw AppError(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "版本索引请求失败" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Data(result.stdout.utf8)
    }
}
