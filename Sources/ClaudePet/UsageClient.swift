import Foundation

struct UsageBar: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
}

enum UsageState: Equatable, Sendable {
    case loading
    case ready([UsageBar], fetched: Date)
    case needsLogin
    case failed(String)
}

/// Reads the plan limits from Anthropic with the Claude Code CLI login stored in the keychain.
/// It never writes credentials: when the access token is stale it lets the official CLI renew
/// it by running the local `/usage` command, then reads the keychain again.
actor UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private var lastRenewal = Date.distantPast

    private struct Token {
        let value: String
        let expiresAt: Date?
        var isExpired: Bool { expiresAt.map { $0 < .now.addingTimeInterval(60) } ?? false }
    }

    func fetch() async -> UsageState {
        if let token = await readToken(), !token.isExpired, let state = await request(token.value) {
            return state
        }
        guard await renewViaCLI(), let token = await readToken(), !token.isExpired else { return .needsLogin }
        return await request(token.value) ?? .needsLogin
    }

    private func readToken() async -> Token? {
        guard let data = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"]),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String, !value.isEmpty else { return nil }
        // The CLI has stored this both in seconds and in milliseconds over time.
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { raw in
            Date(timeIntervalSince1970: raw.doubleValue > 1e11 ? raw.doubleValue / 1000 : raw.doubleValue)
        }
        return Token(value: value, expiresAt: expiresAt)
    }

    /// Returns false when a renewal ran recently, so a logged-out CLI is not started every minute.
    private func renewViaCLI() async -> Bool {
        guard Date.now.timeIntervalSince(lastRenewal) > 10 * 60, let cli = Self.cliPath else { return false }
        lastRenewal = .now
        _ = await Shell.run(cli, ["-p", "/usage", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#], timeout: 60)
        return true
    }

    private static var cliPath: String? {
        let home = URL.homeDirectory.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// nil means the token was refused.
    private func request(_ token: String) async -> UsageState? {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudePet/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed("offline") }
        switch status {
        case 200: return .ready(Self.parse(data), fetched: .now)
        case 401, 403: return nil
        case 429: return .failed("zu viele Abfragen")
        default: return .failed("Fehler \(status)")
        }
    }

    static func parse(_ data: Data) -> [UsageBar] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let bars = root.compactMap { key, value -> UsageBar? in
            guard key.hasPrefix("five_hour") || key.hasPrefix("seven_day"), !key.contains("oauth_apps"),
                  let window = value as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageBar(id: key, label: label(for: key), percent: percent,
                            resetsAt: (window["resets_at"] as? String).flatMap(parseISODate))
        }
        let order = ["five_hour", "seven_day"]
        return bars.sorted { a, b in
            let rankA = order.firstIndex(of: a.id) ?? order.count
            let rankB = order.firstIndex(of: b.id) ?? order.count
            return rankA != rankB ? rankA < rankB : a.percent > b.percent
        }
    }

    private static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "Sitzung"
        case "seven_day": return "Woche"
        default:
            // Model-specific windows ("seven_day_opus") get just the model name, the row is narrow.
            return key
                .replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "five_hour_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
}

enum Shell {
    /// Runs a tool off the concurrency pool and returns stdout, or nil if it failed.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path, arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.currentDirectoryURL = .homeDirectory
        let home = URL.homeDirectory.path
        process.environment = [
            "HOME": home,
            "USER": NSUserName(),
            "LANG": "de_DE.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin:/opt/homebrew/bin"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
