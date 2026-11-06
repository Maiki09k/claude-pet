import Foundation
import XCTest
@testable import ClaudePet

final class ActivityScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_390_000)
    private var root: URL!
    private var projects: URL { root.appendingPathComponent("projects") }
    private var codex: URL { root.appendingPathComponent("codex") }
    private var index: URL { root.appendingPathComponent("index.jsonl") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("fixture"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func scan(after seconds: Double = 0) -> ActivitySnapshot {
        ActivityScanner.scan(now: now.addingTimeInterval(seconds), projects: projects, codex: codex, index: index)
    }

    private var file: URL { projects.appendingPathComponent("fixture/session.jsonl") }

    private func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func event(tool: String? = nil, done: Bool = false) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let content: [[String: Any]] = tool.map { [["type": "tool_use", "name": $0, "input": [:]]] } ?? []
        return try line(["type": "assistant", "timestamp": formatter.string(from: now),
                         "message": ["content": content, "stop_reason": done ? "end_turn" : "tool_use"]])
    }

    private func write(_ data: Data, to url: URL? = nil, modified: Date? = nil) throws {
        let destination = url ?? file
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now], ofItemAtPath: destination.path)
    }

    func testUnchangedQuickToolStillBecomesApprovalAndExpires() throws {
        try write(event(tool: "Read"))
        XCTAssertEqual(scan().mood, .working)
        XCTAssertEqual(scan(after: 25).mood, .working)
        XCTAssertEqual(scan(after: 26).mood, .asking)
        XCTAssertEqual(scan(after: 1_201).mood, .asking)
        XCTAssertEqual(scan(after: 10_801).mood, .sleeping)
    }

    func testUnchangedLongToolBecomesStale() throws {
        try write(event(tool: "Bash"))
        XCTAssertEqual(scan().working, 1)
        XCTAssertEqual(scan(after: 1_201).working, 0)
        XCTAssertEqual(scan(after: 1_201).mood, .sleeping)
    }

    func testUnchangedCompletionExpiresWithoutAnotherWrite() throws {
        try write(event(done: true))
        XCTAssertEqual(scan().mood, .done)
        XCTAssertEqual(scan(after: 119).sessions.first?.mood, .done)
        XCTAssertEqual(scan(after: 120).mood, .idle)
        XCTAssertTrue(scan(after: 120).sessions.isEmpty)
        XCTAssertEqual(scan(after: 1_201).mood, .sleeping)
    }

    func testAppendAndTruncateWithSameModificationDateInvalidateCache() throws {
        let working = try event(tool: "Bash")
        try write(working)
        XCTAssertEqual(scan().mood, .working)
        try write(working + event(done: true))
        XCTAssertEqual(scan().mood, .done)
        try write(working)
        XCTAssertEqual(scan().mood, .working)
    }

    func testSameSizeEditWithNewModificationDateInvalidatesCache() throws {
        try write(event(tool: "Read"))
        XCTAssertEqual(scan(after: 26).mood, .asking)
        try write(event(tool: "Bash"), modified: now.addingTimeInterval(27))
        XCTAssertEqual(scan(after: 27).mood, .working)
        XCTAssertEqual(scan(after: 27).tool, "Bash")
    }

    func testTitleRenameRefreshesDespiteFrequentScans() throws {
        // custom-title's compact prefix is the transcript's actual format.
        let title = Data("{\"type\":\"custom-title\",\"customTitle\":\"Original\"}\n".utf8)
        let renamed = Data("{\"type\":\"custom-title\",\"customTitle\":\"Renamed\"}\n".utf8)
        let working = try event(tool: "Bash")
        try write(title + working)
        XCTAssertEqual(scan().sessions.first?.title, "Original")
        try write(title + working + renamed, modified: now.addingTimeInterval(10))
        for offset in [10.0, 20, 30, 40, 50] { _ = scan(after: offset) }
        XCTAssertEqual(scan(after: 61).sessions.first?.title, "Renamed")
    }

    func testPreviouslyAbsentTitleAppearsAfterRefresh() throws {
        let working = try event(tool: "Bash")
        try write(working)
        XCTAssertEqual(scan().sessions.first?.title, "Session")
        let title = Data("{\"type\":\"custom-title\",\"customTitle\":\"Now named\"}\n".utf8)
        try write(working + title, modified: now.addingTimeInterval(10))
        XCTAssertEqual(scan(after: 61).sessions.first?.title, "Now named")
    }

    private func codexFile() -> URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return codex.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            .appendingPathComponent("rollout-fixture-00000000-0000-0000-0000-000000000001.jsonl")
    }

    private func codexEvent(_ kind: String) throws -> Data {
        try line(["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now), "payload": ["type": kind]])
    }

    func testCodexAppendAndCompletionExpiry() throws {
        let url = codexFile()
        let working = try codexEvent("task_started")
        try write(working, to: url)
        XCTAssertEqual(scan().codex, .working)
        try write(working + codexEvent("task_complete"), to: url)
        XCTAssertEqual(scan().codex, .done)
        XCTAssertNil(scan(after: 120).codex)
    }

    func testCodexQuestionSurvivesCompletionUntilUserReplies() throws {
        let arguments = String(data: try JSONSerialization.data(withJSONObject: [
            "questions": [["title": "Synthetic question", "options": ["One", "Two"]]]
        ]), encoding: .utf8)!
        let question = try line(["type": "response_item", "payload": ["type": "function_call",
            "name": "request_user_input_async", "call_id": "fixture", "arguments": arguments]])
        let data = try question + codexEvent("task_complete")
        try write(data, to: codexFile())
        XCTAssertEqual(scan().codex, .asking)
        XCTAssertEqual(scan(after: 1_201).sessions.first?.question?.title, "Synthetic question")
        let reply = try line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": []]])
        try write(data + reply, to: codexFile(), modified: now.addingTimeInterval(1_202))
        XCTAssertEqual(scan(after: 1_202).codex, .working)
    }

    func testTimestampFormatsAndConcurrentParsing() {
        let expected = Date(timeIntervalSince1970: 1_793_318_400)
        XCTAssertEqual(parseISODate("2026-10-30T00:00:00Z"), expected)
        XCTAssertEqual(parseISODate("2026-10-30T01:00:00+01:00"), expected)
        XCTAssertEqual(parseISODate("2026-10-30T00:00:00.123456Z")!.timeIntervalSince(expected), 0.123456, accuracy: 0.001)
        XCTAssertNil(parseISODate("not a timestamp"))
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(parseISODate("2026-10-30T00:00:00Z"), expected)
        }
    }
}

final class WhatsAppGroupingTests: XCTestCase {
    @MainActor
    func testGroupingPreservesOrderAndTracksRemoval() async {
        let feed = WhatsAppFeed()
        let messages = [
            ChatMessage(id: 3, jid: "preview-a", chat: "A", group: false, text: "Latest", date: .now),
            ChatMessage(id: 2, jid: "preview-b", chat: "B", group: true, text: "Group", date: .now),
            ChatMessage(id: 1, jid: "preview-a", chat: "A", group: false, text: "Earlier", date: .now)
        ]
        feed.unseen = messages
        XCTAssertEqual(feed.threads.map(\.id), ["preview-a", "preview-b"])
        XCTAssertEqual(feed.threads.first?.messages.map(\.id), [3, 1])
        XCTAssertEqual(feed.threads.last?.group, true)
        feed.unseen.removeAll { $0.jid == "preview-a" }
        XCTAssertEqual(feed.threads.map(\.id), ["preview-b"])
        feed.unseen = []
        XCTAssertTrue(feed.threads.isEmpty)
    }
}
