import AppKit
import SwiftUI

enum NotchLayout {
    /// Width of each live-activity ear beside the camera.
    static let ear: CGFloat = 40
    static let height: CGFloat = 216
    static let sectionHeight: CGFloat = 160
    static let gap: CGFloat = 12
    static let padding: CGFloat = 16
    /// One WhatsApp chat opened across the notch, like in WhatsApp itself.
    static let chat = CGSize(width: 620, height: 336)
    /// The WhatsApp pop-up, camera row included.
    static let banner = CGSize(width: 460, height: 128)
    /// "Claude ist fertig" with the first line of the answer.
    static let done = CGSize(width: 500, height: 132)
    /// An appointment about to start.
    static let meeting = CGSize(width: 500, height: 124)
    /// The target while files are dragged onto the notch.
    static let dropZone = CGSize(width: 460, height: 130)
    /// A question to answer here: room for the question and one row per answer.
    static func askSize(for ask: AskRequest, index: Int) -> CGSize {
        let question = ask.questions.indices.contains(index) ? ask.questions[index] : nil
        let options = CGFloat(min(question?.options.count ?? 2, 4))
        // About 70 characters fit on a line of the question; it shows at most three lines.
        let lines = CGFloat(min(max((question?.question.count ?? 0) / 70 + 1, 1), 3))
        return CGSize(width: 580, height: 134 + 40 * options + 17 * (lines - 1))
    }

    /// A question from Claude or Codex grows with its answer choices.
    static func questionSize(for session: SessionStatus) -> CGSize {
        CGSize(width: 540, height: 136 + 19 * CGFloat(min(session.question?.options.count ?? 0, 3)))
    }
    /// Opening overshoots a touch like the Dynamic Island; closing settles without a bounce.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let close = Animation.spring(response: 0.32, dampingFraction: 0.92)

    /// The open notch grows with what it shows; a section on its own gets a wide stage.
    static func expandedSize(for sections: [NotchSection]) -> CGSize {
        let widths: [CGFloat] = [540, 540, 720, 840, 940]
        return CGSize(width: widths[min(sections.count, 4)], height: height)
    }

    /// Sections share the open notch evenly and adapt their layout to what they get.
    static func sectionWidth(in size: CGSize, count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        return (size.width - 2 * padding - gap * (n - 1)) / n
    }
}

/// The parts the open notch can show, in a fixed order so nothing jumps around.
enum NotchSection: CaseIterable {
    case music, whatsapp, agenda, shelf, agents

    /// Only what matters right now; the agents stand in when nothing else does.
    static func relevant(for content: NotchContent) -> [NotchSection] {
        var sections: [NotchSection] = []
        if content.musicRelevant { sections.append(.music) }
        if !content.threads.isEmpty { sections.append(.whatsapp) }
        if content.upcomingSoon { sections.append(.agenda) }
        if !content.shelf.isEmpty { sections.append(.shelf) }
        if !content.activity.sessions.isEmpty || sections.isEmpty { sections.append(.agents) }
        return sections
    }
}

/// Everything the notch shows, as plain values so snapshots can feed it too.
struct NotchContent {
    var activity = ActivitySnapshot()
    var track: Track?
    var musicRelevant = false
    var artwork: NSImage?
    var accent = Color.white
    var mediaBlocked = false
    var events: [AgendaEvent] = []
    var agendaAccess = Agenda.Access.unknown
    var onlyLocalCalendars = false
    var threads: [ChatThread] = []
    /// The chat opened from the list, with its recent history.
    var chat: ChatThread?
    /// Battery percentage while the plug-in flash is showing.
    var chargingFlash: Int?

    var unread: Int { threads.reduce(0) { $0 + $1.messages.count } }
    var nextEvent: AgendaEvent? { events.first { !$0.allDay } }
    var imminentEvent: AgendaEvent? {
        guard let next = nextEvent, next.start.timeIntervalSinceNow < 10 * 60 else { return nil }
        return next
    }
    /// A timed appointment within the next twelve hours; holidays alone do not count.
    /// How far ahead an appointment earns its place in the open notch (settings).
    var agendaHours = 12.0
    /// The little live activities beside the camera (settings).
    var showEars = true
    /// Files parked in the notch.
    var shelf: [ShelfItem] = []

    var upcomingSoon: Bool { nextEvent.map { $0.start.timeIntervalSinceNow < agendaHours * 3600 } ?? false }

    /// Claude and Codex together: whoever needs Maik most sets the tone.
    var agentMood: Mood {
        let moods = [activity.mood, activity.codex ?? .sleeping]
        return [.asking, .working, .done, .idle].first { moods.contains($0) } ?? .sleeping
    }

    @MainActor
    static func live(claude: PetModel, media: MediaCenter, agenda: Agenda, whatsapp: WhatsAppFeed, power: PowerWatch) -> NotchContent {
        // What is switched off in the settings simply never reaches the notch.
        let music = Setting.on(Setting.music)
        var content = NotchContent(activity: Self.agents(claude.activity), track: music ? media.track : nil,
                                   musicRelevant: music && media.relevant,
                                   artwork: media.artwork, accent: media.accent, mediaBlocked: music && media.blocked,
                                   events: Setting.on(Setting.agenda) ? agenda.events : [], agendaAccess: agenda.access,
                                   onlyLocalCalendars: agenda.onlyLocalCalendars,
                                   threads: Setting.on(Setting.whatsapp) ? whatsapp.threads : [],
                                   chat: Setting.on(Setting.whatsapp) ? whatsapp.openChat : nil,
                                   chargingFlash: Setting.on(Setting.charging) ? power.flash : nil)
        content.agendaHours = Setting.value(Setting.agendaHours)
        content.showEars = Setting.on(Setting.ears)
        content.shelf = Setting.on(Setting.shelf) ? ShelfStore.shared.items : []
        return content
    }

    /// Claude's or Codex's sessions dropped when either is switched off.
    private static func agents(_ activity: ActivitySnapshot) -> ActivitySnapshot {
        var activity = activity
        if !Setting.on(Setting.codex) {
            activity.codex = nil
            activity.sessions.removeAll { $0.agent == .codex }
        }
        if !Setting.on(Setting.claude) {
            activity.mood = .sleeping
            activity.working = 0
            activity.asking = 0
            activity.sessions.removeAll { $0.agent == .claude }
        }
        return activity
    }
}

struct NotchActions {
    var playPause: () -> Void = {}
    var next: () -> Void = {}
    var previous: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
    var setVolume: (Int) -> Void = { _ in }
    var toggleShuffle: () -> Void = {}
    var toggleRepeat: () -> Void = {}
    var openPlayer: () -> Void = {}
    /// WhatsApp itself, right in the given chat when possible.
    var openWhatsApp: (String?) -> Void = { _ in }
    /// Opens a chat across the whole notch; `closeChat` goes back to the overview.
    var openChat: (String) -> Void = { _ in }
    var closeChat: () -> Void = {}
    var beginReply: (String) -> Void = { _ in }
    var sendReply: () -> Void = {}
    var cancelReply: () -> Void = {}
    var openMeeting: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var openCalendar: () -> Void = { NotchActions.open("com.apple.iCal") }
    var openAgent: (Agent) -> Void = { NotchActions.open($0 == .claude ? "com.anthropic.claudefordesktop" : "com.openai.chat") }
    /// Answer number `index` to the question on screen.
    var pickAnswer: (Int) -> Void = { _ in }
    /// Leave the question to Claude's own window.
    var answerInClaude: () -> Void = {}
    /// Close an appointment or "fertig" pop-up.
    var dismissBanner: () -> Void = {}
    /// Files dropped on the notch go onto the shelf.
    var dropFiles: ([NSItemProvider]) -> Void = { providers in
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in ShelfStore.shared.add([url]) }
            }
        }
    }

    static func open(_ bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Feeds the live models into the notch.
struct LiveNotch: View {
    let claude: PetModel
    let media: MediaCenter
    let agenda: Agenda
    let whatsapp: WhatsAppFeed
    let power: PowerWatch
    let state: NotchState
    let notchSize: CGSize
    let actions: NotchActions

    var body: some View {
        NotchBody(content: .live(claude: claude, media: media, agenda: agenda, whatsapp: whatsapp, power: power),
                  state: state, notchSize: notchSize, actions: actions)
    }
}

// MARK: Shape

/// The notch outline: concave shoulders where it meets the screen edge, round bottom corners.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set { shoulder = newValue.first; corner = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = shoulder, c = min(corner, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - c))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + c, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - c, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - c), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: Body

struct NotchBody: View {
    let content: NotchContent
    let state: NotchState
    let notchSize: CGSize
    var actions = NotchActions()

    private enum Mode { case compact, banner, expanded }

    private var mode: Mode {
        state.dropping ? .banner
            : state.expanded ? .expanded
            : (state.ask != nil || state.meeting != nil || state.done != nil || state.banner != nil || state.question != nil) ? .banner
            : .compact
    }
    private var sections: [NotchSection] { NotchSection.relevant(for: content) }
    private var ears: (left: Ear?, right: Ear?) { Ear.pick(for: content) }
    private var hasEars: Bool { ears.left != nil || ears.right != nil }

    private var size: CGSize {
        switch mode {
        case .expanded: content.chat != nil ? NotchLayout.chat : NotchLayout.expandedSize(for: sections)
        case .banner:
            if state.dropping { NotchLayout.dropZone }
            else if let ask = state.ask { NotchLayout.askSize(for: ask, index: state.askIndex) }
            else if state.meeting != nil { NotchLayout.meeting }
            else if state.done != nil { NotchLayout.done }
            else { state.question.map(NotchLayout.questionSize(for:)) ?? NotchLayout.banner }
        case .compact: CGSize(width: notchSize.width + (hasEars ? 2 * NotchLayout.ear : 0), height: notchSize.height)
        }
    }

    var body: some View {
        let shoulder: CGFloat = mode == .compact ? 6 : 14
        ZStack(alignment: .top) {
            NotchShape(shoulder: shoulder, corner: mode == .compact ? 10 : mode == .banner ? 26 : 30)
                .fill(.black)
                .frame(width: size.width + 2 * shoulder, height: size.height)
                // No shadow while closed: even an invisible one costs a blur pass on every ear frame.
                .shadow(color: .black.opacity(mode == .compact ? 0 : 0.5), radius: mode == .compact ? 0 : 16, y: 8)
            ZStack(alignment: .top) {
                switch mode {
                case .expanded:
                    if let chat = content.chat {
                        ChatView(thread: chat, unread: content.threads.first { $0.id == chat.id }?.messages ?? [],
                                 state: state, actions: actions, notchHeight: notchSize.height)
                            .transition(.notchContent)
                    } else {
                        ExpandedNotch(content: content, state: state, sections: sections, size: size,
                                      actions: actions, notchHeight: notchSize.height)
                            .transition(.notchContent)
                    }
                case .banner:
                    if state.dropping {
                        DropZone(notchHeight: notchSize.height)
                            .contentShape(Rectangle())
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                actions.dropFiles(providers)
                                return true
                            }
                            .transition(.notchContent)
                    } else if let ask = state.ask {
                        AskBanner(ask: ask, title: state.askTitle, index: state.askIndex, actions: actions, notchHeight: notchSize.height)
                            .id("\(ask.id)-\(state.askIndex)")
                            .transition(.notchContent)
                    } else if let meeting = state.meeting {
                        MeetingBanner(event: meeting, actions: actions, notchHeight: notchSize.height)
                            .transition(.notchContent)
                    } else if let done = state.done {
                        DoneBanner(session: done, actions: actions, notchHeight: notchSize.height)
                            .transition(.notchContent)
                    } else if let question = state.question {
                        QuestionBanner(session: question, actions: actions, notchHeight: notchSize.height)
                            .transition(.notchContent)
                    } else if let message = state.banner {
                        Banner(message: message, actions: actions, notchHeight: notchSize.height)
                            .transition(.notchContent)
                    }
                case .compact:
                    if hasEars {
                        // The frame clock holds only its drawing inputs, rather than retaining
                        // all chats, events and sessions and recomputing their priorities per tick.
                        CompactEars(ears: ears, artwork: content.artwork, accent: content.accent,
                                    claudeMood: content.activity.mood, notchWidth: notchSize.width)
                        .frame(height: notchSize.height)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: NotchGeometry.panelSize.width, height: NotchGeometry.panelSize.height, alignment: .top)
        .animation(NotchLayout.open, value: hasEars)
        .animation(mode == .compact ? NotchLayout.close : NotchLayout.open, value: mode)
        .animation(NotchLayout.open, value: sections)
        .animation(NotchLayout.open, value: content.chat?.id)
        .environment(\.colorScheme, .dark)
    }
}

private struct Blur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// The open notch's content arrives just after the shape, soft and slightly blurred, and leaves at once
    /// so the shrinking shape never cuts through it.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
                .combined(with: .modifier(active: Blur(radius: 6), identity: Blur(radius: 0)))
                .animation(NotchLayout.open.delay(0.07)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

// MARK: Compact ears

/// What one side of the closed notch shows, like a Dynamic Island live activity.
enum Ear: Equatable {
    case clawd(Mood)
    case codex(Mood)
    case artwork
    case equalizer
    case spinner
    case check
    case question
    case calendar
    case countdown(String)
    case whatsapp
    case unread(Int)
    case bolt
    case percent(Int)

    /// Stays the same while a pet only changes its mood, so it does not walk out and back in.
    var identity: String {
        switch self {
        case .clawd: "clawd"
        case .codex: "codex"
        case .countdown, .unread, .percent: String(describing: self).components(separatedBy: "(").first ?? ""
        default: String(describing: self)
        }
    }

    var isPet: Bool {
        switch self {
        case .clawd, .codex: true
        default: false
        }
    }

    /// Only the pets and the spinner move on the shared clock; the equaliser keeps its own.
    static func animates(_ ears: (left: Ear?, right: Ear?)) -> Bool {
        [ears.left, ears.right].contains { $0?.isPet == true || $0 == .spinner }
    }

    /// Left: who is active. Right: what needs you, most urgent first.
    static func pick(for content: NotchContent) -> (left: Ear?, right: Ear?) {
        // Plugging in briefly beats everything, like on the iPhone.
        if let percent = content.chargingFlash { return (.bolt, .percent(percent)) }
        guard content.showEars else { return (nil, nil) }

        let live: Set<Mood> = [.working, .asking, .done]
        let claude = content.activity.mood
        let codex = content.activity.codex ?? .sleeping
        let agents = content.agentMood
        let playing = content.track?.playing == true
        let unread = content.unread
        let soon = content.imminentEvent

        // Both at work: Clawd on the left, Codex's terminal on the right. Each pet shows its own state.
        if live.contains(claude), live.contains(codex) { return (.clawd(claude), .codex(codex)) }

        let left: Ear? = live.contains(claude) ? .clawd(claude)
            : live.contains(codex) ? .codex(codex)
            : unread > 0 ? .whatsapp : playing ? .artwork : soon != nil ? .calendar : nil
        let right: Ear?
        if agents == .asking { right = .question }
        else if unread > 0 { right = .unread(unread) }
        else if agents == .working { right = playing ? .equalizer : .spinner }
        else if agents == .done { right = playing ? .equalizer : .check }
        else if playing { right = .equalizer }
        else if let soon { right = .countdown(soon.start <= .now ? "jetzt" : "\(max(Int(soon.start.timeIntervalSinceNow / 60), 1)) Min") }
        else { right = nil }
        return (left, right)
    }
}

private struct CompactEars: View {
    let ears: (left: Ear?, right: Ear?)
    let artwork: NSImage?
    let accent: Color
    let claudeMood: Mood
    let notchWidth: CGFloat

    var body: some View {
        // Same shared clock and frame rate as before; only the captured data is smaller.
        TimelineView(.animation(minimumInterval: 1.0 / 5, paused: !Ear.animates(ears))) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                EarView(ear: ears.left, side: .leading, artwork: artwork, accent: accent,
                        claudeMood: claudeMood, time: time).frame(width: NotchLayout.ear)
                Spacer(minLength: notchWidth)
                EarView(ear: ears.right, side: .trailing, artwork: artwork, accent: accent,
                        claudeMood: claudeMood, time: time).frame(width: NotchLayout.ear)
            }
            .animation(NotchLayout.open, value: ears.left)
            .animation(NotchLayout.open, value: ears.right)
        }
    }
}

private struct EarView: View {
    let ear: Ear?
    let side: HorizontalEdge
    let artwork: NSImage?
    let accent: Color
    let claudeMood: Mood
    let time: TimeInterval

    /// Pets walk out from under the camera and back in; everything else pops.
    private var transition: AnyTransition {
        guard ear?.isPet == true else { return .opacity.combined(with: .scale(scale: 0.6)) }
        let edge: Edge = side == .leading ? .trailing : .leading
        return .move(edge: edge).combined(with: .opacity)
    }

    var body: some View {
        ZStack {
            face
                .id(ear?.identity)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private var face: some View {
        Group {
            switch ear {
            case .clawd(let mood):
                ClawdIcon(pw: 1.5, ph: 3, mood: mood, time: time).overlay(alignment: .topTrailing) { askingBadge(mood) }
            case .codex(let mood):
                CodexIcon(p: 1.75, mood: mood, time: time).overlay(alignment: .topTrailing) { askingBadge(mood) }
            case .artwork:
                ArtworkView(image: artwork, size: 20, radius: 5)
            case .equalizer:
                Equalizer(color: accent)
            case .spinner:
                // Blue while only Codex works, Claude orange otherwise.
                SpinnerGlyph(time: time, pixel: 2,
                             color: [.working, .asking, .done].contains(claudeMood) ? Palette.clawd : Palette.codex)
                    .frame(width: 10, height: 10)
            case .check:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.mint)
            case .question:
                Image(systemName: "questionmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.amber)
            case .calendar:
                Image(systemName: "calendar").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.amber)
            case .countdown(let text):
                Text(text).font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.amber).lineLimit(1).minimumScaleFactor(0.7)
            case .whatsapp:
                AppIcon(bundleID: "net.whatsapp.WhatsApp", size: 18)
            case .unread(let count):
                Text(count > 9 ? "9+" : "\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(Palette.whatsapp))
            case .bolt:
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.mint)
            case .percent(let value):
                Text("\(value) %").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.mint).lineLimit(1).fixedSize()
            case nil:
                Color.clear
            }
        }
    }

    /// A pet that waits for Maik wears a small amber question mark.
    @ViewBuilder private func askingBadge(_ mood: Mood) -> some View {
        if mood == .asking {
            Text("?").font(.system(size: 7, weight: .black, design: .rounded)).foregroundStyle(.black)
                .frame(width: 9, height: 9).background(Circle().fill(Palette.amber)).offset(x: 4, y: -4)
        }
    }
}
