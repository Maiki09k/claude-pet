import AppKit
import SwiftUI

/// What the settings window asks the app to do.
struct SettingsActions {
    /// Lifts the desktop cards above all windows for a few seconds.
    var showCards: () -> Void = {}
    var resetPosition: () -> Void = {}
    /// One of the notch previews: "open", "banner", "question", "charging".
    var preview: (String) -> Void = { _ in }
    /// Where the cards sit, for the preview over the real wallpaper.
    var desktopArea: () -> (rect: NSRect, screen: NSRect, url: URL)? = { nil }
}

/// The small settings app. While its window is open Claude Pet has a Dock icon and a menu bar
/// like any app; once it closes, Claude Pet is a quiet background app again.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let model: PetModel
    private let agenda: Agenda
    private let actions: SettingsActions
    private var window: NSWindow?
    /// During a demo recording the window floats above the stage.
    var stageLevel: NSWindow.Level? {
        didSet { window?.level = stageLevel ?? .normal }
    }

    init(model: PetModel, agenda: Agenda, actions: SettingsActions) {
        self.model = model
        self.agenda = agenda
        self.actions = actions
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, agenda: agenda, actions: actions,
                                                                  setTitle: { [weak self] in self?.window?.title = $0 }))
            let window = NSWindow(contentViewController: host)
            // The view names its page once the window exists; until then, the page it opens on.
            window.title = (UserDefaults.standard.string(forKey: "settings.pane").flatMap(SettingsPane.init(rawValue:)) ?? .general).title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 780, height: 580))
            if !window.setFrameUsingName("ClaudePetSettings") { window.center() }
            window.setFrameAutosaveName("ClaudePetSettings")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.level = stageLevel ?? .normal
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Let the whole window go: a hidden SwiftUI window can keep its animations ticking.
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentViewController = nil
            self?.window = nil
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, desktop, notch, popups, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Allgemein"
        case .desktop: "Schreibtisch"
        case .notch: "Notch"
        case .popups: "Hinweise"
        case .calendar: "Kalender"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .desktop: "rectangle.on.rectangle"
        case .notch: "capsule.fill"
        case .popups: "bell.badge.fill"
        case .calendar: "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(hex: 0x8E8E93)
        case .desktop: Palette.clawd
        case .notch: Color(hex: 0x1C1C1E)
        case .popups: Color(hex: 0xE5534B)
        case .calendar: Palette.join
        }
    }
}

struct SettingsView: View {
    let model: PetModel
    let agenda: Agenda
    let actions: SettingsActions
    /// The window title names the page, like System Settings.
    var setTitle: (String) -> Void = { _ in }
    /// Opens where Maik left off.
    @AppStorage("settings.pane") private var pane = SettingsPane.general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(get: { pane }, set: { pane = $0 ?? pane })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    PaneIcon(pane: pane)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane(model: model, actions: actions)
                case .desktop: DesktopPane(model: model, agenda: agenda, actions: actions)
                case .notch: NotchPane(actions: actions)
                case .popups: PopupsPane(actions: actions)
                case .calendar: CalendarPane(agenda: agenda)
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: pane, initial: true) { setTitle(pane.title) }
        .frame(minWidth: 720, minHeight: 520)
    }
}

/// White symbol on a coloured tile, like the sidebar of System Settings.
private struct PaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pane.tint.gradient))
    }
}

/// A slider binding that snaps to `step` without the tick marks a stepped slider draws.
private func rounded(_ value: Binding<Double>, to step: Double) -> Binding<Double> {
    Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
}

// MARK: Panes

private struct GeneralPane: View {
    let model: PetModel
    let actions: SettingsActions

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                        ClawdIcon(pw: 3.5, ph: 7, mood: model.activity.mood, time: context.date.timeIntervalSinceReferenceDate)
                    }
                    .frame(width: 64, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claude Pet").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Version \(version) · Clawd, Karten und Dynamic Notch")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            } footer: {
                Text("Erneut öffnen (Finder, Spotlight) zeigt dieses Fenster. Geschlossen läuft Claude Pet unsichtbar weiter.")
            }
            Section("Gerade") {
                LabeledContent("Claude", value: mood)
                ForEach(bars) { bar in
                    LabeledContent(bar.label, value: "\(Int(bar.percent.rounded())) %")
                }
                if bars.isEmpty { LabeledContent("Limits", value: usageNote) }
                Button("Limits jetzt abrufen") { Task { await model.refreshUsage(minimumAge: 0) } }
            }
            Section {
                Button("Claude Pet beenden", role: .destructive) { NSApp.terminate(nil) }
            }
        }
    }

    private var mood: String {
        switch model.activity.mood {
        case .working: "arbeitet"
        case .asking: "wartet auf dich"
        case .done: "fertig"
        case .idle: "bereit"
        case .sleeping: "schläft"
        }
    }

    private var bars: [UsageBar] {
        if case .ready(let bars, _) = model.usage { return bars }
        return []
    }

    private var usageNote: String {
        switch model.usage {
        case .loading: "werden geladen"
        case .needsLogin: "Claude Code anmelden"
        case .failed(let reason): reason
        case .ready: ""
        }
    }
}

private struct DesktopPane: View {
    let model: PetModel
    let agenda: Agenda
    let actions: SettingsActions

    @AppStorage(Setting.claudeCard) private var claudeCard = true
    @AppStorage(Setting.agendaCard) private var agendaCard = true
    @AppStorage(Setting.critter) private var critter = true
    @AppStorage(Setting.glassStyle) private var glass = GlassStyle.clear
    @AppStorage(Setting.cardText) private var text = CardText.automatic

    var body: some View {
        Form {
            Section {
                DesktopPreview(model: model, agenda: agenda, area: actions.desktopArea)
                    .listRowInsets(EdgeInsets())
            }
            Section("Karten") {
                Toggle("Claude: Status und Limits", isOn: $claudeCard)
                Toggle("Termine von heute und morgen", isOn: $agendaCard)
                Toggle("Clawd läuft auf der Karte", isOn: $critter)
                    .disabled(!claudeCard && !agendaCard)
            }
            Section {
                Picker("Glas", selection: $glass) {
                    ForEach(GlassStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Schrift", selection: $text) {
                    ForEach(CardText.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Aussehen")
            } footer: {
                Text("„Automatisch“ misst dein Hintergrundbild: auf hellen Bildern dunkle Schrift, auf dunklen helle.")
            }
            Section {
                HStack {
                    Button("Karten nach vorn holen", action: actions.showCards)
                    Button("Position zurücksetzen", action: actions.resetPosition)
                }
            } footer: {
                Text("Die Karten liegen hinter allen Fenstern und lassen sich mit der Maus verschieben.")
            }
        }
    }
}

/// The cards as they look on the desktop: the real cards over the piece of wallpaper they sit on.
private struct DesktopPreview: View {
    let model: PetModel
    let agenda: Agenda
    let area: () -> (rect: NSRect, screen: NSRect, url: URL)?

    @AppStorage(Setting.claudeCard) private var claudeCard = true
    @AppStorage(Setting.agendaCard) private var agendaCard = true
    @AppStorage(Setting.critter) private var critter = true
    @State private var backdrop: NSImage?

    var body: some View {
        ZStack {
            if let backdrop {
                Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(hex: 0x3B5378), Color(hex: 0x6E5A80)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: WidgetMetrics.gap) {
                if critter && (claudeCard || agendaCard) {
                    // Clawd as he stands on the upper card.
                    ClawdIcon(pw: CritterPainter.pw, ph: CritterPainter.ph, mood: model.activity.mood, time: 0)
                        .frame(maxWidth: WidgetMetrics.card.width, alignment: .leading)
                        .padding(.leading, 70)
                        .padding(.bottom, -WidgetMetrics.gap)
                }
                if claudeCard { WidgetCard(activity: model.activity, usage: model.usage) }
                if agendaCard { AgendaCard(events: agenda.events, access: agenda.access, onlyLocalCalendars: agenda.onlyLocalCalendars) }
                if !claudeCard && !agendaCard {
                    Text("Keine Karte eingeschaltet")
                        .font(.callout.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
            }
            .scaleEffect(0.74)
        }
        .frame(height: 270)
        .frame(maxWidth: .infinity)
        .clipped()
        .task { await load() }
    }

    private func load() async {
        guard let area = area() else { return }
        let image = await Task.detached(priority: .utility) {
            Wallpaper.crop(behind: area.rect, in: area.screen, from: area.url)
        }.value
        if let image { backdrop = NSImage(cgImage: image, size: area.rect.size) }
    }
}

private struct NotchPane: View {
    let actions: SettingsActions

    @AppStorage(Setting.notch) private var notch = true
    @AppStorage(Setting.music) private var music = true
    @AppStorage(Setting.whatsapp) private var whatsapp = true
    @AppStorage(Setting.agenda) private var agenda = true
    @AppStorage(Setting.claude) private var claude = true
    @AppStorage(Setting.codex) private var codex = true
    @AppStorage(Setting.shelf) private var shelf = true
    @AppStorage(Setting.ears) private var ears = true
    @AppStorage(Setting.charging) private var charging = true
    @AppStorage(Setting.openDelay) private var openDelay = 0.15
    @AppStorage(Setting.agendaHours) private var agendaHours = 12.0
    @AppStorage(Setting.whatsappHours) private var whatsappHours = 12.0

    var body: some View {
        Form {
            Section {
                Toggle("Dynamic Notch", isOn: $notch)
            } footer: {
                Text("Zeigt um die Kamera herum nur, was gerade wichtig ist, und öffnet sich, wenn die Maus darauf ruht.")
            }
            Section("Was die Notch zeigen darf") {
                row("Musik aus Spotify und Musik", symbol: "music.note", tint: Palette.mint, isOn: $music)
                row("WhatsApp-Nachrichten", symbol: "message.fill", tint: Palette.whatsapp, isOn: $whatsapp)
                row("Termine", symbol: "calendar", tint: Palette.join, isOn: $agenda)
                row("Claude", symbol: "sparkle", tint: Palette.clawd, isOn: $claude)
                row("Codex", symbol: "terminal.fill", tint: Palette.codex, isOn: $codex)
                row("Ablage für Dateien", symbol: "tray.full.fill", tint: Color(hex: 0x8E8E93), isOn: $shelf)
            }
            .disabled(!notch)
            Section("Verhalten") {
                Toggle("Live-Anzeigen neben der Kamera", isOn: $ears)
                Toggle("Blitz beim Einstecken", isOn: $charging)
                LabeledContent("Öffnen nach") {
                    HStack {
                        Slider(value: rounded($openDelay, to: 0.05), in: 0.05...0.8).frame(width: 180)
                        Text(seconds(openDelay)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Termine erscheinen") {
                    Stepper(value: $agendaHours, in: 1...24, step: 1) {
                        Text("\(Int(agendaHours)) Std. vorher").monospacedDigit()
                    }
                }
                LabeledContent("Ungelesene WhatsApp-Chats") {
                    Stepper(value: $whatsappHours, in: 1...48, step: 1) {
                        Text("bis \(Int(whatsappHours)) Std. alt").monospacedDigit()
                    }
                }
            }
            .disabled(!notch)
            Section {
                HStack {
                    Button("Notch öffnen") { actions.preview("open") }
                    Button("Chat zeigen") { actions.preview("chat") }
                    Button("Blitz zeigen") { actions.preview("charging") }
                }
            }
            .disabled(!notch)
        }
    }

    /// "0,15 s"
    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE"))) + " s"
    }

    private func row(_ title: String, symbol: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
            }
        }
    }
}

private struct PopupsPane: View {
    let actions: SettingsActions

    @AppStorage(Setting.notch) private var notch = true
    @AppStorage(Setting.whatsappBanner) private var whatsapp = true
    @AppStorage(Setting.groupBanner) private var groups = false
    @AppStorage(Setting.whatsappSeconds) private var whatsappSeconds = 5.0
    @AppStorage(Setting.questionBanner) private var questions = true
    @AppStorage(Setting.questionSeconds) private var questionSeconds = 8.0
    @AppStorage(Setting.doneBanner) private var done = true
    @AppStorage(Setting.doneSeconds) private var doneSeconds = 6.0
    @AppStorage(Setting.meetingAlert) private var meeting = true
    @AppStorage(Setting.meetingLead) private var meetingLead = 2.0
    @AppStorage(Setting.askInNotch) private var askInNotch = true
    @AppStorage(Setting.askSeconds) private var askSeconds = 30.0

    var body: some View {
        Form {
            Section {
                Toggle("Neue Nachricht klappt die Notch auf", isOn: $whatsapp)
                Toggle("Auch Nachrichten aus Gruppen", isOn: $groups).disabled(!whatsapp)
                duration($whatsappSeconds, range: 3...15).disabled(!whatsapp)
                Button("Beispiel zeigen") { actions.preview("banner") }
            } header: {
                Text("WhatsApp")
            } footer: {
                Text("Ein Klick auf die Nachricht öffnet den ganzen Chat in der Notch, dort antwortest du auch. Gruppen zählen sonst nur still mit. Als gelesen gilt ein Chat, wenn du ihn hier geöffnet, beantwortet oder am Handy gelesen hast.")
            }
            Section {
                Toggle("Kurz aufklappen, wenn Claude oder Codex fertig ist", isOn: $done)
                duration($doneSeconds, range: 3...15).disabled(!done)
                Button("Beispiel zeigen") { actions.preview("done") }
            } header: {
                Text("Fertig-Meldung")
            } footer: {
                Text("Zeigt die erste Zeile der Antwort und öffnet die Session mit einem Klick. Bleibt still, wenn die App ohnehin vorne ist.")
            }
            Section {
                Toggle("Vor Terminen aufklappen", isOn: $meeting)
                LabeledContent("Vorlauf") {
                    Stepper(value: $meetingLead, in: 1...10, step: 1) {
                        Text("\(Int(meetingLead)) Min. vorher").monospacedDigit()
                    }
                }
                .disabled(!meeting)
                Button("Beispiel zeigen") { actions.preview("meeting") }
            } header: {
                Text("Termin-Alarm")
            } footer: {
                Text("Mit Videolink gibt es einen großen „Beitreten“-Knopf, sonst den Weg in den Kalender.")
            }
            Section {
                Toggle("Claudes Fragen per Klick in der Notch beantworten", isOn: $askInNotch)
                LabeledContent("Danach in Claude zeigen") {
                    HStack {
                        Slider(value: rounded($askSeconds, to: 5), in: 10...120).frame(width: 180)
                        Text("\(Int(askSeconds)) s").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!askInNotch)
                Button("Beispiel zeigen") { actions.preview("ask") }
            } header: {
                Text("Antworten aus der Notch")
            } footer: {
                Text("Fragt Claude Code etwas, erscheint die Frage zuerst hier, und ein Klick auf 1, 2, 3 oder 4 antwortet. Ohne Klick zeigt Claude sie nach Ablauf der Zeit selbst; „In Claude antworten“ sofort. Fragen mit Mehrfachauswahl und Codex-Fragen erscheinen nur in der App.")
            }
            Section {
                Toggle("Frage klappt die Notch auf", isOn: $questions)
                duration($questionSeconds, range: 4...20).disabled(!questions)
                Button("Beispiel zeigen") { actions.preview("question") }
            } header: {
                Text("Fragen nur anzeigen")
            } footer: {
                Text("Für Codex und alles, was nicht hier beantwortet wird: Die Frage bleibt in der offenen Notch stehen, bis du sie in der App beantwortest.")
            }
        }
        .disabled(!notch)
    }

    private func duration(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent("Anzeigedauer") {
            HStack {
                Slider(value: rounded(value, to: 1), in: range).frame(width: 180)
                Text("\(Int(value.wrappedValue)) s").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct CalendarPane: View {
    let agenda: Agenda
    @State private var hidden = Set(UserDefaults.standard.stringArray(forKey: Setting.hiddenCalendars) ?? [])

    private var accounts: [String] {
        var seen: [String] = []
        for calendar in agenda.calendars where !seen.contains(calendar.account) { seen.append(calendar.account) }
        return seen
    }

    /// EventKit names some accounts in English.
    private func name(_ account: String) -> String {
        switch account {
        case "Other": "Weitere"
        case "Subscribed Calendars": "Abonnierte Kalender"
        case "On My Mac": "Auf meinem Mac"
        default: account
        }
    }

    var body: some View {
        Form {
            switch agenda.access {
            case .granted:
                if agenda.calendars.isEmpty {
                    Section { Text("Keine Kalender gefunden.").foregroundStyle(.secondary) }
                }
                ForEach(accounts, id: \.self) { account in
                    Section(name(account)) {
                        ForEach(agenda.calendars.filter { $0.account == account }) { calendar in
                            Toggle(isOn: binding(for: calendar.id)) {
                                HStack(spacing: 8) {
                                    Circle().fill(calendar.color).frame(width: 10, height: 10)
                                    Text(calendar.title)
                                }
                            }
                        }
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Ausgeschaltete Kalender erscheinen weder auf der Karte noch in der Notch.")
                }
            case .denied:
                Section {
                    Text("Claude Pet darf deinen Kalender nicht lesen.")
                    Button("Systemeinstellungen öffnen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            case .unknown:
                Section { Text("Kalender wird geladen …").foregroundStyle(.secondary) }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { !hidden.contains(id) }, set: { shown in
            if shown { hidden.remove(id) } else { hidden.insert(id) }
            agenda.setCalendar(id, shown: shown)
        })
    }
}
