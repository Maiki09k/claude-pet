import AppKit
import SwiftUI

/// `ClaudePet --snapshot out.png` renders every mood as a contact sheet: the full
/// widget at two moments of a simulated walk, so the drawing can be checked
/// without catching the live widget in each state.
@MainActor
enum Snapshot {
    static func write(to url: URL) -> Bool {
        let bars = [
            UsageBar(id: "five_hour", label: "Sitzung", percent: 42, resetsAt: .now.addingTimeInterval(2 * 3600 + 14 * 60)),
            UsageBar(id: "seven_day", label: "Woche", percent: 76, resetsAt: .now.addingTimeInterval(3 * 86400)),
            UsageBar(id: "seven_day_opus", label: "Opus", percent: 93, resetsAt: .now.addingTimeInterval(3 * 86400)),
        ]
        let two = Array(bars.prefix(2))
        let rows: [(Mood, ActivitySnapshot, UsageState, [TimeInterval])] = [
            (.working, ActivitySnapshot(mood: .working, working: 2, tool: "Bash", lastActivity: .now), .ready(bars, fetched: .now), [1.4, 1.5]),
            (.asking, ActivitySnapshot(mood: .asking, asking: 1, lastActivity: .now), .ready(two, fetched: .now), [1.2, 4.0]),
            (.done, ActivitySnapshot(mood: .done, lastActivity: .now), .ready(two, fetched: .now), [0.3, 2.6]),
            (.idle, ActivitySnapshot(mood: .idle, lastActivity: .now.addingTimeInterval(-7 * 60)), .needsLogin, [3.0, 9.0]),
            (.sleeping, ActivitySnapshot(mood: .sleeping, lastActivity: .now.addingTimeInterval(-3 * 3600)), .loading, [2.0, 9.0]),
        ]

        let sheet = VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row.3, id: \.self) { time in
                        frame(row.1, row.2, mood: row.0, at: time, poked: row.0 == .idle && time == row.3[1])
                    }
                }
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color(hex: 0x3B5378), Color(hex: 0x6E5A80)], startPoint: .topLeading, endPoint: .bottomTrailing))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `ClaudePet --icon out.png`: the 1024 px app icon, Clawd on a dark rounded square
    /// (macOS icon grid: 824 px tile, 100 px margin). `install.sh` turns it into AppIcon.icns.
    static func writeIcon(to url: URL) -> Bool {
        let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
        let icon = ZStack {
            tile.fill(LinearGradient(colors: [Color(hex: 0x3A2620), Color(hex: 0x120D0B)], startPoint: .top, endPoint: .bottom))
            tile.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 4)
            VStack(spacing: 18) {
                ClawdIcon(pw: 30, ph: 60, mood: .idle, time: 0)
                Ellipse().fill(.black.opacity(0.45)).frame(width: 380, height: 34).blur(radius: 6)
            }
            .offset(y: 30)
        }
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        .frame(width: 1024, height: 1024)

        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Made-up appointments, clearly labelled, for layout checks only.
    static let sampleEvents = [
        AgendaEvent(id: "1", title: "Beispiel: Abstimmung", start: .now.addingTimeInterval(8 * 60),
                    end: .now.addingTimeInterval(38 * 60), allDay: false, color: Palette.mint,
                    meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
        AgendaEvent(id: "2", title: "Beispiel: Review mit langem Titel", start: .now.addingTimeInterval(3 * 3600),
                    end: .now.addingTimeInterval(4 * 3600), allDay: false, color: Palette.amber, location: "Büro"),
        AgendaEvent(id: "3", title: "Beispiel: Sport", start: .now.addingTimeInterval(20 * 3600),
                    end: .now.addingTimeInterval(21 * 3600), allDay: false, color: Palette.night),
        AgendaEvent(id: "4", title: "Beispiel: Urlaub", start: .now.addingTimeInterval(26 * 3600),
                    end: .now.addingTimeInterval(50 * 3600), allDay: true, color: Palette.clawd),
    ]

    /// `ClaudePet --notch-snapshot out.png`: every notch state with clearly made-up sample data,
    /// drawn over a stand-in menu bar with the hardware notch.
    static func writeNotch(to url: URL) -> Bool {
        let notch = CGSize(width: 185, height: 32)
        let track = Track(player: .spotify, title: "Beispieltitel mit einem ziemlich langen Namen", artist: "Beispiel-Interpret",
                          artworkURL: nil, playing: true, position: 42, duration: 214, fetched: .now,
                          shuffling: true, repeating: false, volume: 64)
        let threads = [
            ChatThread(id: "a", name: "Beispiel Kontakt", group: false, messages: [
                ChatMessage(id: 3, jid: "a", chat: "Beispiel Kontakt", group: false, text: "Kommst du morgen mit zum Termin?", date: .now.addingTimeInterval(-60)),
                ChatMessage(id: 2, jid: "a", chat: "Beispiel Kontakt", group: false, text: "Hey, kurze Frage", date: .now.addingTimeInterval(-120)),
            ]),
            ChatThread(id: "b", name: "Beispiel Gruppe", group: true, messages: [
                ChatMessage(id: 1, jid: "b", chat: "Beispiel Gruppe", group: true, text: "Wer bringt den Grill mit?", date: .now.addingTimeInterval(-900),
                            sender: "Anna Beispiel"),
            ]),
        ]
        // Many chats at once: the list scrolls, every row opens its chat.
        let manyThreads = threads + [
            ChatThread(id: "c", name: "Beispiel Büro", group: false, messages: [
                ChatMessage(id: 8, jid: "c", chat: "Beispiel Büro", group: false, text: "Dokument", date: .now.addingTimeInterval(-1800),
                            messageID: "c1", media: "document", filename: "Beispiel-Angebot.pdf"),
            ]),
            ChatThread(id: "e", name: "Beispiel Verein", group: true, messages: [
                ChatMessage(id: 9, jid: "e", chat: "Beispiel Verein", group: true, text: "Training fällt heute aus", date: .now.addingTimeInterval(-3600),
                            sender: "Trainer Beispiel"),
            ]),
        ]
        // Made-up photo, profile picture and file for the media rows.
        let photo = NSImage(size: CGSize(width: 320, height: 220), flipped: false) { rect in
            NSGradient(colors: [NSColor(Palette.join), NSColor(Palette.mint)])?.draw(in: rect, angle: 35)
            ("Beispielfoto" as NSString).draw(at: CGPoint(x: 92, y: 98), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white])
            return true
        }
        let face = NSImage(size: CGSize(width: 96, height: 96), flipped: false) { rect in
            NSGradient(colors: [NSColor(Palette.amber), NSColor(Palette.clawd)])?.draw(in: rect, angle: 90)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 30, y: 46, width: 36, height: 36)).fill()
            NSBezierPath(ovalIn: CGRect(x: 14, y: -30, width: 68, height: 64)).fill()
            return true
        }
        let photoMessage = ChatMessage(id: 5, jid: "m", chat: "Beispiel Fotos", group: false, text: "Foto", date: .now.addingTimeInterval(-30),
                                       messageID: "p1", media: "image")
        let fileMessage = ChatMessage(id: 4, jid: "d", chat: "Beispiel Büro", group: false, text: "Dokument", date: .now.addingTimeInterval(-300),
                                      messageID: "d1", media: "document", filename: "Beispiel-Angebot.pdf", size: 482_000)
        WhatsAppMedia.shared.previews[photoMessage.mediaKey] = photo
        WhatsAppMedia.shared.avatars["m"] = face
        let voiceMessage = ChatMessage(id: 6, jid: "v", chat: "Beispiel Team", group: false, text: "Sprachnachricht", date: .now.addingTimeInterval(-90),
                                       messageID: "vm1", media: "audio")
        WhatsAppMedia.shared.voices[voiceMessage.mediaKey] = ("", 32)
        let voiceThreads = [ChatThread(id: "v", name: "Beispiel Team", group: false, messages: [voiceMessage])]
        let mediaThreads = [ChatThread(id: "m", name: "Beispiel Fotos", group: false, messages: [photoMessage]),
                            ChatThread(id: "d", name: "Beispiel Büro", group: false, messages: [fileMessage])]
        // An opened chat: older messages, Maik's own, then the unread part with photo and voice message.
        func line(_ id: Int64, _ text: String, ago: Double, me: Bool = false, media: String = "", jid: String = "m",
                  chat: String = "Beispiel Fotos", sender: String = "") -> ChatMessage {
            ChatMessage(id: id, jid: jid, chat: chat, group: jid.hasSuffix("g"), text: text, date: .now.addingTimeInterval(-ago),
                        messageID: "h\(id)", media: media, caption: media.isEmpty ? text : "", fromMe: me, sender: sender)
        }
        var chatPhoto = line(25, "Foto", ago: 120, media: "image")
        chatPhoto.caption = "Schau mal, der Ausblick!"
        WhatsAppMedia.shared.previews[chatPhoto.mediaKey] = photo
        let chatVoice = line(26, "Sprachnachricht", ago: 60, media: "audio")
        WhatsAppMedia.shared.voices[chatVoice.mediaKey] = ("", 47)
        let openChat = ChatThread(id: "m", name: "Beispiel Fotos", group: false, messages: [
            chatVoice, chatPhoto,
            line(24, "Bin gleich da", ago: 1800, me: true),
            line(23, "Wann bist du heute im Büro?\nIch bring den Schlüssel mit.", ago: 2400),
            line(22, "Super, danke dir!", ago: 5000, me: true),
            line(21, "Hab dir die Unterlagen geschickt", ago: 5400),
            line(20, "Bis morgen!", ago: 26 * 3600, me: true),
        ])
        let openGroup = ChatThread(id: "gg", name: "Beispiel Gruppe", group: true, messages: [
            line(33, "Ich bring Getränke mit", ago: 100, jid: "gg", chat: "Beispiel Gruppe", sender: "Anna Beispiel"),
            line(32, "Samstag 14 Uhr passt mir", ago: 300, jid: "gg", chat: "Beispiel Gruppe", sender: "Ben Beispiel"),
            line(31, "Wer ist am Wochenende dabei? Wir könnten grillen, falls das Wetter hält, sonst gehen wir einfach zu mir und kochen zusammen.", ago: 900, me: true, jid: "gg", chat: "Beispiel Gruppe"),
        ])

        var activity = ActivitySnapshot(mood: .working, working: 2)
        activity.codex = .working
        activity.sessions = [
            SessionStatus(id: "1", agent: .claude, title: "Beispiel: Notch bauen", mood: .working, since: .now),
            SessionStatus(id: "2", agent: .codex, title: "Beispiel: Bilder erstellen", mood: .working, since: .now),
            SessionStatus(id: "3", agent: .claude, title: "Beispiel: Briefing", mood: .done, since: .now),
        ]

        func content(music: Bool = false, chats: Bool = false, agenda: Bool = false, agents: Bool = false, asking: ActivitySnapshot? = nil,
                     media: Bool = false, voice: Bool = false) -> NotchContent {
            var content = NotchContent(agendaAccess: .granted)
            if music { content.track = track; content.musicRelevant = true; content.accent = Palette.mint }
            if chats { content.threads = threads }
            if media { content.threads = mediaThreads }
            if voice { content.threads = voiceThreads }
            if agenda { content.events = sampleEvents }
            content.activity = agents ? asking ?? activity : ActivitySnapshot(mood: .idle)
            return content
        }
        var asking = activity
        asking.codex = .asking
        let question = PendingQuestion(title: "Beispiel: Bei Bild 17 liegt das Gerüst unter der Bildmitte. Die zwei Varianten erhalten Haus und Gerüst, setzen die Person aber tiefer als verlangt. Welche Vorgabe hat Vorrang?",
                                       options: ["Originalmotiv erhalten und tiefere Person akzeptieren", "Person höher setzen und Gerüst neu erzeugen", "Bild 17 weglassen"])
        asking.sessions[1] = SessionStatus(id: "2", agent: .codex, title: "Beispiel: Bilder erstellen", mood: .asking, since: .now, question: question)
        asking.sessions.swapAt(0, 1)

        let shelfItems = ["Beispiel-Angebot.pdf", "Beispiel Logo.png", "Beispiel-Tabelle.xlsx"].map { ShelfItem(url: URL(filePath: "/tmp/\($0)")) }
        let doneSession = SessionStatus(id: "x", agent: .claude, title: "Beispiel: Notch bauen", mood: .done, since: .now,
                                        summary: "Beispiel: Fertig-Meldung, Termin-Alarm und Ablage sind eingebaut und geprüft.")
        let meetingEvent = AgendaEvent(id: "m", title: "Beispiel: Abstimmung mit Kunde", start: .now.addingTimeInterval(118),
                                       end: .now.addingTimeInterval(1918), allDay: false, color: Palette.join,
                                       meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))

        func state(expanded: Bool, banner: ChatMessage? = nil, question: SessionStatus? = nil, replyTo: String? = nil) -> NotchState {
            let state = NotchState()
            state.expanded = expanded
            state.banner = banner
            state.question = question
            state.replyTo = replyTo
            if replyTo != nil { state.draft = "Ja, bin dabei!" }
            return state
        }

        let rows: [(String, NotchContent, NotchState)] = [
            ("zu: Claude und Codex arbeiten, Musik läuft", content(music: true, agents: true), state(expanded: false)),
            ("neue Direktnachricht (Banner)", content(chats: true), state(expanded: false, banner: threads[0].latest)),
            ("nur WhatsApp, beim Antworten", content(chats: true), state(expanded: true, replyTo: "a")),
            ("Fertig-Meldung", content(), { let s = state(expanded: false); s.done = doneSession; return s }()),
            ("Termin-Alarm", content(), { let s = state(expanded: false); s.meeting = meetingEvent; return s }()),
            ("Dateien über der Notch", content(), { let s = state(expanded: false); s.dropping = true; return s }()),
            ("Ablage mit Musik", { var c = content(music: true); c.shelf = shelfItems; return c }(), state(expanded: true)),
            ("Sprachnachricht als Banner", content(voice: true), state(expanded: false, banner: voiceMessage)),
            ("Sprachnachricht in der Notch", content(voice: true), state(expanded: true)),
            ("Sprachnachricht schmal, neben Claude", content(agents: true, voice: true), state(expanded: true)),
            ("vier Chats neben Terminen (Liste scrollt)", { var c = content(agenda: true); c.threads = manyThreads; return c }(), state(expanded: true)),
            ("Gruppennachricht als Banner (mit Absender)", content(chats: true), state(expanded: false, banner: threads[1].latest)),
            ("Foto als Banner", content(media: true), state(expanded: false, banner: photoMessage)),
            ("WhatsApp mit Foto und Profilbild", content(media: true), state(expanded: true)),
            ("WhatsApp mit Dokument", content(media: true), { let s = state(expanded: true); s.selectedChat = "d"; return s }()),
            ("Chat geöffnet (Klick auf einen Chat)", { var c = content(media: true); c.threads[0] = ChatThread(id: "m", name: "Beispiel Fotos", group: false, messages: [chatVoice, chatPhoto]); c.chat = openChat; return c }(), state(expanded: true)),
            ("Gruppenchat geöffnet", { var c = content(); c.chat = openGroup; return c }(), state(expanded: true)),
            ("nur Musik", content(music: true), state(expanded: true)),
            ("nur Termine", content(agenda: true), state(expanded: true)),
            ("nur Claude und Codex", content(agents: true), state(expanded: true)),
            ("Codex fragt (Banner)", content(agents: true), state(expanded: false, question: asking.sessions[0])),
            ("Codex fragt, Notch offen", content(agents: true, asking: asking), state(expanded: true)),
            ("Codex fragt, mit Musik und Terminen", content(music: true, agenda: true, agents: true, asking: asking), state(expanded: true)),
            ("Musik und WhatsApp", content(music: true, chats: true), state(expanded: true)),
            ("alles", content(music: true, chats: true, agenda: true, agents: true), state(expanded: true)),
        ]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Color(hex: 0x3B5378), Color(hex: 0x6E5A80)], startPoint: .top, endPoint: .bottom)
                        Color.black.opacity(0.25).frame(height: 33).frame(maxHeight: .infinity, alignment: .top)
                        UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                            .fill(Color(hex: 0x202020))
                            .frame(width: notch.width, height: notch.height)
                        NotchBody(content: row.1, state: row.2, notchSize: notch)
                    }
                    .frame(width: NotchGeometry.panelSize.width,
                           height: row.2.expanded ? (row.1.chat != nil ? NotchLayout.chat.height + 20 : 236) : row.2.question.map { NotchLayout.questionSize(for: $0).height + 22 }
                               ?? (row.2.banner != nil || row.2.done != nil || row.2.meeting != nil || row.2.dropping ? 156 : 50), alignment: .top)
                    .clipped()
                }
            }
        }
        .padding(16)
        .background(Color(hex: 0x15151A))
        .environment(\.inSnapshot, true)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// The widget as it looks `time` seconds into a mood.
    private static func frame(_ activity: ActivitySnapshot, _ usage: UsageState, mood: Mood, at time: TimeInterval, poked: Bool) -> some View {
        let critter = Critter()
        var pose = critter.pose
        for step in stride(from: 0, through: time, by: 1.0 / 15) {
            pose = critter.step(at: step, mood: mood, track: CritterPainter.track)
        }
        return ZStack(alignment: .topLeading) {
            WidgetCard(activity: activity, usage: usage, glass: false)
                .padding(.leading, WidgetMetrics.margin)
                .padding(.top, WidgetMetrics.band)
            AgendaCard(events: mood == .sleeping ? [] : sampleEvents, access: .granted, onlyLocalCalendars: mood == .sleeping, glass: false)
                .padding(.leading, WidgetMetrics.margin)
                .padding(.top, WidgetMetrics.band + WidgetMetrics.card.height + WidgetMetrics.gap)
            CritterView(pose: pose, mood: mood, time: time, pokeAge: poked ? 0.3 : .infinity, sweating: mood == .working)
                .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.band + 12)
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.size.height, alignment: .topLeading)
    }
}
