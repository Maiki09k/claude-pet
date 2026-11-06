import AppKit
import Foundation

/// An AskUserQuestion that Claude Code handed to the notch through the PreToolUse hook.
struct AskRequest: Codable, Equatable, Identifiable {
    struct Question: Codable, Equatable {
        let question: String
        var header: String?
        let options: [Option]
        var multiSelect: Bool?
    }

    struct Option: Codable, Equatable {
        let label: String
        var description: String?
    }

    let id: String
    /// Claude Code's session id, which is also the transcript's file name.
    let session: String
    let questions: [Question]
    let deadline: Date
}

/// The hand-over between Claude Code and the running app. Claude Code starts `ClaudePet --ask-hook`
/// before every AskUserQuestion; the hook drops `<id>.json` here and waits for `<id>.answer.json`.
/// If none comes in time, or Maik picks "In Claude antworten", the hook steps aside and the
/// question appears in Claude as usual.
enum AskBridge {
    struct Reply: Codable {
        var answers: [String: String]?
        var skip: Bool?
    }

    static let directory = URL.homeDirectory.appending(path: "Library/Application Support/ClaudePet/Ask", directoryHint: .isDirectory)
    static let posted = Notification.Name("io.github.maiki09k.claudepet.ask")

    private static func requestFile(_ id: String) -> URL { directory.appending(path: "\(id).json") }
    private static func replyFile(_ id: String) -> URL { directory.appending(path: "\(id).answer.json") }

    // MARK: Hook side

    /// `ClaudePet --ask-hook`. Prints the PreToolUse decision when Maik answered in the notch,
    /// nothing otherwise. Always exits 0: a failing hook must never block Claude.
    static func runHook() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard Setting.on(Setting.askInNotch), Setting.on(Setting.notch), Setting.on(Setting.claude) else {
            log("übersprungen: in den Einstellungen aus")
            return 0
        }
        guard appIsRunning else {
            log("übersprungen: Claude Pet läuft nicht")
            return 0
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              payload["tool_name"] as? String == "AskUserQuestion",
              let toolInput = payload["tool_input"] as? [String: Any],
              toolInput["answers"] == nil,
              let raw = toolInput["questions"] as? [[String: Any]], !raw.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let questions = try? JSONDecoder().decode([AskRequest.Question].self, from: data),
              // Several picks per question stay in Claude, where they can be ticked properly.
              !questions.contains(where: { $0.multiSelect == true })
        else {
            log("übersprungen: Mehrfachauswahl oder unbekanntes Format")
            return 0
        }

        let wait = min(max(Setting.value(Setting.askSeconds), 5), 120)
        let id = (payload["tool_use_id"] as? String).map { $0.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }
            ?? UUID().uuidString
        let request = AskRequest(id: id, session: payload["session_id"] as? String ?? "", questions: questions,
                                 deadline: .now.addingTimeInterval(wait))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: requestFile(id), options: .atomic)
        } catch {
            return 0
        }
        defer {
            try? FileManager.default.removeItem(at: requestFile(id))
            try? FileManager.default.removeItem(at: replyFile(id))
        }
        DistributedNotificationCenter.default().postNotificationName(posted, object: id, userInfo: nil, deliverImmediately: true)
        let topic = String((questions.first?.question ?? "").prefix(60))
        log("in der Notch: \(topic)")

        while Date.now < request.deadline {
            if let data = try? Data(contentsOf: replyFile(id)), let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                guard reply.skip != true, let answers = reply.answers, !answers.isEmpty else {
                    log("an Claude übergeben")
                    return 0
                }
                log("beantwortet: \(answers.values.joined(separator: ", "))")
                // updatedInput replaces the whole input, so the questions travel along.
                var updated = toolInput
                updated["answers"] = answers
                let decision: [String: Any] = ["hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "In der Notch von Claude Pet beantwortet",
                    "updatedInput": updated,
                ]]
                if let json = try? JSONSerialization.data(withJSONObject: decision) {
                    FileHandle.standardOutput.write(json)
                }
                return 0
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        log("Zeit abgelaufen, Claude zeigt die Frage selbst")
        return 0
    }

    /// `~/Library/Application Support/ClaudePet/ask.log`: what the hook did, the last 100 lines.
    static let logFile = directory.deletingLastPathComponent().appending(path: "ask.log")

    private static func log(_ line: String) {
        let stamp = Date.now.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let old = (try? String(contentsOf: logFile, encoding: .utf8))?.split(separator: "\n").suffix(99).joined(separator: "\n") ?? ""
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ((old.isEmpty ? "" : old + "\n") + "\(stamp)  \(line)\n").write(to: logFile, atomically: true, encoding: .utf8)
    }

    /// Without the app nobody could click, so the hook would only delay the question.
    private static var appIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.maiki09k.claudepet")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    // MARK: App side

    /// Questions still waiting, oldest first. Leftovers of a hook Claude Code cut off are cleared.
    static func pending() -> [AskRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var requests: [AskRequest] = []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasSuffix(".answer.json") {
            guard let data = try? Data(contentsOf: file), let request = try? JSONDecoder().decode(AskRequest.self, from: data) else { continue }
            if request.deadline.timeIntervalSinceNow < -5 {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: replyFile(request.id))
            } else if request.deadline > .now {
                requests.append(request)
            }
        }
        return requests.sorted { $0.deadline < $1.deadline }
    }

    static func answer(_ id: String, with answers: [String: String]) {
        write(Reply(answers: answers), for: id)
    }

    /// "In Claude antworten": the hook lets go and Claude shows the question itself.
    static func skip(_ id: String) {
        write(Reply(skip: true), for: id)
    }

    private static func write(_ reply: Reply, for id: String) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        try? data.write(to: replyFile(id), options: .atomic)
    }
}
