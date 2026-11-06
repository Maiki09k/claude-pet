import Foundation

/// What the pet shows, from "needs you" down to "fast asleep".
enum Mood: String, CaseIterable, Sendable {
    case asking, working, done, idle, sleeping
}

struct ActivitySnapshot: Equatable, Sendable {
    var mood: Mood = .sleeping
    var working = 0
    var asking = 0
    /// Tool of the session that started its current step most recently.
    var tool: String?
    var lastActivity: Date?
    /// Claude and Codex sessions that are busy, waiting or just finished, most urgent first.
    var sessions: [SessionStatus] = []
    /// Codex's overall state for the notch; Clawd and `mood` stay Claude's own.
    var codex: Mood?
}

enum Agent: String, Sendable {
    case claude, codex
}

/// One conversation as the notch lists it: its title from the sidebar and what it is doing.
struct SessionStatus: Equatable, Sendable, Identifiable {
    let id: String
    let agent: Agent
    let title: String
    let mood: Mood
    let since: Date
    /// What it asks while it waits for Maik.
    var question: PendingQuestion?
    /// Once done: the first line of its last answer.
    var summary: String?
}

struct PendingQuestion: Equatable, Sendable {
    let title: String
    let options: [String]
}

/// Reads the tail of every recently touched Claude Code transcript under
/// ~/.claude/projects and works out what each session is doing. Read-only.
enum ActivityScanner {
    static let projectsDir = URL.homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)

    /// Tools that answer within a second. Still pending after `approvalDelay`
    /// means the session is waiting for an approval click.
    static let quickTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Grep", "Glob"]
    static let approvalDelay: TimeInterval = 25
    static let doneFor: TimeInterval = 2 * 60
    static let idleFor: TimeInterval = 20 * 60
    /// A session that looks busy but wrote nothing for this long was abandoned.
    static let staleAfter: TimeInterval = 20 * 60
    /// An open question stays on screen this long, even while nothing else happens.
    static let askingFor: TimeInterval = 3 * 3600

    private enum Session {
        case working(tool: String?, since: Date)
        case asking(PendingQuestion?)
        case finished(Date)
    }

    /// Parsing is independent of the clock. Quiet files can reuse their result while the
    /// approval, completion and expiry rules below still advance on every scan.
    private struct CachedTail {
        let modified: Date
        let size: UInt64
        let result: (Session, String?)?
    }
    private nonisolated(unsafe) static var tails: [String: CachedTail] = [:]
    private static let scanLock = NSLock()

    static func scan(now: Date = .now, projects: URL = projectsDir,
                     codex: URL = codexSessions, index: URL = codexIndex) -> ActivitySnapshot {
        // The detached UI task and diagnostic callers share the parser caches.
        scanLock.lock()
        defer { scanLock.unlock() }
        var snapshot = ActivitySnapshot()
        var lastFinished: Date?
        var newestStep = Date.distantPast
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var recentPaths: Set<String> = []

        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                snapshot.lastActivity = max(snapshot.lastActivity ?? modified, modified)
                let age = now.timeIntervalSince(modified)
                guard age < askingFor else { continue }
                recentPaths.insert(file.path)
                guard let (parsed, title) = state(of: file, modified: modified, now: now) else { continue }
                let session: Session
                if case .working(let tool?, let since) = parsed,
                   quickTools.contains(tool), now.timeIntervalSince(since) > approvalDelay {
                    session = .asking(PendingQuestion(title: "Wartet auf deine Freigabe (\(tool))", options: []))
                } else { session = parsed }
                // Quiet for a while: only an open question still counts.
                if age >= staleAfter, case .asking = session {} else if age >= staleAfter { continue }
                let id = file.deletingPathExtension().lastPathComponent
                let name = title ?? "Session"
                switch session {
                case .asking(let question):
                    snapshot.asking += 1
                    snapshot.sessions.append(SessionStatus(id: id, agent: .claude, title: name, mood: .asking, since: modified,
                                                           question: question))
                case .working(let tool, let since):
                    snapshot.working += 1
                    snapshot.sessions.append(SessionStatus(id: id, agent: .claude, title: name, mood: .working, since: since))
                    if since > newestStep {
                        newestStep = since
                        snapshot.tool = tool
                    }
                case .finished(let at):
                    lastFinished = max(lastFinished ?? at, at)
                    if now.timeIntervalSince(at) < doneFor {
                        snapshot.sessions.append(SessionStatus(id: id, agent: .claude, title: name, mood: .done, since: at,
                                                               summary: Summary.last(in: file, modified: modified, agent: .claude)))
                    }
                }
            }
        }
        scanCodex(now: now, sessions: codex, index: index, recentPaths: &recentPaths, into: &snapshot)
        tails = tails.filter { recentPaths.contains($0.key) }
        titles = titles.filter { recentPaths.contains($0.key) }
        let urgency: [Mood: Int] = [.asking: 0, .done: 1, .working: 2]
        snapshot.sessions.sort { (urgency[$0.mood] ?? 3, $1.since) < (urgency[$1.mood] ?? 3, $0.since) }

        snapshot.mood =
            if snapshot.asking > 0 { .asking }
            else if snapshot.working > 0 { .working }
            else if let lastFinished, now.timeIntervalSince(lastFinished) < doneFor { .done }
            else if let last = snapshot.lastActivity, now.timeIntervalSince(last) < idleFor { .idle }
            else { .sleeping }
        return snapshot
    }

    // MARK: Codex

    static let codexSessions = URL.homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
    static let codexIndex = URL.homeDirectory.appending(path: ".codex/session_index.jsonl")
    private nonisolated(unsafe) static var codexNames: (path: String, modified: Date, names: [String: String]) = ("", .distantPast, [:])

    /// Codex (in the ChatGPT app or the CLI) writes one rollout file per thread under sessions/YYYY/MM/DD.
    private static func scanCodex(now: Date, sessions: URL, index: URL,
                                  recentPaths: inout Set<String>, into snapshot: inout ActivitySnapshot) {
        let calendar = Calendar.current
        var files: [URL] = []
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appending(path: String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            files += (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        var moods: [Mood] = []
        for file in files where file.pathExtension == "jsonl" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) < askingFor else { continue }
            recentPaths.insert(file.path)
            // rollout-2026-10-25T09-33-52-<thread id>.jsonl
            let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
            let name = codexTitles(in: index)[id] ?? "Codex"
            // Codex asks asynchronously and often finishes its turn right after, so an open
            // question wins over whatever the last line says.
            let question = CodexQuestions.open(in: file)
            var mood: Mood?
            var since = modified
            if let question {
                mood = .asking
                snapshot.sessions.append(SessionStatus(id: id, agent: .codex, title: name, mood: .asking, since: modified, question: question))
            } else if now.timeIntervalSince(modified) < staleAfter,
                      let (session, _) = tail(of: file, modified: modified, now: now, interpret: codexSession(from:modified:now:), wantsTitle: false) {
                switch session {
                case .asking(let pending): mood = .asking; snapshot.sessions.append(SessionStatus(id: id, agent: .codex, title: name, mood: .asking, since: modified, question: pending))
                case .working(_, let at): mood = .working; since = at
                case .finished(let at) where now.timeIntervalSince(at) < doneFor: mood = .done; since = at
                case .finished: break
                }
                if let mood, mood != .asking {
                    snapshot.sessions.append(SessionStatus(id: id, agent: .codex, title: name, mood: mood, since: since,
                                                           summary: mood == .done ? Summary.last(in: file, modified: modified, agent: .codex) : nil))
                }
            }
            if let mood { moods.append(mood) }
        }
        snapshot.codex = [.asking, .working, .done].first { moods.contains($0) }
    }

    /// Thread names from Codex's index, re-read only when the index changes.
    private static func codexTitles(in index: URL) -> [String: String] {
        guard let modified = try? index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return [:] }
        if index.path == codexNames.path, modified == codexNames.modified { return codexNames.names }
        var names: [String: String] = [:]
        if let handle = try? FileHandle(forReadingFrom: index) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
            for line in (try? handle.readToEnd())?.split(separator: UInt8(ascii: "\n")) ?? [] {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let id = entry["id"] as? String, let name = entry["thread_name"] as? String else { continue }
                names[id] = name
            }
        }
        codexNames = (index.path, modified, names)
        return names
    }

    /// Codex events: a finished or aborted task ends the turn, approval requests wait for Maik,
    /// any other step means it is still working. Bookkeeping lines say nothing.
    private static func codexSession(from line: Data, modified: Date, now: Date) -> Session? {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = entry["type"] as? String else { return nil }
        let at = (entry["timestamp"] as? String).flatMap(parseISODate) ?? modified
        switch type {
        case "event_msg":
            let kind = (entry["payload"] as? [String: Any])?["type"] as? String ?? ""
            switch kind {
            case "task_complete": return .finished(at)
            case "turn_aborted": return .finished(.distantPast)
            case "token_count", "thread_settings_applied": return nil
            default:
                return kind.hasSuffix("approval_request")
                    ? .asking(PendingQuestion(title: "Wartet auf deine Freigabe", options: []))
                    : .working(tool: nil, since: at)
            }
        case "response_item":
            return .working(tool: nil, since: at)
        default:
            return nil
        }
    }

    /// Titles change rarely, so a minute-old one is good enough and spares re-reading.
    private nonisolated(unsafe) static var titles: [String: (title: String?, at: Date)] = [:]

    private static func state(of file: URL, modified: Date, now: Date) -> (Session, String?)? {
        tail(of: file, modified: modified, now: now, interpret: session(from:modified:now:), wantsTitle: true)
    }

    /// Walks the file backwards until `interpret` recognises what the session is doing,
    /// then a little further up for the conversation title the Claude app writes after each turn.
    private static func tail(of file: URL, modified: Date, now: Date,
                             interpret: (Data, Date, Date) -> Session?, wantsTitle: Bool) -> (Session, String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        // Size also detects an append or truncation when modification times coincide.
        // Title lookups retain their existing one-minute refresh window, including renames.
        if let hit = tails[file.path], hit.modified == modified, hit.size == size,
           !wantsTitle || titles[file.path].map({ now.timeIntervalSince($0.at) < 60 }) == true { return hit.result }

        let titleHit = wantsTitle ? titles[file.path].flatMap { now.timeIntervalSince($0.at) < 60 ? $0 : nil } : nil
        let needsTitle = wantsTitle && titleHit == nil
        var title = titleHit?.title
        var found: Session?
        // Request blobs can be megabytes long, so widen the window until a full entry fits.
        var window: UInt64 = 64 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"))
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                let entry = Data(line)
                if needsTitle, title == nil { title = customTitle(in: entry) }
                if found == nil { found = interpret(entry, modified, now) }
                if found != nil, title != nil || !needsTitle { break }
            }
            // The state may sit megabytes up; the title is only worth the first megabyte.
            let limit: UInt64 = found == nil ? 8 * 1024 * 1024 : 1024 * 1024
            if (found != nil && (title != nil || !needsTitle)) || start == 0 || window >= limit { break }
            window *= 4
        }
        if needsTitle { titles[file.path] = (title, now) }
        let result = found.map { ($0, title) }
        tails[file.path] = CachedTail(modified: modified, size: size, result: result)
        return result
    }

    /// The first question of an AskUserQuestion call with its option labels.
    private static func askedQuestion(in input: [String: Any]?) -> PendingQuestion? {
        guard let first = (input?["questions"] as? [[String: Any]])?.first,
              let title = first["question"] as? String else { return nil }
        let options = (first["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
        return PendingQuestion(title: title, options: options)
    }

    /// Title lines are short; checking the prefix first keeps megabyte request lines from being parsed twice.
    private static func customTitle(in line: Data) -> String? {
        guard line.count < 2000, line.starts(with: Data(#"{"type":"custom-title""#.utf8)),
              let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let title = entry["customTitle"] as? String, !title.isEmpty else { return nil }
        return title
    }

    /// nil means "this entry says nothing about the state, keep looking".
    private static func session(from line: Data, modified: Date, now: Date) -> Session? {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let type = entry["type"] as? String
        let at = (entry["timestamp"] as? String).flatMap(parseISODate) ?? modified

        if type == "system" {
            return entry["subtype"] as? String == "stop_hook_summary" ? .finished(at) : nil
        }
        guard type == "user" || type == "assistant",
              entry["isSidechain"] as? Bool != true,
              entry["isMeta"] as? Bool != true else { return nil }

        let message = entry["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []

        if type == "assistant" {
            if let use = blocks.last(where: { $0["type"] as? String == "tool_use" }), let tool = use["name"] as? String {
                if tool == "AskUserQuestion" { return .asking(askedQuestion(in: use["input"] as? [String: Any])) }
                if tool == "ExitPlanMode" { return .asking(PendingQuestion(title: "Plan wartet auf deine Freigabe", options: [])) }
                return .working(tool: tool, since: at)
            }
            switch message?["stop_reason"] as? String {
            case nil, "tool_use", "pause_turn": return .working(tool: nil, since: at)
            default: return .finished(at)
            }
        }

        let text = (message?["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined()
        // Stopped by hand: nothing to celebrate, go straight to idle.
        if text.hasPrefix("[Request interrupted") { return .finished(.distantPast) }
        if text.hasPrefix("<local-command-std") { return .finished(at) }
        return .working(tool: nil, since: at)
    }
}

/// The first line of a session's last answer, for the "fertig" pop-up. Read from the end of the
/// transcript once per change of the file.
enum Summary {
    private nonisolated(unsafe) static var cache: [String: (modified: Date, text: String?)] = [:]

    static func last(in file: URL, modified: Date, agent: Agent) -> String? {
        if let hit = cache[file.path], hit.modified == modified { return hit.text }
        let text = read(file, agent: agent)
        cache[file.path] = (modified, text)
        return text
    }

    private static func read(_ file: URL, agent: Agent) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var window: UInt64 = 128 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            var lines = data.split(separator: UInt8(ascii: "\n"))
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                if let text = agent == .claude ? claudeText(Data(line)) : codexText(Data(line)) { return firstLine(text) }
            }
            if start == 0 || window >= 4 * 1024 * 1024 { return nil }
            window *= 4
        }
    }

    private static func claudeText(_ line: Data) -> String? {
        guard line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
              let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              entry["isSidechain"] as? Bool != true,
              let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func codexText(_ line: Data) -> String? {
        guard line.range(of: Data(#""type":"event_msg""#.utf8)) != nil,
              let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = entry["payload"] as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "task_complete": return payload["last_agent_message"] as? String
        case "agent_message": return payload["message"] as? String
        default: return nil
        }
    }

    /// The opening line without Markdown, which is where the answer usually sits.
    private static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("---") } ?? ""
        var clean = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // Heading, quote and list markers, not the digits of "3 Fotos geladen".
        clean = clean.replacingOccurrences(of: #"^(#+\s*|>\s*|[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return clean.isEmpty ? nil : String(clean.prefix(180))
    }
}

/// Open Codex questions (`request_user_input_async`) per rollout file. Rollouts only grow and can be
/// hundreds of megabytes with images inside, so each file is read once from near its end and
/// afterwards only the bytes appended since; only lines carrying a marker are parsed.
enum CodexQuestions {
    private struct Progress {
        var offset: UInt64
        var open: [(id: String, question: PendingQuestion)]
    }

    private nonisolated(unsafe) static var progress: [String: Progress] = [:]
    /// Questions older than this many bytes back were answered long ago.
    private static let firstLook: UInt64 = 48 * 1024 * 1024
    private static let ask = Data("request_user_input_async".utf8)
    private static let reply = Data("send_user_message_question_reply".utf8)
    private static let userTurn = Data(#""role":"user""#.utf8)

    static func open(in file: URL) -> PendingQuestion? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var state = progress[file.path] ?? Progress(offset: size > firstLook ? size - firstLook : 0, open: [])
        if size < state.offset { state = Progress(offset: 0, open: []) }

        var carry = Data()
        var position = state.offset
        try? handle.seek(toOffset: position)
        // On the first look, skip to the next full line.
        var skipPartial = position > 0 && progress[file.path] == nil
        while position < size {
            let chunk = handle.readData(ofLength: Int(min(8 * 1024 * 1024, size - position)))
            if chunk.isEmpty { break }
            position += UInt64(chunk.count)
            var data = carry + chunk
            guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { carry = data; continue }
            carry = data[(lastBreak + 1)...]
            data = data[..<lastBreak]
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if skipPartial, !lines.isEmpty { lines.removeFirst(); skipPartial = false }
            for line in lines where line.range(of: ask) != nil || line.range(of: reply) != nil || line.range(of: userTurn) != nil {
                apply(Data(line), to: &state)
            }
        }
        // Only complete lines count as read; a half-written last line is read again next time.
        state.offset = position - UInt64(carry.count)
        progress[file.path] = state
        return state.open.last?.question
    }

    private static func apply(_ line: Data, to state: inout Progress) {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              entry["type"] as? String == "response_item",
              let payload = entry["payload"] as? [String: Any] else { return }
        if payload["type"] as? String == "function_call", payload["name"] as? String == "request_user_input_async",
           let id = payload["call_id"] as? String,
           let arguments = (payload["arguments"] as? String)?.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any],
           let first = (parsed["questions"] as? [[String: Any]])?.first,
           let title = first["title"] as? String {
            state.open.append((id, PendingQuestion(title: title, options: first["options"] as? [String] ?? [])))
        } else if payload["type"] as? String == "message", payload["role"] as? String == "user" {
            // Maik answered: by the question card, or by simply writing back.
            state.open.removeAll()
        }
    }
}

/// Transcript timestamps carry milliseconds, the usage API microseconds.
func parseISODate(_ text: String) -> Date? {
    TranscriptDates.parse(text)
}

/// Formatter setup is expensive; reuse immutable configurations, with a lock because
/// activity scanning and the usage HTTP client can parse dates on different threads.
private enum TranscriptDates {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let seconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = fractional.date(from: text) { return date }
        return seconds.date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
}
