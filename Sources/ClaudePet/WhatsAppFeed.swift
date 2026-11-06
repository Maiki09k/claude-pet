import AppKit
import Observation
import SQLite3

struct ChatMessage: Identifiable, Equatable {
    let id: Int64
    let jid: String
    let chat: String
    let group: Bool
    /// The caption or text, or a word like "Foto" when there is none.
    let text: String
    let date: Date
    /// WhatsApp's own message id, which the bridge needs to fetch a photo.
    var messageID = ""
    /// "image", "video", "audio", "document", "sticker" or empty for plain text.
    var media = ""
    /// What was actually written; empty for a photo without caption.
    var caption = ""
    var filename: String?
    var size: Int64 = 0
    /// Maik's own message, shown on the right in an open chat.
    var fromMe = false
    /// Who wrote it in a group.
    var sender = ""
}

/// Unread messages of one chat, newest first.
struct ChatThread: Identifiable, Equatable {
    let id: String
    let name: String
    let group: Bool
    let messages: [ChatMessage]

    var latest: ChatMessage { messages[0] }
}

/// Incoming WhatsApp messages, read from the local database of the whatsapp-mcp bridge.
/// Read-only; it never sends or marks anything in WhatsApp itself.
@MainActor @Observable
final class WhatsAppFeed {
    /// Incoming messages not yet seen here, newest first.
    var unseen: [ChatMessage] = [] {
        didSet {
            if unseen != oldValue { threads = Self.group(unseen) }
        }
    }
    /// The newest direct message worth a pop-up.
    var pop: ChatMessage?
    /// The chat opened in the notch and its last messages, own ones included, newest first.
    private(set) var openJID: String?
    private(set) var history: [ChatMessage] = []

    /// The opened chat as a thread, for the notch's chat view.
    var openChat: ChatThread? {
        guard let openJID, let first = history.first else { return nil }
        let name = history.first { !$0.fromMe }?.chat ?? first.chat
        return ChatThread(id: openJID, name: name, group: openJID.hasSuffix("@g.us"), messages: history)
    }

    /// Unread messages grouped by chat, the most recent chat first.
    private(set) var threads: [ChatThread] = []

    /// Group only when the unread list changes, rather than on every hover/animation tick.
    private static func group(_ messages: [ChatMessage]) -> [ChatThread] {
        var order: [String] = []
        var byChat: [String: [ChatMessage]] = [:]
        for message in messages {
            if byChat[message.jid] == nil { order.append(message.jid) }
            byChat[message.jid, default: []].append(message)
        }
        return order.compactMap { jid in
            guard let messages = byChat[jid], let first = messages.first else { return nil }
            return ChatThread(id: jid, name: first.chat, group: first.group, messages: messages)
        }
    }

    /// The bridge's `store` folder. Default `~/whatsapp-mcp/whatsapp-bridge/store`, elsewhere via
    /// `defaults write io.github.maiki09k.claudepet whatsapp.store /path/to/store` and a restart.
    static let store: URL = UserDefaults.standard.string(forKey: "whatsapp.store")
        .map { URL(filePath: NSString(string: $0).expandingTildeInPath) }
        ?? URL.homeDirectory.appending(path: "whatsapp-mcp/whatsapp-bridge/store")

    @ObservationIgnored private let database = WhatsAppFeed.store.appending(path: "messages.db")
    @ObservationIgnored private var lastModified: Date?
    @ObservationIgnored private var newestRowID: Int64 = 0
    /// Chats read in the notch or answered from it, read up to this row. Kept across restarts.
    @ObservationIgnored private var readUpTo: [String: Int64] =
        (UserDefaults.standard.dictionary(forKey: WhatsAppFeed.readKey) as? [String: Int64]) ?? [:]
    private static let bridge = URL(string: "http://127.0.0.1:8080/api/send")!
    private static let seenKey = "whatsappSeenRowID"
    private static let readKey = "whatsappReadUpTo"
    /// Older than this, a message is no longer "now" (settings, 12 hours unless changed).
    private static var relevantFor: TimeInterval { Setting.value(Setting.whatsappHours) * 3600 }

    func start() {
        poll()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Opens WhatsApp itself, right in this chat when its phone number is known (groups have no link).
    func openWhatsApp(_ jid: String? = nil) {
        if let jid, let phone = phone(for: jid), let url = URL(string: "whatsapp://send?phone=\(phone)"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(filePath: "/Applications/WhatsApp.app"))
        }
    }

    /// Sends Maik's own reply through the local bridge. Returns whether WhatsApp accepted it.
    func send(_ text: String, to jid: String) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        var request = URLRequest(url: Self.bridge, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["recipient": jid, "message": message])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              reply["success"] as? Bool == true else { return false }
        markRead(jid)
        return true
    }

    /// Opens one chat in the notch with its recent history; reading it there counts as read once it closes.
    func open(_ jid: String) {
        openJID = jid
        history = query(chat: jid, limit: 60)?.map(Self.message) ?? []
        // The bridge holding its write lock must not turn the click into nothing: show what is known.
        if history.isEmpty { history = unseen.filter { $0.jid == jid } }
    }

    /// For the "chat" preview: a made-up chat, never read from or marked in the database.
    func showSample(_ thread: ChatThread) {
        openJID = thread.id
        history = thread.messages
    }

    func close() {
        guard let jid = openJID else { return }
        markRead(jid)
        openJID = nil
        history = []
    }

    /// One chat counts as read, the others stay.
    func markRead(_ jid: String) {
        guard !jid.hasPrefix("preview") else { return }
        readUpTo[jid] = max(readUpTo[jid] ?? 0, history.first { $0.jid == jid }?.id ?? 0,
                            unseen.filter { $0.jid == jid }.map(\.id).max() ?? newestRowID)
        UserDefaults.standard.set(readUpTo, forKey: Self.readKey)
        unseen.removeAll { $0.jid == jid }
        if pop?.jid == jid { pop = nil }
    }

    private func poll() {
        guard let modified = try? database.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified != lastModified else {
            // Nothing new, but old messages still age out of "now".
            if unseen.contains(where: { $0.date.timeIntervalSinceNow < -Self.relevantFor }) {
                unseen.removeAll { $0.date.timeIntervalSinceNow < -Self.relevantFor }
            }
            return
        }
        // The bridge may hold a write lock for a moment; try again on the next tick.
        guard let rows = query() else { return }
        lastModified = modified
        if let openJID, !openJID.hasPrefix("preview"), let rows = query(chat: openJID, limit: 60) {
            let next = rows.map(Self.message)
            if history != next { history = next }
        }
        newestRowID = max(newestRowID, rows.map(\.rowID).max() ?? 0)

        // First run: start from now instead of flooding the notch with history.
        guard let seen = UserDefaults.standard.object(forKey: Self.seenKey) as? Int64 else {
            UserDefaults.standard.set(newestRowID, forKey: Self.seenKey)
            return
        }

        let fresh = unread(in: rows, seen: seen)

        let previousNewest = unseen.first?.id ?? seen
        if unseen != fresh { unseen = fresh }
        // Faces and photos for what the notch is about to show.
        for jid in Set(fresh.map(\.jid)) { WhatsAppMedia.shared.loadAvatar(jid) }
        for message in fresh.prefix(12) {
            WhatsAppMedia.shared.loadPreview(message)
            WhatsAppMedia.shared.loadVoice(message)
        }
        // Groups count quietly unless the settings let them pop up too.
        let groupsPop = Setting.on(Setting.groupBanner)
        if let newest = fresh.first(where: { !$0.group || groupsPop }), newest.id > previousNewest, newest.date.timeIntervalSinceNow > -120 {
            pop = newest
        }
    }

    /// What still counts as unread: incoming, recent, and not read here, answered or read on the phone.
    private func unread(in rows: [Row], seen: Int64) -> [ChatMessage] {
        // A reply in a chat (from any device) means its earlier messages were read.
        var lastReply: [String: Int64] = [:]
        for row in rows where row.fromMe { lastReply[row.jid] = max(lastReply[row.jid] ?? 0, row.rowID) }
        // Read on the phone or in WhatsApp itself: the bridge records up to when (read_marks).
        let marks = readMarks()
        return rows
            // Status posts and channels are no conversation.
            .filter { !$0.jid.hasSuffix("@broadcast") && !$0.jid.hasSuffix("@newsletter") }
            .filter { !$0.fromMe && $0.rowID > seen && $0.rowID > max(lastReply[$0.jid] ?? 0, readUpTo[$0.jid] ?? 0) }
            .filter { $0.date.timeIntervalSinceNow > -Self.relevantFor }
            .filter { row in row.date > max(marks[row.jid] ?? .distantPast, alternate(row.jid).flatMap { marks[$0] } ?? .distantPast) }
            .map(Self.message)
    }

    /// For `--status`: whether the bridge database can be read, without showing any content.
    func diagnose() -> String {
        guard let rows = query() else { return "WhatsApp: Bridge-Datenbank nicht lesbar" }
        let recent = rows.filter { !$0.fromMe && $0.date.timeIntervalSinceNow > -Self.relevantFor }
        let newest = rows.first.map { AgendaEvent.clock($0.date) } ?? "–"
        let chats = Dictionary(grouping: rows, by: \.jid).values.compactMap(\.first)
        let named = chats.filter { !$0.name.hasPrefix("+") && $0.name != "Unbekannter Chat" && !$0.name.allSatisfy(\.isNumber) }.count
        // What a click on the newest chat would open, counted only.
        let history = rows.first.flatMap { query(chat: $0.jid, limit: 60) } ?? []
        return "WhatsApp: \(rows.count) Zeilen gelesen, \(recent.count) eingehend in den letzten \(Int(Self.relevantFor / 3600)) Std., neueste \(newest), "
            + "\(named) von \(chats.count) Chats mit Namen, neuester Chat geöffnet: \(history.count) Nachrichten, "
            + "\(history.filter(\.fromMe).count) eigene, \(readMarks().count) Chats mit Lesestand vom Handy, "
            + "in der Notch ungelesen: \(Set(unread(in: rows, seen: UserDefaults.standard.object(forKey: Self.seenKey) as? Int64 ?? .max).map(\.jid)).count) Chats"
    }

    private static func message(_ row: Row) -> ChatMessage {
        ChatMessage(id: row.rowID, jid: row.jid, chat: row.name, group: row.jid.hasSuffix("@g.us"), text: row.text, date: row.date,
                    messageID: row.messageID, media: row.media, caption: row.caption, filename: row.filename, size: row.size,
                    fromMe: row.fromMe, sender: row.sender)
    }

    private struct Row {
        let rowID: Int64
        let jid: String
        let name: String
        let text: String
        let date: Date
        let fromMe: Bool
        let messageID: String
        let media: String
        let caption: String
        let filename: String?
        let size: Int64
        let sender: String
    }

    /// Up to when each chat was read on one of Maik's devices, recorded by the patched bridge.
    private func readMarks() -> [String: Date] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        // An older bridge has no such table: then nothing counts as read elsewhere.
        guard sqlite3_prepare_v2(db, "SELECT chat_jid, read_until FROM read_marks", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var marks: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let jid = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            marks[jid] = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
        }
        return marks
    }

    /// The newest messages of all chats, or of one chat.
    private func query(chat: String? = nil, limit: Int = 400) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = """
        SELECT m.rowid, m.chat_jid, coalesce(c.name, ''), coalesce(m.content, ''), coalesce(m.media_type, ''), m.timestamp, m.is_from_me,
               coalesce(m.id, ''), coalesce(m.filename, ''), coalesce(m.file_length, 0), coalesce(m.sender, '')
        FROM messages m LEFT JOIN chats c ON c.jid = m.chat_jid
        \(chat == nil ? "" : "WHERE m.chat_jid = ?1")
        ORDER BY \(chat == nil ? "m.rowid" : "m.timestamp") DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        if let chat { sqlite3_bind_text(statement, 1, chat, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }

        let formatter = ISO8601DateFormatter()
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let jid = text(1)
            let stamp = text(5).replacingOccurrences(of: " ", with: "T")
            guard let date = formatter.date(from: stamp) else { continue }
            rows.append(Row(rowID: sqlite3_column_int64(statement, 0), jid: jid,
                            name: displayName(text(2), jid: jid),
                            text: Self.preview(text(3), media: text(4)), date: date,
                            fromMe: sqlite3_column_int(statement, 6) != 0,
                            messageID: text(7), media: text(4), caption: text(3),
                            filename: text(8).isEmpty ? nil : text(8), size: sqlite3_column_int64(statement, 9),
                            sender: jid.hasSuffix("@g.us") ? senderName(text(10)) : ""))
        }
        return rows
    }

    /// The bridge often only knows a chat by its number (or WhatsApp's hidden "LID" number);
    /// the name from the address book or the profile lives in its session database.
    private func displayName(_ name: String, jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        // A chat "name" of only digits is a number the bridge filled in, not a name.
        if !name.isEmpty, !name.allSatisfy(\.isNumber) { return name }
        if let contact = contactName(jid) { return contact }
        // A new contact can arrive any time; look again soon instead of showing a number for ten minutes.
        if Date.now.timeIntervalSince(names.loaded) > 30 {
            names.loaded = .distantPast
            if let contact = contactName(jid) { return contact }
        }
        if let phone = phoneNumber(jid) { return "+" + phone }
        if !name.isEmpty, name != user { return "+" + name }
        return jid.hasSuffix("@s.whatsapp.net") ? "+" + user : "Unbekannter Chat"
    }

    @ObservationIgnored private let session = WhatsAppFeed.store.appending(path: "whatsapp.db")
    @ObservationIgnored private var names: (loaded: Date, byJID: [String: String], phones: [String: String], lids: [String: String])
        = (.distantPast, [:], [:], [:])

    private func contactName(_ jid: String) -> String? {
        loadNames()
        if let name = names.byJID[jid] { return name }
        if let phone = names.phones[jid] { return names.byJID[phone + "@s.whatsapp.net"] }
        return nil
    }

    /// A group member, known to the bridge only by number (phone or LID).
    private func senderName(_ user: String) -> String {
        guard !user.isEmpty else { return "" }
        let base = user.split(separator: "@").first.map(String.init) ?? user
        return contactName(base + "@s.whatsapp.net") ?? contactName(base + "@lid") ?? phoneNumber(base + "@lid").map { "+" + $0 } ?? ""
    }

    /// The same chat under its other address: WhatsApp's hidden LID or the phone number.
    private func alternate(_ jid: String) -> String? {
        loadNames()
        if let phone = names.phones[jid] { return phone + "@s.whatsapp.net" }
        if jid.hasSuffix("@s.whatsapp.net"), let lid = names.lids[String(jid.dropLast(15))] { return lid }
        return nil
    }

    /// The phone number behind a direct chat, for a link straight into WhatsApp.
    private func phone(for jid: String) -> String? {
        if jid.hasSuffix("@s.whatsapp.net") { return String(jid.dropLast(15)) }
        return phoneNumber(jid)
    }

    private func phoneNumber(_ jid: String) -> String? {
        loadNames()
        return names.phones[jid]
    }

    /// Contact names and the LID-to-phone map, read-only, refreshed every ten minutes.
    private func loadNames() {
        guard Date.now.timeIntervalSince(names.loaded) > 600 else { return }
        names.loaded = .now
        var db: OpaquePointer?
        guard sqlite3_open_v2(session.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        func rows(_ sql: String) -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
            }
            return result
        }
        var byJID: [String: String] = [:]
        // Address book name first, then the business name, then what the person calls themselves.
        for row in rows("SELECT their_jid, coalesce(full_name, ''), coalesce(business_name, ''), coalesce(push_name, '') FROM whatsmeow_contacts") {
            if let name = row.dropFirst().first(where: { !$0.isEmpty }) { byJID[row[0]] = name }
        }
        var phones: [String: String] = [:]
        var lids: [String: String] = [:]
        for row in rows("SELECT lid, pn FROM whatsmeow_lid_map") {
            phones[row[0] + "@lid"] = row[1]
            lids[row[1]] = row[0] + "@lid"
        }
        names.byJID = byJID
        names.phones = phones
        names.lids = lids
    }

    private static func preview(_ content: String, media: String) -> String {
        if !content.isEmpty { return content.replacingOccurrences(of: "\n", with: " ") }
        switch media {
        case "audio": return "Sprachnachricht"
        case "image": return "Foto"
        case "video": return "Video"
        case "document": return "Dokument"
        case "sticker": return "Sticker"
        default: return "Nachricht"
        }
    }
}
