import AppKit
import SwiftUI

// MARK: Open notch

struct ExpandedNotch: View {
    let content: NotchContent
    let state: NotchState
    let sections: [NotchSection]
    let size: CGSize
    let actions: NotchActions
    let notchHeight: CGFloat

    var body: some View {
        let width = NotchLayout.sectionWidth(in: size, count: sections.count)
        VStack(spacing: 0) {
            // The row beside the camera.
            HStack {
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(Locale(identifier: "de_DE"))))
                Spacer()
                BatteryLabel()
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 30)
            .frame(height: notchHeight)

            HStack(alignment: .top, spacing: NotchLayout.gap) {
                ForEach(sections, id: \.self) { section in
                    Group {
                        switch section {
                        case .music: MusicSection(content: content, actions: actions, width: width)
                        case .whatsapp: WhatsAppSection(threads: content.threads, state: state, actions: actions, width: width)
                        case .agenda: AgendaSection(content: content, actions: actions, width: width)
                        case .shelf: ShelfSection(items: content.shelf, width: width)
                        case .agents: AgentsSection(content: content, actions: actions, width: width)
                        }
                    }
                    .frame(width: width)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(height: NotchLayout.sectionHeight)
            .padding(.horizontal, NotchLayout.padding)
            .padding(.top, 8)
        }
    }
}

/// Sections get the wide layout from this width on.
private let wideFrom: CGFloat = 300

// MARK: Music

private struct MusicSection: View {
    let content: NotchContent
    let actions: NotchActions
    let width: CGFloat

    var body: some View {
        Section {
            if let track = content.track {
                // The full transport needs a little more room than the other wide layouts.
                if width >= 330 { wide(track) } else { narrow(track) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Musik")
                    Hint(text: content.mediaBlocked
                         ? "Steuerung erlauben: Systemeinstellungen › Datenschutz › Automation › Claude Pet"
                         : "Gerade läuft nichts in Spotify oder Musik.")
                }
            }
        }
    }

    /// On its own: big cover, the whole transport, shuffle, repeat and volume.
    private func wide(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ArtworkView(image: content.artwork, size: min(112, max(84, width * 0.27)), radius: 18)
                .shadow(color: content.accent.opacity(content.artwork == nil ? 0 : 0.55), radius: 18)
                .onTapGesture(perform: actions.openPlayer)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: track.title, font: .system(size: 15, weight: .semibold, design: .rounded), height: 19)
                Text(track.artist).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 6)
                SeekBar(track: track, accent: content.accent, seek: actions.seek)
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    ToggleIcon(symbol: "shuffle", on: track.shuffling, accent: content.accent, action: actions.toggleShuffle)
                    Spacer()
                    Controls(playing: track.playing, actions: actions, big: true)
                    Spacer()
                    ToggleIcon(symbol: "repeat", on: track.repeating, accent: content.accent, action: actions.toggleRepeat)
                }
                Spacer(minLength: 4)
                VolumeBar(volume: track.volume, set: actions.setVolume)
            }
        }
    }

    private func narrow(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ArtworkView(image: content.artwork, size: 50, radius: 10)
                    .shadow(color: content.accent.opacity(content.artwork == nil ? 0 : 0.5), radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: track.title, font: .system(size: 12.5, weight: .semibold, design: .rounded), height: 16)
                    Text(track.artist).font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: actions.openPlayer)
            Spacer(minLength: 8)
            SeekBar(track: track, accent: content.accent, seek: actions.seek)
            HStack {
                Spacer()
                Controls(playing: track.playing, actions: actions, big: false)
                Spacer()
            }
        }
    }
}

private struct Controls: View {
    let playing: Bool
    let actions: NotchActions
    let big: Bool

    var body: some View {
        HStack(spacing: big ? 22 : 16) {
            control("backward.fill", size: big ? 15 : 12, action: actions.previous)
            control(playing ? "pause.fill" : "play.fill", size: big ? 24 : 17, action: actions.playPause)
            control("forward.fill", size: big ? 15 : 12, action: actions.next)
        }
        .foregroundStyle(.white)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: size + 12, height: size + 8).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

private struct ToggleIcon: View {
    let symbol: String
    let on: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(on ? accent : .white.opacity(0.4))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Elapsed and remaining time; click or drag anywhere on the bar to jump there.
private struct SeekBar: View {
    let track: Track
    let accent: Color
    let seek: (Double) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = track.playing ? context.date.timeIntervalSince(track.fetched) : 0
            let position = min(track.position + elapsed, track.duration)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(accent).frame(width: track.duration > 0 ? geo.size.width * position / track.duration : 0)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                        seek(min(max(drag.location.x / geo.size.width, 0), 1) * track.duration)
                    })
                }
                .frame(height: 10)
                HStack {
                    Text(Self.clock(position))
                    Spacer()
                    Text("-" + Self.clock(max(track.duration - position, 0)))
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Player volume; set when the drag ends, one AppleScript call instead of dozens.
private struct VolumeBar: View {
    let volume: Int
    let set: (Int) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
            GeometryReader { geo in
                let value = dragging ?? Double(volume) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(0.85)).frame(width: geo.size.width * value)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded { _ in
                        if let dragging { set(Int((dragging * 100).rounded())) }
                        dragging = nil
                    })
            }
            .frame(height: 10)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: WhatsApp

/// Looks like WhatsApp's own dark theme: panel, bubbles and the green accent.
private struct WhatsAppSection: View {
    let threads: [ChatThread]
    @Bindable var state: NotchState
    let actions: NotchActions
    let width: CGFloat

    private var selected: ChatThread? { threads.first { $0.id == state.selectedChat } ?? threads.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if width >= 380 { wide } else { narrow }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.waPanel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.whatsapp.opacity(0.18), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            AppIcon(bundleID: "net.whatsapp.WhatsApp", size: 14)
            Text("WhatsApp").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(Palette.whatsapp)
            Text("\(threads.reduce(0) { $0 + $1.messages.count }) neu")
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Palette.whatsapp))
            Spacer()
            Button { actions.openWhatsApp(nil) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.waMuted)
                    .frame(width: 22, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("In WhatsApp öffnen")
        }
    }

    /// Chats on the left, the newest conversation with its reply field on the right.
    private var wide: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                header
                list(plays: false)
            }
            .frame(width: min(210, width * 0.42))
            if let selected {
                Conversation(thread: selected, state: state, actions: actions)
            }
        }
    }

    /// Next to other sections: every unread chat, a click opens it across the notch.
    private var narrow: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            list(plays: true)
        }
    }

    @Environment(\.inSnapshot) private var inSnapshot

    private func list(plays: Bool) -> some View {
        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach(threads) { thread in
                ChatRow(thread: thread, selected: false, plays: plays)
                    .onTapGesture { actions.openChat(thread.id) }
            }
        }
        return Group {
            if inSnapshot {
                rows.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { rows }.scrollIndicators(.never)
            }
        }
    }
}

private struct ChatRow: View {
    let thread: ChatThread
    let selected: Bool
    /// The narrow layout has no conversation pane, so a voice message plays from the row itself.
    var plays = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: thread.name, group: thread.group, size: 26, jid: thread.id)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(thread.name).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(AgendaEvent.clock(thread.latest.date)).font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(Palette.whatsapp)
                }
                HStack(spacing: 4) {
                    if plays, thread.latest.media == "audio" {
                        VoiceRow(message: thread.latest, width: 200, mini: true)
                    } else {
                        if let symbol = thread.latest.mediaSymbol {
                            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.waMuted)
                        }
                        Text(thread.latest.preview).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.waMuted).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if thread.messages.count > 1 {
                        Text("\(thread.messages.count)").font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.black).frame(minWidth: 15, minHeight: 15)
                            .background(Circle().fill(Palette.whatsapp))
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(hovering ? 0.12 : selected ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Chat öffnen")
    }
}

/// The last messages of one chat as bubbles, oldest on top, and the reply field.
private struct Conversation: View {
    let thread: ChatThread
    @Bindable var state: NotchState
    let actions: NotchActions

    var body: some View {
        // A picture needs the room of two text bubbles.
        let shown = Array(thread.messages.prefix(thread.latest.media.isEmpty ? 2 : 1).reversed())
        VStack(alignment: .leading, spacing: 5) {
            Button { actions.openChat(thread.id) } label: {
                HStack(spacing: 6) {
                    Text(thread.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    if thread.group {
                        Image(systemName: "person.2.fill").font(.system(size: 9)).foregroundStyle(Palette.waMuted)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.waMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ganzen Chat öffnen")
            ForEach(shown) { message in
                Bubble(message: message, lines: shown.count == 1 ? 3 : 1)
            }
            Spacer(minLength: 0)
            ReplyField(thread: thread, state: state, actions: actions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Open chat

/// One chat across the whole notch, like in WhatsApp: the last messages with Maik's own on the right,
/// pictures and voice messages in full, and the reply field. Opened by a click on a chat.
struct ChatView: View {
    let thread: ChatThread
    /// Messages not seen yet; a divider marks where they start.
    let unread: [ChatMessage]
    @Bindable var state: NotchState
    let actions: NotchActions
    let notchHeight: CGFloat
    @Environment(\.inSnapshot) private var inSnapshot

    private var messages: [ChatMessage] { thread.messages.reversed() }
    private var firstUnread: Int64? { unread.count > 1 || messages.count > 1 ? unread.last?.id : nil }
    private var subtitle: String {
        if !unread.isEmpty { return unread.count == 1 ? "1 neue Nachricht" : "\(unread.count) neue Nachrichten" }
        return thread.group ? "Gruppe" : "WhatsApp"
    }

    var body: some View {
        VStack(spacing: 0) {
            // The row beside the camera: back to the overview, or on to WhatsApp itself.
            HStack {
                Button(action: actions.closeChat) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Chats")
                    }
                    .foregroundStyle(Palette.whatsapp)
                    .frame(height: notchHeight).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Zurück zur Übersicht")
                Spacer()
                Button { actions.openWhatsApp(thread.id) } label: {
                    HStack(spacing: 4) {
                        Text("In WhatsApp")
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(height: notchHeight).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("In WhatsApp öffnen")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Avatar(name: thread.name, group: thread.group, size: 30, jid: thread.id)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(thread.name).font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(subtitle).font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(unread.isEmpty ? Palette.waMuted : Palette.whatsapp)
                    }
                    Spacer(minLength: 0)
                }
                if inSnapshot {
                    // Newest at the bottom edge, older ones cut off above, as the scroll view starts out.
                    Color.clear.overlay(alignment: .bottom) { lines }.clipped()
                } else {
                    ScrollView { lines }
                        .defaultScrollAnchor(.bottom)
                        .scrollIndicators(.never)
                }
                ReplyField(thread: thread, state: state, actions: actions)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.waPanel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.whatsapp.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, NotchLayout.padding)
            .padding(.top, 4)
            .padding(.bottom, NotchLayout.padding)
        }
    }

    private var lines: some View {
        // Sixty messages at most: a plain stack keeps the bottom anchor exact, a lazy one only estimates.
        let shown = messages
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                let previous = index > 0 ? shown[index - 1] : nil
                let newDay = previous.map { !Calendar.current.isDate($0.date, inSameDayAs: message.date) } ?? true
                if newDay { DayDivider(date: message.date) }
                if message.id == firstUnread { UnreadDivider(count: unread.count) }
                // Messages in a row from the same person sit closer together, as in WhatsApp.
                let sameRun = !newDay && previous.map { $0.fromMe == message.fromMe && $0.sender == message.sender
                    && message.date.timeIntervalSince($0.date) < 300 } ?? false
                ChatLine(message: message, group: thread.group, showsSender: !sameRun)
                    .padding(.top, sameRun ? 2 : 6)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// One message in the open chat: incoming on the left (with the writer's name in groups), own on the right.
private struct ChatLine: View {
    let message: ChatMessage
    let group: Bool
    var showsSender = true

    var body: some View {
        HStack(spacing: 0) {
            if message.fromMe { Spacer(minLength: 90) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                if group, showsSender, !message.fromMe, !message.sender.isEmpty {
                    Text(message.sender).font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Avatar.color(for: message.sender)).lineLimit(1).padding(.horizontal, 4)
                }
                Bubble(message: message, lines: 8, large: true)
            }
            if !message.fromMe { Spacer(minLength: 90) }
        }
    }
}

/// "Heute", "Gestern" or the date above the first message of a day.
private struct DayDivider: View {
    let date: Date

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "de_DE")))
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(Palette.waMuted)
            .padding(.horizontal, 9).frame(height: 18)
            .background(Capsule().fill(Palette.waBubble))
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }
}

/// Where the unread part of a chat begins, as in WhatsApp.
private struct UnreadDivider: View {
    let count: Int

    var body: some View {
        Text(count == 1 ? "1 ungelesene Nachricht" : "\(count) ungelesene Nachrichten")
            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.whatsapp)
            .padding(.horizontal, 10).frame(height: 20)
            .background(Capsule().fill(.white.opacity(0.06)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let lines: Int
    /// In the open chat: bigger pictures and text with its line breaks.
    var large = false

    /// What was written; for a photo without caption nothing, the picture speaks for itself.
    private var words: String {
        if large { return message.caption.isEmpty && message.media.isEmpty ? message.text : message.caption }
        return message.media.isEmpty ? message.text : message.caption.replacingOccurrences(of: "\n", with: " ")
    }
    private var fill: Color { message.fromMe ? Palette.waOutgoing : Palette.waBubble }

    var body: some View {
        switch message.media {
        case "sticker":
            MediaPreview(message: message, height: large ? 96 : 64, sticker: true)
        case "image", "video":
            picture
                .contentShape(Rectangle())
                .onTapGesture { WhatsAppMedia.shared.open(message) }
                .help(message.media == "video" ? "Video abspielen" : "Foto groß ansehen")
        case "document":
            bubble { attachment(symbol: "doc.fill", title: message.filename ?? "Dokument", detail: size) }
                .contentShape(Rectangle())
                .onTapGesture { WhatsAppMedia.shared.open(message) }
                .help("Öffnen")
        case "audio":
            bubble { VoiceRow(message: message, width: 250) }
        default:
            bubble {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(words).font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95)).lineLimit(lines)
                        .fixedSize(horizontal: false, vertical: large)
                    time
                }
            }
        }
    }

    /// Like WhatsApp: the photo fills the bubble, the time sits on it unless a caption follows.
    private var picture: some View {
        let height: CGFloat = large ? (words.isEmpty ? 120 : 104) : (words.isEmpty ? 70 : 50)
        let width = MediaPreview.width(for: message, height: height)
        return VStack(alignment: .leading, spacing: 3) {
            MediaPreview(message: message, height: height, sticker: false)
                .overlay(alignment: .bottomTrailing) {
                    if words.isEmpty {
                        time.foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.black.opacity(0.45))).padding(4)
                    }
                }
            if !words.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(words).font(.system(size: 11.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95)).lineLimit(large ? 4 : 1)
                        .fixedSize(horizontal: false, vertical: large)
                    Spacer(minLength: 0)
                    time
                }
                .frame(width: width - 4)
                .padding(.horizontal, 2)
            }
        }
        .padding(3)
        .background(shape.fill(fill))
    }

    private var time: some View {
        Text(AgendaEvent.clock(message.date)).font(.system(size: 8.5, weight: .medium, design: .rounded))
            .monospacedDigit().foregroundStyle(message.fromMe ? .white.opacity(0.6) : Palette.waMuted)
    }

    /// Flat corner at the top left for incoming, top right for own messages, like in WhatsApp.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: message.fromMe ? 12 : 3, bottomLeadingRadius: 12, bottomTrailingRadius: 12,
                               topTrailingRadius: message.fromMe ? 3 : 12, style: .continuous)
    }

    private func bubble(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(shape.fill(fill))
    }

    private var size: String {
        message.size > 0 ? ByteCountFormatter.string(fromByteCount: message.size, countStyle: .file) : "Dokument"
    }

    private func attachment(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.whatsapp.opacity(0.35)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 6) {
                    Text(detail).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.waMuted)
                    time
                }
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A voice message as WhatsApp shows it: play button, waveform filling up, time and speed.
struct VoiceRow: View {
    let message: ChatMessage
    let width: CGFloat
    var compact = false
    /// Inside a chat row: just as tall as a line of text.
    var mini = false

    private var player: VoicePlayer { VoicePlayer.shared }
    private var button: CGFloat { mini ? 18 : compact ? 26 : 32 }
    private var barHeight: CGFloat { mini ? 11 : compact ? 16 : 22 }
    private var voice: (path: String, duration: TimeInterval)? { WhatsAppMedia.shared.voices[message.mediaKey] }
    private var isCurrent: Bool { player.current == message.mediaKey }

    /// The same made-up waveform for a message every time, from its id.
    private var bars: [CGFloat] {
        var seed = message.messageID.unicodeScalars.reduce(UInt32(17)) { $0 &* 31 &+ $1.value }
        return (0..<(mini ? 16 : compact ? 18 : 28)).map { _ in
            seed = seed &* 1664525 &+ 1013904223
            return 0.25 + CGFloat(seed % 1000) / 1333
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Button { player.toggle(message) } label: {
                Image(systemName: isCurrent && player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: mini ? 8 : compact ? 11 : 13, weight: .bold)).foregroundStyle(.black)
                    .frame(width: button, height: button)
                    .background(Circle().fill(voice == nil ? Palette.whatsapp.opacity(0.4) : Palette.whatsapp))
            }
            .buttonStyle(PressStyle())
            .help(voice == nil ? "Wird geladen …" : "Anhören")
            let duration = max(voice?.duration ?? 0, 0.1)
            let done = isCurrent ? player.position / duration : 0
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(Double(index) / Double(bars.count) < done ? Palette.whatsapp : .white.opacity(0.35))
                        .frame(width: mini ? 2.5 : 3, height: barHeight * height)
                }
            }
            .frame(height: barHeight + 2)
            VStack(alignment: .trailing, spacing: 1) {
                Text(clock(isCurrent ? player.position : (voice?.duration ?? 0)))
                    .font(.system(size: mini ? 9.5 : 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.waMuted)
                if isCurrent, !compact, !mini {
                    Button { player.cycleRate() } label: {
                        Text(player.rate == 1 ? "1×" : player.rate == 1.5 ? "1,5×" : "2×")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(height: 15)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
        .frame(maxWidth: width, alignment: .leading)
        .task(id: message.mediaKey) { WhatsAppMedia.shared.loadVoice(message) }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// A photo, video frame or sticker from a message, loaded on demand through the bridge.
private struct MediaPreview: View {
    let message: ChatMessage
    let height: CGFloat
    let sticker: Bool

    var body: some View {
        let image = WhatsAppMedia.shared.preview(for: message)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: sticker ? .fit : .fill)
            } else if !sticker {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06))
                Image(systemName: message.media == "video" ? "video.fill" : "photo")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.waMuted)
            }
            if message.media == "video" {
                Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.55)))
            }
        }
        .frame(width: Self.width(for: message, height: height, sticker: sticker), height: height)
        .clipShape(RoundedRectangle(cornerRadius: sticker ? 0 : 9, style: .continuous))
        .task(id: message.mediaKey) { WhatsAppMedia.shared.loadPreview(message) }
    }

    /// The picture's own shape, kept between portrait 3:4 and a wide 16:9.
    static func width(for message: ChatMessage, height: CGFloat, sticker: Bool = false) -> CGFloat {
        guard let image = WhatsAppMedia.shared.preview(for: message), image.size.height > 0 else { return height * 1.4 }
        return height * min(max(image.size.width / image.size.height, sticker ? 0.5 : 0.75), 1.78)
    }
}

/// Answer without leaving what you are doing. The notch takes the keyboard only while you type.
private struct ReplyField: View {
    let thread: ChatThread
    @Bindable var state: NotchState
    let actions: NotchActions
    @FocusState private var focused: Bool

    /// "Antworten an Anna …", in a group the group's whole name.
    private var firstName: String { thread.group ? thread.name : thread.name.split(separator: " ").first.map(String.init) ?? thread.name }
    private var typing: Bool { state.replyTo == thread.id }

    var body: some View {
        HStack(spacing: 8) {
            switch (typing, state.sendState) {
            case (true, .sent):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.whatsapp)
                Text("Gesendet").foregroundStyle(Palette.whatsapp)
                Spacer()
            case (true, _):
                TextField("Nachricht an \(firstName)", text: $state.draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(actions.sendReply)
                    .onExitCommand(perform: actions.cancelReply)
                    .task {
                        // The panel turns key a moment after the click.
                        try? await Task.sleep(for: .milliseconds(60))
                        focused = true
                    }
                if state.sendState == .sending {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: actions.sendReply) {
                        Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 22, height: 22).background(Circle().fill(Palette.whatsapp))
                    }
                    .buttonStyle(PressStyle())
                    .disabled(state.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case (false, _):
                Button { actions.beginReply(thread.id) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10, weight: .bold))
                        Text("Antworten an \(firstName) …").lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.waMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.leading, 12)
        .padding(.trailing, typing ? 4 : 12)
        .frame(height: 30)
        .background(Capsule().fill(Palette.waBubble))
        .overlay(alignment: .bottomLeading) {
            if typing, state.sendState == .failed {
                Text("Nicht gesendet: läuft die WhatsApp-Bridge?").font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.alarm).offset(x: 12, y: 13)
            }
        }
    }
}

/// Initials on a colour picked from the name, the same colour every time.
struct Avatar: View {
    let name: String
    let group: Bool
    let size: CGFloat
    /// The chat, to show its WhatsApp profile picture once the bridge delivered it.
    var jid: String?

    private static let colors: [UInt32] = [0xC0674A, 0xC79A2E, 0x3E9E78, 0x3C82C4, 0x6F67C9, 0xB25D9B, 0x2E9C95, 0x7F9A3F]

    private var initials: String {
        let letters = name.split(separator: " ").compactMap { $0.first(where: \.isLetter) }.prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var color: Color { Self.color(for: name) }

    /// The same colour for a name everywhere, also for writers in a group chat.
    static func color(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return Color(hex: colors[Int(hash % UInt32(colors.count))])
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            Text(initials).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white)
            if let jid, let photo = WhatsAppMedia.shared.avatar(for: jid) {
                Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .task(id: jid) { if let jid { WhatsAppMedia.shared.loadAvatar(jid) } }
        .overlay(alignment: .bottomTrailing) {
            if group {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.22, weight: .bold)).foregroundStyle(.white)
                    .padding(2).background(Circle().fill(Palette.waPanel)).offset(x: 2, y: 2)
            }
        }
    }
}

/// A new direct message: the notch drops down with reply and open, a click away.
struct Banner: View {
    let message: ChatMessage
    let actions: NotchActions
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 12) {
                    Avatar(name: message.chat, group: message.group, size: 38, jid: message.jid)
                        .overlay(alignment: .bottomTrailing) {
                            AppIcon(bundleID: "net.whatsapp.WhatsApp", size: 15).offset(x: 4, y: 4)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(message.chat).font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
                            Spacer()
                            Text("jetzt").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Palette.waMuted)
                        }
                        HStack(spacing: 5) {
                            if let symbol = message.mediaSymbol {
                                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.waMuted)
                            }
                            Text(message.preview).font(.system(size: 12.5, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        }
                    }
                    if message.showsPreview, let image = WhatsAppMedia.shared.preview(for: message) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.openChat(message.jid) }
                .help("Chat öffnen")
                HStack(spacing: 8) {
                    if message.media == "audio" {
                        VoiceRow(message: message, width: 200, compact: true)
                    }
                    Spacer()
                    pill("Öffnen", symbol: "arrow.up.forward.app", fill: .white.opacity(0.12), text: .white) { actions.openWhatsApp(message.jid) }
                    pill("Antworten", symbol: "arrowshape.turn.up.left.fill", fill: Palette.whatsapp, text: .black) {
                        actions.beginReply(message.jid)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }

    private func pill(_ title: String, symbol: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(text)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(fill))
        }
        .buttonStyle(PressStyle())
    }
}

/// Claude or Codex asks something: the notch drops down with the question and its choices.
/// Answering happens in the app itself, one click away.
struct QuestionBanner: View {
    let session: SessionStatus
    let actions: NotchActions
    let notchHeight: CGFloat

    private var name: String { session.agent == .codex ? "Codex" : "Claude" }
    private var question: PendingQuestion { session.question ?? PendingQuestion(title: "Wartet auf deine Antwort", options: []) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(alignment: .top, spacing: 14) {
                TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    Group {
                        if session.agent == .codex { CodexIcon(p: 2.5, mood: .asking, time: time) }
                        else { ClawdIcon(pw: 2.5, ph: 5, mood: .asking, time: time) }
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "questionmark.circle.fill").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.amber).background(Circle().fill(.black)).offset(x: 7, y: -7)
                    }
                }
                .frame(width: 44, height: 40)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(question.options.isEmpty ? "\(name) wartet auf dich" : "\(name) fragt")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundStyle(Palette.amber)
                            .fixedSize()
                        Text(session.title).font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        Spacer(minLength: 8)
                        Button { actions.openAgent(session.agent) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .bold))
                                Text("Antworten").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(session.agent == .codex ? .white : .black)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(session.agent == .codex ? Palette.codex : Palette.clawd))
                        }
                        .buttonStyle(PressStyle())
                        .fixedSize()
                        .help("In \(name) öffnen und antworten")
                    }
                    QuestionLines(question: question, lines: 3, options: 3, size: 12.5)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }
}

/// Claude or Codex finished: the pet cheers, the first line of the answer says what came out.
struct DoneBanner: View {
    let session: SessionStatus
    let actions: NotchActions
    let notchHeight: CGFloat

    private var name: String { session.agent == .codex ? "Codex" : "Claude" }
    private var tint: Color { session.agent == .codex ? Palette.codex : Palette.clawd }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(alignment: .top, spacing: 14) {
                TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    if session.agent == .codex { CodexIcon(p: 2.5, mood: .done, time: time) }
                    else { ClawdIcon(pw: 2.5, ph: 5, mood: .done, time: time) }
                }
                .frame(width: 46, height: 40)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.mint)
                        Text("\(name) ist fertig").font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.mint).fixedSize()
                        Text(session.title).font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        Spacer(minLength: 6)
                        Button(action: actions.dismissBanner) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                                .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(PressStyle())
                    }
                    Text(session.summary ?? "Fertig. Das Ergebnis steht in \(name).")
                        .font(.system(size: 12.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button { actions.openAgent(session.agent); actions.dismissBanner() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .bold))
                                Text("In \(name) öffnen").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(session.agent == .codex ? .white : .black)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(tint))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }
}

/// An appointment starts in a moment: title, time and a big button into the call.
struct MeetingBanner: View {
    let event: AgendaEvent
    let actions: NotchActions
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(event.start.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "de_DE"))).uppercased())
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 14).background(event.color)
                    Text(event.start.formatted(.dateTime.day()))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 42, height: 44)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(when(at: context.date)).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(event.start <= context.date ? Palette.mint : Palette.amber).monospacedDigit()
                    }
                    if let location = event.location {
                        Text(location).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: actions.dismissBanner) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(PressStyle())
                    if let url = event.meetingURL {
                        Button { actions.openMeeting(url); actions.dismissBanner() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "video.fill").font(.system(size: 11, weight: .bold))
                                Text("Beitreten").font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(Capsule().fill(Palette.join))
                        }
                        .buttonStyle(PressStyle())
                    } else {
                        Button { actions.openCalendar(); actions.dismissBanner() } label: {
                            Text("Im Kalender").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 26)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }

    private func when(at now: Date) -> String {
        let seconds = Int(event.start.timeIntervalSince(now))
        if seconds <= 0 { return "läuft seit \(max(-seconds / 60, 0)) Min. · bis \(AgendaEvent.clock(event.end))" }
        if seconds < 60 { return "beginnt in \(seconds) s · \(AgendaEvent.clock(event.start))" }
        return "beginnt in \((seconds + 59) / 60) Min. · \(AgendaEvent.clock(event.start))"
    }
}

/// A question from Claude that Maik answers right here: one click per answer goes straight back
/// to Claude. The bar runs down until Claude shows the question in its own window instead.
struct AskBanner: View {
    let ask: AskRequest
    let title: String
    let index: Int
    let actions: NotchActions
    let notchHeight: CGFloat

    private var question: AskRequest.Question { ask.questions[min(index, ask.questions.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                        ClawdIcon(pw: 2.5, ph: 5, mood: .asking, time: context.date.timeIntervalSinceReferenceDate)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "questionmark.circle.fill").font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Palette.amber).background(Circle().fill(.black)).offset(x: 7, y: -7)
                            }
                    }
                    .frame(width: 46, height: 30)
                    .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Claude fragt").font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.amber).fixedSize()
                            Text(title).font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            Spacer(minLength: 8)
                            if ask.questions.count > 1 {
                                Text("Frage \(index + 1) von \(ask.questions.count)")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55)).fixedSize()
                            }
                        }
                        Text(question.question).font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92)).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(Array(question.options.prefix(4).enumerated()), id: \.offset) { number, option in
                        Button { actions.pickAnswer(number) } label: { row(number, option) }
                            .buttonStyle(RowPressStyle())
                    }
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    private func row(_ number: Int, _ option: AskRequest.Option) -> some View {
        HStack(spacing: 10) {
            Text("\(number + 1)").font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.black).frame(width: 20, height: 20)
                .background(Circle().fill(Palette.amber))
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1)
                if let description = option.description, !description.isEmpty {
                    Text(description).font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
        .contentShape(Rectangle())
    }

    /// Time left before Claude shows the question itself, and the way to answer there right away.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let left = max(ask.deadline.timeIntervalSince(context.date), 0)
            let total = max(Setting.value(Setting.askSeconds), 1)
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(Palette.amber.opacity(0.8)).frame(width: geo.size.width * min(left / total, 1))
                    }
                }
                .frame(height: 4)
                Text("\(Int(left.rounded(.up))) s").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.55)).frame(width: 30, alignment: .trailing)
                Button(action: actions.answerInClaude) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .bold))
                        Text("In Claude antworten").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(PressStyle())
                .fixedSize()
            }
        }
    }
}

/// Wide answer rows: a gentle press instead of the icon buttons' deep one.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// The question itself and its numbered choices, as Claude or Codex put them.
private struct QuestionLines: View {
    let question: PendingQuestion
    let lines: Int
    let options: Int
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.title).font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.9)).lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.prefix(options).enumerated()), id: \.offset) { index, option in
                HStack(spacing: 7) {
                    Text("\(index + 1)").font(.system(size: size - 3, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black).frame(width: size + 2, height: size + 2)
                        .background(Circle().fill(Palette.amber.opacity(0.9)))
                    Text(option).font(.system(size: size - 1, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            if question.options.count > options {
                Text("+\(question.options.count - options) weitere Antworten").font(.system(size: size - 2.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: Agenda

private struct AgendaSection: View {
    let content: NotchContent
    let actions: NotchActions
    let width: CGFloat

    private var upcoming: [AgendaEvent] { content.events.filter { !$0.allDay } }

    var body: some View {
        Section {
            switch content.agendaAccess {
            case .unknown:
                Hint(text: "Kalender wird geladen …")
            case .denied:
                Hint(text: "Freigeben: Systemeinstellungen › Datenschutz › Kalender")
            case .granted:
                if let next = upcoming.first {
                    if width >= wideFrom { wide(next) } else { narrow }
                } else {
                    Hint(text: content.onlyLocalCalendars
                         ? "Google-Kalender fehlt: Systemeinstellungen › Internetaccounts"
                         : "Heute und morgen nichts mehr.")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.openCalendar)
    }

    /// On its own: the next appointment large, with a join button for video calls.
    private func wide(_ next: AgendaEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Als Nächstes")
                Spacer()
                Countdown(event: next)
            }
            Spacer(minLength: 8)
            HStack(alignment: .center, spacing: 11) {
                Capsule().fill(next.color).frame(width: 4, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(next.title).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(detail(next)).font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let url = next.meetingURL { JoinButton(url: url, compact: false, open: actions.openMeeting) }
            }
            Spacer(minLength: 8)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            Spacer(minLength: 6)
            ForEach(upcoming.dropFirst().prefix(2)) { event in
                HStack(spacing: 8) {
                    Text(time(event)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5)).frame(width: 66, alignment: .leading)
                    Circle().fill(event.color).frame(width: 6, height: 6)
                    Text(event.title).font(.system(size: 11.5, weight: .medium, design: .rounded)).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 1)
            }
            if upcoming.count == 1 {
                Text("Danach ist der Kalender frei.").font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var narrow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Termine")
            ForEach(Array(upcoming.prefix(3).enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .center, spacing: 7) {
                    Capsule().fill(event.color).frame(width: 3, height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(event.when).font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(index == 0 && event.start.timeIntervalSinceNow < 3600 ? Palette.amber : .white.opacity(0.5))
                    }
                    Spacer(minLength: 2)
                    if index == 0, let url = event.meetingURL { JoinButton(url: url, compact: true, open: actions.openMeeting) }
                }
            }
        }
    }

    private func detail(_ event: AgendaEvent) -> String {
        let span = AgendaEvent.clock(event.start) + " – " + AgendaEvent.clock(event.end)
        if let location = event.location { return span + " · " + location }
        if let host = event.meetingURL?.host {
            let service = host.contains("meet.google") ? "Google Meet" : host.contains("zoom") ? "Zoom"
                : host.contains("teams") ? "Teams" : "Videocall"
            return span + " · " + service
        }
        return span
    }

    private func time(_ event: AgendaEvent) -> String {
        let clock = AgendaEvent.clock(event.start)
        if Calendar.current.isDateInToday(event.start) { return clock }
        return event.start.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "de_DE"))) + " " + clock
    }
}

private struct Countdown: View {
    let event: AgendaEvent

    var body: some View {
        let seconds = event.start.timeIntervalSinceNow
        let (text, color): (String, Color) =
            if seconds <= 0 { ("läuft", Palette.mint) }
            else if seconds < 3600 { ("in \(max(Int(seconds / 60), 1)) Min.", Palette.amber) }
            else { (event.when, .white.opacity(0.6)) }
        Text(text).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

private struct JoinButton: View {
    let url: URL
    let compact: Bool
    let open: (URL) -> Void

    var body: some View {
        Button { open(url) } label: {
            HStack(spacing: 5) {
                Image(systemName: "video.fill").font(.system(size: 10, weight: .bold))
                if !compact { Text("Beitreten").font(.system(size: 11.5, weight: .semibold, design: .rounded)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 7 : 12)
            .frame(height: compact ? 22 : 28)
            .background(Capsule().fill(Palette.join))
        }
        .buttonStyle(PressStyle())
        .help("Videocall beitreten")
    }
}

// MARK: Shelf

/// Files parked in the notch: drag them out where they are needed, a click opens them.
private struct ShelfSection: View {
    let items: [ShelfItem]
    let width: CGFloat

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: "Ablage")
                    Text("\(items.count)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.white.opacity(0.8)))
                    Spacer()
                    Button("Leeren") { ShelfStore.shared.clear() }
                        .buttonStyle(PressStyle())
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(items) { ShelfTile(item: $0) }
                    }
                }
                Spacer(minLength: 0)
                Hint(text: "Herausziehen zum Ablegen, Klick öffnet.")
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: ShelfStore.shared.image(for: item))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    Button { ShelfStore.shared.remove(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 15, height: 15).background(Circle().fill(.black.opacity(0.75)))
                    }
                    .buttonStyle(PressStyle())
                    .offset(x: 5, y: -4)
                }
            Text(item.name).font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85)).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 66)
        }
        .frame(width: 70)
        .contentShape(Rectangle())
        .onTapGesture { ShelfStore.shared.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.url.path)
    }
}

/// Where dragged files land: the notch opens into a target while files hover over it.
struct DropZone: View {
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hier ablegen").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("Die Dateien bleiben in der Notch, bis du sie wieder herausziehst.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.mint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }
}

// MARK: Agents

/// Claude and Codex at a glance: who works on what, what is done, who waits for you.
/// The limits live on the desktop widget, not here.
private struct AgentsSection: View {
    let content: NotchContent
    let actions: NotchActions
    let width: CGFloat

    private var sessions: [SessionStatus] { content.activity.sessions }
    private var hasCodex: Bool { sessions.contains { $0.agent == .codex } }
    private var hasClaude: Bool { sessions.contains { $0.agent == .claude } }

    private var title: String {
        hasCodex && hasClaude ? "Claude & Codex" : hasCodex ? "Codex" : "Claude"
    }

    private var status: (String, Color) {
        let working = sessions.filter { $0.mood == .working }.count
        switch content.agentMood {
        case .asking: return ("wartet auf dich", Palette.amber)
        case .working: return (working > 1 ? "\(working) arbeiten" : "arbeitet", hasClaude ? Palette.light : Palette.codexLight)
        case .done: return ("fertig", Palette.mint)
        case .idle: return ("bereit", .white.opacity(0.6))
        case .sleeping: return ("schläft", Palette.night)
        }
    }

    var body: some View {
        Section {
            if width >= wideFrom { wide } else { narrow }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.openAgent(sessions.first?.agent ?? .claude) }
    }

    /// Clawd, and Codex's terminal beside him while a Codex thread is live.
    private var mascot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 10) {
                if hasClaude || !hasCodex {
                    ClawdIcon(pw: 3, ph: 6, mood: content.activity.mood, time: time)
                }
                if hasCodex {
                    CodexIcon(p: 3, mood: content.activity.codex ?? .idle, time: time)
                }
            }
        }
    }

    private var wide: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 10) {
                mascot
                Text(status.0).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(status.1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 84)
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: title)
                if sessions.isEmpty {
                    Hint(text: "Gerade läuft nichts. Clawd ruht sich aus.")
                } else if let asking = sessions.first(where: { $0.question != nil }), let question = asking.question {
                    // A question needs the room: who asks, what, and the choices.
                    SessionRow(session: asking, compact: false)
                    QuestionLines(question: question, lines: 2, options: sessions.count > 1 ? 2 : 3, size: 11.5)
                        .padding(.leading, 22)
                    if sessions.count > 1 {
                        Text("+\(sessions.count - 1) weitere").font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                } else {
                    ForEach(sessions.prefix(3)) { SessionRow(session: $0, compact: false) }
                    if sessions.count > 3 {
                        Text("+\(sessions.count - 3) weitere").font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var narrow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 6) {
                        if hasClaude || !hasCodex { ClawdIcon(pw: 2, ph: 4, mood: content.activity.mood, time: time) }
                        if hasCodex { CodexIcon(p: 2, mood: content.activity.codex ?? .idle, time: time) }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(status.0).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(status.1)
                }
            }
            if let question = sessions.first(where: { $0.question != nil })?.question {
                Text(question.title).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85)).lineLimit(4)
            } else {
                ForEach(sessions.prefix(3)) { SessionRow(session: $0, compact: true) }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionStatus
    let compact: Bool

    var body: some View {
        if compact {
            HStack(spacing: 8) {
                icon.frame(width: 14)
                Text(session.title).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 0)
            }
        } else {
            // The name gets the whole line; state and time sit underneath.
            HStack(alignment: .top, spacing: 8) {
                icon.frame(width: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if session.agent == .claude {
                            AppIcon(bundleID: "com.anthropic.claudefordesktop", size: 13)
                        } else {
                            Text(">_").font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                                .frame(width: 15, height: 13).background(RoundedRectangle(cornerRadius: 3).fill(Palette.codex))
                        }
                        Text(session.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    }
                    Text(elapsed.isEmpty ? label : "\(label) · \(elapsed)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(color)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "seit 12 Min." while it works or waits, "vor 1 Min." once it is done.
    private var elapsed: String {
        let minutes = Int(Date.now.timeIntervalSince(session.since) / 60)
        if minutes < 1 { return session.mood == .done ? "gerade eben" : "" }
        let span = minutes < 60 ? "\(minutes) Min." : "\(minutes / 60) Std."
        return (session.mood == .done ? "vor " : "seit ") + span
    }

    private var label: String {
        switch session.mood {
        case .asking: "wartet"
        case .done: "fertig"
        default: "arbeitet"
        }
    }

    private var color: Color {
        switch session.mood {
        case .asking: Palette.amber
        case .done: Palette.mint
        default: session.agent == .codex ? Palette.codexLight : Palette.light
        }
    }

    @ViewBuilder private var icon: some View {
        switch session.mood {
        case .asking: Image(systemName: "questionmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.amber)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.mint)
        default: Circle().fill(session.agent == .codex ? Palette.codex : Palette.clawd).frame(width: 7, height: 7)
        }
    }
}

// MARK: Pieces

private struct Section<Inner: View>: View {
    @ViewBuilder let inner: () -> Inner

    var body: some View {
        inner()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
            // Nothing may spill into the neighbouring card.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.45))
    }
}

private struct Hint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Buttons give way under the finger, like the system's media controls.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A title too long for its space scrolls slowly back and forth instead of being cut off.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let height: CGFloat
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth - geo.size.width
            if overflow > 2 {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    // 25 pt per second, holding 1.5 s at each end.
                    let travel = Double(overflow) / 25
                    let cycle = travel + 3
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                    let offset = CGFloat(min(max(t - 1.5, 0), travel) * 25)
                    Text(text).font(font).fixedSize().offset(x: -offset)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            } else {
                Text(text).font(font).lineLimit(1)
            }
        }
        .frame(height: height)
        .clipped()
        .background(alignment: .leading) {
            Text(text).font(font).fixedSize().hidden()
                .background(GeometryReader { measure in
                    Color.clear.onAppear { textWidth = measure.size.width }
                        .onChange(of: text) { textWidth = measure.size.width }
                })
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Equalizer: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = 0.5 + 0.5 * sin(t * [7.1, 9.3, 6.2, 8.4][i] + Double(i) * 1.3)
                    Capsule().fill(color).frame(width: 3, height: 4 + 10 * wave)
                }
            }
        }
        .frame(width: 20, height: 16)
    }
}

/// Claude Code's thinking spinner, from the same frames Clawd wears above his head.
struct SpinnerGlyph: View {
    let time: TimeInterval
    let pixel: CGFloat
    var color = Palette.clawd

    var body: some View {
        Canvas { context, _ in
            let frame = CritterPainter.spinner[Int(time * 5) % CritterPainter.spinner.count]
            var path = Path()
            for (y, row) in frame.enumerated() {
                for (x, ch) in row.enumerated() where ch == "X" {
                    path.addRect(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
                }
            }
            context.fill(path, with: .color(color))
        }
    }
}

/// Clawd standing still, for the notch: legs tap while he works, arms go up when he is done.
struct ClawdIcon: View {
    let pw: CGFloat
    let ph: CGFloat
    let mood: Mood
    let time: TimeInterval

    var body: some View {
        Canvas { context, _ in
            let beat = Int(time * 2.5) % 2
            let cheering = mood == .done
            var body = Path()
            for (y, row) in CritterPainter.sprite.enumerated() {
                for (x, ch) in row.enumerated() {
                    switch ch {
                    case "#", "E":
                        body.addRect(quad(x, y))
                    case "A" where !cheering:
                        body.addRect(quad(x, y))
                    case "L":
                        let lifted = mood == .working && (x % 4 == 1) == (beat == 0)
                        body.addRect(quad(x, y, height: lifted ? ph / 2 : ph))
                    default:
                        break
                    }
                }
            }
            if cheering {
                for x in [1, 2, 16, 17] { body.addRect(quad(x, 1)) }
            }
            context.fill(body, with: .color(Palette.clawd))

            var eyes = Path()
            let blink = time.truncatingRemainder(dividingBy: 4.2) > 4.05
            for x in CritterPainter.eyes {
                if mood == .sleeping || blink {
                    eyes.addRect(quad(x, 1, height: ph * 0.3, top: ph * 0.6))
                } else if cheering {
                    eyes.addRect(quad(x, 1, height: ph * 0.35, top: ph * 0.2))
                } else {
                    eyes.addRect(quad(x, 1))
                }
            }
            context.fill(eyes, with: .color(Palette.eye))
        }
        .frame(width: 18 * pw, height: 5 * ph)
    }

    private func quad(_ x: Int, _ y: Int, height: CGFloat? = nil, top: CGFloat = 0) -> CGRect {
        CGRect(x: CGFloat(x) * pw, y: CGFloat(y) * ph + top, width: pw, height: height ?? ph)
    }
}

/// Codex's own pet: a little terminal on legs with a `>_` prompt, Clawd's counterpart.
/// Working, its cursor blinks and it taps; done, it throws its arms up; waiting, its screen asks "?".
struct CodexIcon: View {
    let p: CGFloat
    let mood: Mood
    let time: TimeInterval

    // W shell, K screen, A arms, L legs. 16 wide, 9 tall.
    static let sprite = [
        "..WWWWWWWWWWWW..",
        ".WWWWWWWWWWWWWW.",
        ".WKKKKKKKKKKKKW.",
        ".WKKKKKKKKKKKKW.",
        "AWKKKKKKKKKKKKWA",
        ".WKKKKKKKKKKKKW.",
        ".WKKKKKKKKKKKKW.",
        "..WWWWWWWWWWWW..",
        "...LL......LL...",
    ]
    static let shell = Palette.codex
    static let screen = Color(hex: 0x0E1526)
    static let prompt = Color(hex: 0xE6EEFF)

    var body: some View {
        Canvas { context, _ in
            let beat = Int(time * 2.5) % 2
            let cheering = mood == .done
            var shell = Path(), screen = Path(), legs = Path()
            for (y, row) in Self.sprite.enumerated() {
                for (x, ch) in row.enumerated() {
                    switch ch {
                    case "W": shell.addRect(px(x, y))
                    case "K": screen.addRect(px(x, y))
                    case "A" where !cheering: shell.addRect(px(x, y))
                    case "L":
                        let lifted = mood == .working && (x < 8) == (beat == 0)
                        legs.addRect(px(x, y, height: lifted ? p / 2 : p))
                    default: break
                    }
                }
            }
            if cheering {
                for (x, y) in [(0, 2), (0, 1), (15, 2), (15, 1)] { shell.addRect(px(x, y)) }
            }
            context.fill(shell, with: .color(Self.shell))
            context.fill(legs, with: .color(Color(hex: 0x2F57D0)))
            context.fill(screen, with: .color(Self.screen))

            var glyph = Path()
            let color: Color
            if mood == .asking {
                color = Palette.amber
                for (x, y) in [(6, 2), (7, 2), (8, 2), (8, 3), (7, 4), (7, 6)] { glyph.addRect(px(x, y)) }
            } else {
                color = Self.prompt
                for (x, y) in [(3, 3), (4, 4), (3, 5)] { glyph.addRect(px(x, y)) }
                // The cursor blinks while it works and stays lit once it is done.
                if mood != .working || Int(time * 2) % 2 == 0 {
                    for x in 6...8 { glyph.addRect(px(x, 5)) }
                }
            }
            context.fill(glyph, with: .color(color))
        }
        .frame(width: 16 * p, height: 9 * p)
    }

    private func px(_ x: Int, _ y: Int, height: CGFloat? = nil) -> CGRect {
        CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: height ?? p)
    }
}

/// An installed app's own icon (WhatsApp, ChatGPT/Codex, Claude), cached per app.
struct AppIcon: View {
    let bundleID: String
    let size: CGFloat
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    private var image: NSImage? {
        if let cached = Self.cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleID] = icon
        return icon
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Circle().fill(.white.opacity(0.2)).frame(width: size * 0.8, height: size * 0.8)
        }
    }
}

struct BatteryLabel: View {
    var body: some View {
        if let (percent, charging) = PowerWatch.read() {
            HStack(spacing: 4) {
                Text("\(percent) %").monospacedDigit()
                Image(systemName: charging ? "battery.100.bolt" : Self.symbol(percent))
                    .foregroundStyle(percent <= 20 && !charging ? Palette.alarm : .white.opacity(0.7))
            }
        }
    }

    private static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }
}
