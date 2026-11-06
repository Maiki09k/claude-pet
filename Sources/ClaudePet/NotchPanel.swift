import AppKit
import Observation
import SwiftUI

/// Size and place of the camera notch on the built-in display.
struct NotchGeometry {
    /// The notch in screen coordinates (origin bottom left).
    let notch: CGRect
    /// The transparent panel the notch grows inside.
    let panel: CGRect

    /// Tall enough for a question from Claude with four answers.
    static let panelSize = CGSize(width: 1000, height: 360)

    init?(screen: NSScreen) {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let height = screen.safeAreaInsets.top
        notch = CGRect(x: left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
        panel = CGRect(x: notch.midX - Self.panelSize.width / 2, y: screen.frame.maxY - Self.panelSize.height,
                       width: Self.panelSize.width, height: Self.panelSize.height)
    }

    /// For snapshots: a 14" MacBook Pro notch.
    init(snapshotNotch size: CGSize) {
        notch = CGRect(x: (Self.panelSize.width - size.width) / 2, y: Self.panelSize.height - size.height, width: size.width, height: size.height)
        panel = CGRect(origin: .zero, size: Self.panelSize)
    }
}

@MainActor @Observable
final class NotchState {
    enum SendState { case idle, sending, sent, failed }

    var expanded = false
    /// A new WhatsApp message being shown for a few seconds.
    var banner: ChatMessage?
    /// Claude or Codex asking something, shown for a few seconds when the question comes in.
    var question: SessionStatus?
    /// A session that just finished, with the first line of its answer.
    var done: SessionStatus?
    /// An appointment about to start.
    var meeting: AgendaEvent?
    /// A drag with files is over the notch.
    var dropping = false
    /// A question from Claude to answer right here, with the session's name.
    var ask: AskRequest?
    var askTitle = "Claude"
    /// Which of the request's questions is on screen, and the answers given so far.
    var askIndex = 0
    var askAnswers: [String: String] = [:]
    /// Chat shown in the open WhatsApp section.
    var selectedChat: String?
    /// Chat being answered; while set, the notch holds the keyboard and stays open.
    var replyTo: String?
    var draft = ""
    var sendState = SendState.idle
}

/// Transparent panel over the menu bar. It lets every click through until the
/// pointer rests on the notch, then the notch opens and takes clicks.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
    }

    /// Only while a reply is typed; otherwise clicks in the notch never steal the keyboard.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a panel that never becomes key must react to the very first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private let claude: PetModel
    private let media: MediaCenter
    private let agenda: Agenda
    private let whatsapp: WhatsAppFeed
    private let power = PowerWatch()
    private let state = NotchState()
    private var panel: NotchPanel?
    /// Keeps the notch put while the desktop slides on a Space change.
    private let sticky = StickySpace()
    private var geometry: NotchGeometry?
    private var hoverSince: Date?
    private var leftAt: Date?
    private var bannerUntil = Date.distantPast
    private var shownPop: Int64?
    private var questionUntil = Date.distantPast
    private var shownQuestion: String?
    /// Requests already handled here (answered, handed to Claude or timed out).
    private var doneAsks: Set<String> = []
    private var doneUntil = Date.distantPast
    /// Finished sessions already announced; nil until the first look, so old ones stay quiet.
    private var shownDone: Set<String>?
    private var meetingUntil = Date.distantPast
    private var shownMeetings: Set<String> = []
    /// The drag pasteboard's count while no button is down; a change during a press means a drag.
    private var idleDragCount = NSPasteboard(name: .drag).changeCount
    private var lastAskLook = Date.distantPast
    /// The open notch showed WhatsApp messages, so closing it counts as having read them.
    /// While set, a preview keeps the notch open regardless of the pointer.
    private var previewUntil = Date.distantPast
    /// The app that had the keyboard before a reply, to hand it back afterwards.
    private var keyboardOwner: NSRunningApplication?

    private static let closeDelay: TimeInterval = 0.3

    init(claude: PetModel, media: MediaCenter, agenda: Agenda, whatsapp: WhatsAppFeed) {
        self.claude = claude
        self.media = media
        self.agenda = agenda
        self.whatsapp = whatsapp
    }

    func start() {
        build()
        power.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.build() }
        }
        // `distnoted` preview: post io.github.maiki09k.claudepet.preview with "open", "banner" or "charging".
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.maiki09k.claudepet.preview"), object: nil,
                                                            queue: .main) { [weak self] note in
            let kind = note.object as? String
            MainActor.assumeIsolated { self?.preview(kind ?? "open") }
        }
        // Claude's hook announces a question; the timer below catches any it missed.
        DistributedNotificationCenter.default().addObserver(forName: AskBridge.posted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForAsks() }
        }
        // Polling the pointer is cheaper and needs no permission, unlike global event monitors.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
    }

    private func build() {
        if let panel { sticky.remove(panel) }
        panel?.orderOut(nil)
        panel = nil
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }),
              let geometry = NotchGeometry(screen: screen) else { return }
        self.geometry = geometry
        let panel = NotchPanel(frame: geometry.panel)
        let root = LiveNotch(claude: claude, media: media, agenda: agenda, whatsapp: whatsapp, power: power, state: state,
                             notchSize: geometry.notch.size, actions: makeActions())
        let host = FirstClickHostingView(rootView: root)
        // Files dragged onto the notch land on the shelf.
        host.registerForDraggedTypes([.fileURL])
        // The panel never resizes: skip SwiftUI's size bookkeeping on every animation frame.
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        sticky.add(panel)
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Clicking elsewhere while typing ends the reply but keeps the draft.
            MainActor.assumeIsolated { if self?.state.replyTo != nil { self?.endReply(keepDraft: true) } }
        }
        self.panel = panel
    }

    private func makeActions() -> NotchActions {
        var actions = NotchActions(playPause: media.playPause, next: media.next, previous: media.previous,
                                   seek: media.seek, setVolume: media.setVolume,
                                   toggleShuffle: media.toggleShuffle, toggleRepeat: media.toggleRepeat,
                                   openPlayer: media.openPlayer, openWhatsApp: { [weak self] jid in self?.whatsapp.openWhatsApp(jid) })
        actions.openChat = { [weak self] jid in
            guard let self else { return }
            if state.replyTo != nil, state.replyTo != jid { endReply(keepDraft: false) }
            state.selectedChat = jid
            if !state.expanded { setExpanded(true) }
            whatsapp.open(jid)
        }
        actions.closeChat = { [weak self] in
            guard let self else { return }
            if state.replyTo != nil { endReply(keepDraft: false) }
            VoicePlayer.shared.stop()
            whatsapp.close()
        }
        actions.beginReply = { [weak self] jid in self?.beginReply(jid) }
        actions.sendReply = { [weak self] in self?.sendReply() }
        actions.cancelReply = { [weak self] in self?.endReply(keepDraft: false) }
        actions.pickAnswer = { [weak self] index in self?.pickAnswer(index) }
        actions.dismissBanner = { [weak self] in
            self?.state.meeting = nil
            self?.state.done = nil
        }
        actions.answerInClaude = { [weak self] in self?.answerInClaude() }
        return actions
    }

    // MARK: Answering Claude

    private func lookForAsks() {
        lastAskLook = .now
        if let ask = state.ask, ask.deadline <= .now {
            // Time is up: the hook has let go and Claude shows the question itself.
            doneAsks.insert(ask.id)
            state.ask = nil
        }
        guard state.ask == nil, Setting.on(Setting.notch),
              let next = AskBridge.pending().first(where: { !doneAsks.contains($0.id) }) else { return }
        if state.expanded { setExpanded(false) }
        state.banner = nil
        state.question = nil
        state.ask = next
        state.askIndex = 0
        state.askAnswers = [:]
        state.askTitle = claude.activity.sessions.first { $0.id == next.session }?.title ?? "Claude"
        // The same question also shows up in the transcript; it must not pop up a second time.
        shownQuestion = "\(next.session)|\(next.questions.first?.question ?? "")"
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func pickAnswer(_ index: Int) {
        guard let ask = state.ask, state.askIndex < ask.questions.count else { return }
        let question = ask.questions[state.askIndex]
        guard index < question.options.count else { return }
        state.askAnswers[question.question] = question.options[index].label
        if state.askIndex + 1 < ask.questions.count {
            state.askIndex += 1
            return
        }
        if !ask.id.hasPrefix("preview") { AskBridge.answer(ask.id, with: state.askAnswers) }
        doneAsks.insert(ask.id)
        state.ask = nil
    }

    private func answerInClaude() {
        guard let ask = state.ask else { return }
        if !ask.id.hasPrefix("preview") { AskBridge.skip(ask.id) }
        doneAsks.insert(ask.id)
        state.ask = nil
        NotchActions.open("com.anthropic.claudefordesktop")
    }

    // MARK: Replying

    private func beginReply(_ jid: String) {
        guard let panel else { return }
        if state.replyTo != jid { state.draft = "" }
        state.selectedChat = jid
        state.replyTo = jid
        state.sendState = .idle
        if !state.expanded { setExpanded(true) }
        // Answer with the conversation in view, as in WhatsApp.
        if whatsapp.openJID != jid { whatsapp.open(jid) }
        keyboardOwner = NSWorkspace.shared.frontmostApplication
        panel.allowsKey = true
        panel.makeKey()
    }

    private func sendReply() {
        guard let jid = state.replyTo, state.sendState != .sending,
              !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.sendState = .sending
        let text = state.draft
        Task {
            let sent = await whatsapp.send(text, to: jid)
            state.sendState = sent ? .sent : .failed
            guard sent else { return }
            state.draft = ""
            try? await Task.sleep(for: .seconds(1.2))
            if state.replyTo == jid { endReply(keepDraft: false) }
        }
    }

    private func endReply(keepDraft: Bool) {
        state.replyTo = nil
        state.sendState = .idle
        if !keepDraft { state.draft = "" }
        guard let panel, panel.allowsKey else { return }
        panel.allowsKey = false
        panel.resignKey()
        // Hand the keyboard back to where Maik was typing before.
        keyboardOwner?.activate()
        keyboardOwner = nil
    }

    private func preview(_ kind: String) {
        switch kind {
        case "banner":
            state.banner = ChatMessage(id: -1, jid: "", chat: "Vorschau", group: false, text: "So erscheint eine neue WhatsApp-Nachricht.", date: .now)
            bannerUntil = .now.addingTimeInterval(Setting.value(Setting.whatsappSeconds))
        case "question":
            state.question = SessionStatus(id: "preview", agent: .codex, title: "Vorschau", mood: .asking, since: .now,
                                           question: PendingQuestion(title: "So erscheint eine Frage von Codex oder Claude.",
                                                                     options: ["Erste Antwort", "Zweite Antwort"]))
            questionUntil = .now.addingTimeInterval(Setting.value(Setting.questionSeconds))
        case "ask":
            let options = [AskRequest.Option(label: "Erste Antwort", description: "Ein Klick schickt sie direkt an Claude"),
                           AskRequest.Option(label: "Zweite Antwort", description: nil)]
            state.ask = AskRequest(id: "preview-\(UUID().uuidString)", session: "",
                                   questions: [.init(question: "So erscheint eine Frage von Claude, die du hier beantwortest.", options: options)],
                                   deadline: .now.addingTimeInterval(Setting.value(Setting.askSeconds)))
            state.askTitle = "Vorschau"
            state.askIndex = 0
            state.askAnswers = [:]
        case let pick where pick.hasPrefix("ask-pick:"):
            // Same as clicking that answer, for checks without a mouse.
            if let number = Int(pick.dropFirst(9)) { pickAnswer(number - 1) }
        case "ask-skip":
            answerInClaude()
        case let file where file.hasPrefix("voice-check:"):
            let message = ChatMessage(id: -2, jid: "check", chat: "Prüfung", group: false, text: "", date: .now, messageID: "check", media: "audio")
            WhatsAppMedia.shared.voices[message.mediaKey] = (String(file.dropFirst(12)), 0)
            VoicePlayer.shared.checkMuted(message)
        case "voice-check":
            // Plays the newest voice message muted for a moment and notes whether time moved; nothing is heard.
            if let message = whatsapp.unseen.first(where: { $0.media == "audio" }) {
                VoicePlayer.shared.checkMuted(message)
            } else {
                UserDefaults.standard.set("keine Sprachnachricht da", forKey: "voice.check")
            }
        case "calendar-check":
            UserDefaults.standard.set(agenda.diagnose(), forKey: "calendar.check")
        case "dismiss":
            state.meeting = nil
            state.done = nil
        case "done":
            state.done = SessionStatus(id: "preview", agent: .claude, title: "Vorschau", mood: .done, since: .now,
                                       summary: "So meldet sich Claude, wenn eine Session fertig ist: mit der ersten Zeile der Antwort.")
            doneUntil = .now.addingTimeInterval(Setting.value(Setting.doneSeconds))
        case "meeting":
            state.meeting = AgendaEvent(id: "preview", title: "Vorschau: Abstimmung", start: .now.addingTimeInterval(120),
                                        end: .now.addingTimeInterval(1920), allDay: false, color: Palette.join,
                                        meetingURL: URL(string: "https://meet.google.com/"))
            meetingUntil = .now.addingTimeInterval(20)
        case let file where file.hasPrefix("shelf:"):
            // Same as dropping that file on the notch, for checks without a mouse.
            ShelfStore.shared.add([URL(filePath: String(file.dropFirst(6)))])
        case "charging":
            power.showFlash()
        case "open":
            previewUntil = .now.addingTimeInterval(6)
            setExpanded(true)
        case "chat":
            // A made-up chat opened across the notch; real chats stay untouched.
            previewUntil = .now.addingTimeInterval(6)
            setExpanded(true)
            let line = { (id: Int64, text: String, ago: Double, me: Bool) in
                ChatMessage(id: id, jid: "preview-chat", chat: "Vorschau", group: false, text: text, date: .now.addingTimeInterval(-ago),
                            caption: text, fromMe: me)
            }
            whatsapp.showSample(ChatThread(id: "preview-chat", name: "Vorschau", group: false, messages: [
                line(-14, "So sieht ein geöffneter Chat aus. Die neuesten Nachrichten stehen unten, ältere erreichst du per Scrollen.", 30, false),
                line(-13, "Und meine eigenen rechts?", 90, true),
                line(-12, "Genau, in Grün wie in WhatsApp.", 120, false),
                line(-11, "Wie öffne ich so einen Chat?", 600, true),
                line(-10, "Einfach in der Notch auf den Chat klicken.", 660, false),
            ]))
        default:
            // Previews meant for the cards or the settings window.
            break
        }
    }

    private func track() {
        guard let geometry, let panel else { return }
        // Switched off in the settings: no notch window at all, the camera cut-out stays plain.
        let enabled = Setting.on(Setting.notch)
        if enabled != panel.isVisible {
            if enabled { panel.orderFrontRegardless() } else { setExpanded(false); panel.orderOut(nil) }
        }
        guard enabled else { return }
        let now = Date.now
        let notch = geometry.notch
        if now.timeIntervalSince(lastAskLook) > 1 || (state.ask.map { $0.deadline <= now } ?? false) { lookForAsks() }

        // Files being dragged near the notch: it opens into a drop target. A drag shows as a change of
        // the drag pasteboard while the button is held; no event monitor or permission is needed.
        let pressed = NSEvent.pressedMouseButtons & 1 == 1
        let dragBoard = NSPasteboard(name: .drag)
        if !pressed { idleDragCount = dragBoard.changeCount }
        let carriesFiles = pressed && dragBoard.changeCount != idleDragCount && Setting.on(Setting.shelf)
            && (dragBoard.types?.contains(.fileURL) ?? false)
        let target = CGRect(x: notch.midX - 300, y: notch.maxY - 200, width: 600, height: 200)
        let dropping = carriesFiles && target.contains(NSEvent.mouseLocation)
        if dropping != state.dropping {
            if dropping, state.expanded { setExpanded(false) }
            state.dropping = dropping
        }

        // A new direct message drops the notch down for five seconds.
        if let pop = whatsapp.pop, pop.id != shownPop {
            shownPop = pop.id
            if !state.expanded, state.ask == nil, Setting.on(Setting.whatsapp), Setting.on(Setting.whatsappBanner) {
                state.banner = pop
                bannerUntil = now.addingTimeInterval(Setting.value(Setting.whatsappSeconds))
            }
        }

        // A new question drops it down for a few seconds; an answered one leaves at once.
        let asking = claude.activity.sessions.first {
            $0.question != nil && Setting.on($0.agent == .codex ? Setting.codex : Setting.claude)
        }
        let askKey = asking.map { "\($0.id)|\($0.question?.title ?? "")" }
        if askKey != shownQuestion {
            shownQuestion = askKey
            if let asking, !state.expanded, state.ask == nil, Setting.on(Setting.questionBanner) {
                state.question = asking
                questionUntil = now.addingTimeInterval(Setting.value(Setting.questionSeconds))
            }
        }
        if let shown = state.question, shown.id != "preview", asking?.id != shown.id { state.question = nil }

        // Finished: one short pop-up per session and turn, unless Maik is looking at that app anyway.
        let finished = claude.activity.sessions.filter {
            $0.mood == .done && Setting.on($0.agent == .codex ? Setting.codex : Setting.claude)
        }
        func doneKey(_ session: SessionStatus) -> String { "\(session.id)|\(Int(session.since.timeIntervalSince1970))" }
        if shownDone == nil { shownDone = Set(finished.map(doneKey)) }
        if let fresh = finished.first(where: { !(shownDone?.contains(doneKey($0)) ?? true) }) {
            shownDone?.insert(doneKey(fresh))
            let appInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == (fresh.agent == .claude ? "com.anthropic.claudefordesktop" : "com.openai.chat")
            if Setting.on(Setting.doneBanner), !state.expanded, !appInFront,
               state.ask == nil, state.question == nil, state.meeting == nil {
                state.banner = nil
                state.done = fresh
                doneUntil = now.addingTimeInterval(Setting.value(Setting.doneSeconds))
            }
        }

        // An appointment about to start drops the notch down with its join button.
        let lead = Setting.value(Setting.meetingLead) * 60
        if Setting.on(Setting.meetingAlert), Setting.on(Setting.agenda),
           let soon = agenda.events.first(where: { !$0.allDay && $0.start.timeIntervalSince(now) <= lead && $0.start.timeIntervalSince(now) > -60 }),
           shownMeetings.insert("\(soon.id)|\(soon.start)").inserted, state.ask == nil {
            if state.expanded { setExpanded(false) }
            state.banner = nil
            state.done = nil
            state.question = nil
            state.meeting = soon
            meetingUntil = soon.start.addingTimeInterval(90)
        }
        if state.meeting != nil, now > meetingUntil { state.meeting = nil }

        let size: CGSize
        if state.dropping {
            size = NotchLayout.dropZone
        } else if state.expanded {
            let content = NotchContent.live(claude: claude, media: media, agenda: agenda, whatsapp: whatsapp, power: power)
            size = content.chat != nil ? NotchLayout.chat : NotchLayout.expandedSize(for: NotchSection.relevant(for: content))
        } else if let ask = state.ask {
            size = NotchLayout.askSize(for: ask, index: state.askIndex)
        } else if state.meeting != nil {
            size = NotchLayout.meeting
        } else if state.done != nil {
            size = NotchLayout.done
        } else if let question = state.question {
            size = NotchLayout.questionSize(for: question)
        } else if state.banner != nil {
            size = NotchLayout.banner
        } else {
            // The notch plus its ears, reaching a little below it.
            size = CGSize(width: notch.width + 2 * NotchLayout.ear, height: notch.height + 4)
        }
        let margin: CGFloat = state.expanded ? 12 : 0
        let zone = CGRect(x: notch.midX - size.width / 2 - margin, y: notch.maxY - size.height - margin,
                          width: size.width + 2 * margin, height: size.height + margin + 2)
        let inside = zone.contains(NSEvent.mouseLocation)

        if inside {
            leftAt = nil
            // A question, an appointment or a "fertig" stays put while the pointer is on it,
            // so its buttons can be clicked; hovering must not swap it for the open notch.
            if !state.expanded, !state.dropping, state.ask == nil, state.meeting == nil, state.done == nil {
                hoverSince = hoverSince ?? now
                // Pointer has to rest a moment before the notch opens, so passing by does nothing.
                if now.timeIntervalSince(hoverSince!) > Setting.value(Setting.openDelay) { setExpanded(true) }
            }
        } else {
            hoverSince = nil
            // Typing a reply keeps it open; so does a preview.
            if state.expanded, now > previewUntil, state.replyTo == nil {
                leftAt = leftAt ?? now
                if now.timeIntervalSince(leftAt!) > Self.closeDelay { setExpanded(false) }
            } else {
                // A voice message started from the banner keeps it open until it ends.
                if state.banner != nil, VoicePlayer.shared.playing { bannerUntil = now.addingTimeInterval(1) }
                if state.banner != nil, now > bannerUntil {
                    state.banner = nil
                    VoicePlayer.shared.stop()
                }
                if state.question != nil, now > questionUntil { state.question = nil }
                if state.done != nil, now > doneUntil { state.done = nil }
            }
        }
        // Clicks reach the notch only while it shows something clickable. Each change is a call to
        // the window server, so only set it when it actually changes.
        let ignores = !(state.expanded || state.dropping || state.banner != nil || state.question != nil || state.ask != nil
                        || state.done != nil || state.meeting != nil)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        state.banner = nil
        state.question = nil
        state.done = nil
        if expanded {
            // A light tick on the trackpad, felt only when a finger rests on it.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            media.refresh()
        } else {
            endReply(keepDraft: false)
            // Nothing keeps playing once its controls are gone.
            VoicePlayer.shared.stop()
            // Only a chat that was opened counts as read; the others stay until read here or on the phone.
            whatsapp.close()
        }
    }
}
