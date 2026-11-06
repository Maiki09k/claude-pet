import AppKit
import SwiftUI

enum WidgetMetrics {
    static let card = CGSize(width: 372, height: 156)
    /// Room above the card where Clawd walks along the top edge.
    static let band: CGFloat = 50
    /// Room around the card for its shadow.
    static let margin: CGFloat = 18
    static let corner: CGFloat = 26
    /// The agenda card sits below the Claude card.
    static let agenda = CGSize(width: 372, height: 156)
    static let gap: CGFloat = 12
    static var size: CGSize { CGSize(width: card.width + 2 * margin, height: band + card.height + gap + agenda.height + margin) }
}

/// The live widget: the card fed by the model, with the critter walking on its top edge.
struct WidgetView: View {
    let model: PetModel
    let agenda: Agenda
    var openSettings: () -> Void = {}

    @AppStorage(Setting.claudeCard) private var showClaude = true
    @AppStorage(Setting.agendaCard) private var showAgenda = true
    @AppStorage(Setting.critter) private var showCritter = true

    private var frameInterval: Double {
        switch model.activity.mood {
        case .sleeping: 1.0 / 6
        case .idle: 1.0 / 12
        default: 1.0 / 15
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Whatever is shown starts at the top, so Clawd always walks on the upper card.
            VStack(alignment: .leading, spacing: WidgetMetrics.gap) {
                if showClaude {
                    WidgetCard(activity: model.activity, usage: model.usage)
                        .gesture(WindowDragGesture())
                        .contextMenu { menu }
                }
                if showAgenda {
                    AgendaCard(events: agenda.events, access: agenda.access, onlyLocalCalendars: agenda.onlyLocalCalendars)
                        .gesture(WindowDragGesture())
                        .contextMenu { menu }
                }
            }
            .padding(.leading, WidgetMetrics.margin)
            .padding(.top, WidgetMetrics.band)

            if showCritter && (showClaude || showAgenda) { critter }
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.size.height, alignment: .topLeading)
        .environment(\.onDesktop, true)
    }

    @ViewBuilder private var menu: some View {
        Button("Einstellungen …", action: openSettings)
        Button("Limits jetzt abrufen") {
            Task { await model.refreshUsage(minimumAge: 0) }
        }
        Divider()
        Button("Claude Pet beenden") { NSApp.terminate(nil) }
    }

    private var critter: some View {
        // Sprite frame rates keep the widget near zero CPU; covered, it stops entirely.
        TimelineView(.animation(minimumInterval: frameInterval, paused: !model.visible)) { context in
            let time = context.date.timeIntervalSince(model.startedAt)
            let pose = model.critter.step(at: time, mood: model.activity.mood, track: CritterPainter.track)
            let origin = CritterPainter.origin(for: pose)
            ZStack(alignment: .topLeading) {
                CritterView(pose: pose, mood: model.activity.mood, time: time,
                            pokeAge: context.date.timeIntervalSince(model.pokedAt),
                            sweating: (model.sessionPercent ?? 0) >= 85)
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: CGFloat(CritterPainter.columns) * CritterPainter.pw + 12, height: 5 * CritterPainter.ph + 16)
                    .contentShape(Rectangle())
                    .onTapGesture { model.poke() }
                    .offset(x: origin.x - 6, y: origin.y - 14)
            }
        }
        .frame(width: WidgetMetrics.size.width, height: WidgetMetrics.band + 12)
    }
}

struct WidgetCard: View {
    let activity: ActivitySnapshot
    let usage: UsageState
    var glass = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(subline)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusPill(mood: activity.mood)
            }
            Spacer(minLength: 10)
            TimelineView(.everyMinute) { _ in UsageSection(usage: usage) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: WidgetMetrics.card.width, height: WidgetMetrics.card.height, alignment: .topLeading)
        .cardChrome(glass: glass)
    }

    private var subline: String {
        switch activity.mood {
        case .asking:
            return activity.asking > 1 ? "\(activity.asking) Sessions brauchen dich" : "braucht deine Antwort"
        case .working:
            let doing = Self.phrase(for: activity.tool)
            return activity.working > 1 ? "\(activity.working) Sessions · \(doing)" : doing
        case .done:
            return "gerade fertig geworden"
        case .idle, .sleeping:
            guard let last = activity.lastActivity else { return "heute noch nichts los" }
            return (activity.mood == .idle ? "ruhig seit " : "schläft seit ") + Self.duration(since: last)
        }
    }

    static func phrase(for tool: String?) -> String {
        switch tool {
        case nil: return "denkt nach …"
        case "Bash": return "Terminal läuft"
        case "Read", "Grep", "Glob": return "liest Code"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "schreibt Code"
        case "WebFetch", "WebSearch": return "recherchiert"
        case "Agent", "Task", "Workflow": return "Helfer arbeiten"
        case let name? where name.hasPrefix("mcp__"): return "nutzt Werkzeuge"
        default: return "ist beschäftigt"
        }
    }

    static func duration(since date: Date) -> String {
        let minutes = max(1, Int(Date.now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) Min." }
        if minutes < 24 * 60 { return "\(minutes / 60) Std." }
        let days = minutes / (24 * 60)
        return days == 1 ? "gestern" : "\(days) Tagen"
    }
}

private struct StatusPill: View {
    let mood: Mood

    private var look: (String, Color) {
        switch mood {
        case .asking: ("wartet auf dich", Color(hex: 0xE2A321))
        case .working: ("arbeitet", Palette.clawd)
        case .done: ("fertig", Color(hex: 0x2FB57A))
        case .idle: ("bereit", Color.secondary)
        case .sleeping: ("schläft", Color(hex: 0x6F7CE0))
        }
    }

    var body: some View {
        let (label, color) = look
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
        .fixedSize()
    }
}

private struct UsageSection: View {
    let usage: UsageState

    var body: some View {
        switch usage {
        case .loading:
            note("Limits werden geladen …")
        case .failed(let reason):
            note("Limits gerade nicht abrufbar (\(reason))")
        case .needsLogin:
            VStack(alignment: .leading, spacing: 6) {
                note("Für die Limits einmal im Terminal anmelden:")
                Text("claude auth login")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
            }
        case .ready(let bars, _):
            HStack(alignment: .top, spacing: 16) {
                ForEach(shown(bars)) { UsageGauge(bar: $0).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    /// Session and week always; a model-specific week only once it has been used.
    private func shown(_ bars: [UsageBar]) -> [UsageBar] {
        let main = bars.filter { $0.id == "five_hour" || $0.id == "seven_day" }
        let extra = bars.first { $0.id != "five_hour" && $0.id != "seven_day" && $0.percent > 0 }
        return main + (extra.map { [$0] } ?? [])
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One limit as an instrument: label, big number, bar, time to reset.
private struct UsageGauge: View {
    let bar: UsageBar

    private var tint: Color {
        bar.percent >= 90 ? Color(hex: 0xE5534B) : bar.percent >= 70 ? Color(hex: 0xE8A33A) : Palette.clawd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(bar.label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(bar.percent.rounded()))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(bar.percent >= 90 ? Color(hex: 0xE5534B) : .primary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(5, geo.size.width * min(bar.percent, 100) / 100))
                }
            }
            .frame(height: 5)
            .padding(.top, 3)
            Text(resetText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 6)
        }
    }

    private var resetText: String {
        guard let reset = bar.resetsAt else { return " " }
        let seconds = reset.timeIntervalSinceNow
        if seconds <= 60 { return "Reset gleich" }
        if seconds < 3600 { return "Reset in \(Int(seconds / 60)) min" }
        if seconds < 24 * 3600 {
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return "Reset in \(hours) h \(minutes) min"
        }
        return "Reset " + Self.weekday.string(from: reset)
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EE HH:mm"
        return formatter
    }()
}

extension View {
    /// Apple's own Liquid Glass on macOS 26, nothing painted on top; the old frosted glass before that and in snapshots.
    func cardChrome(glass: Bool) -> some View {
        modifier(CardChrome(glass: glass))
    }
}

/// The three looks Apple's glass offers. Switch live with the preview "glass:clear", "glass:tinted" or "glass:frosted".
enum GlassStyle: String, CaseIterable, Identifiable {
    /// Most transparent, strongest lensing of what lies behind.
    case clear
    /// The standard frosted glass of macOS widgets.
    case frosted
    /// Apple's own tint in Claude orange.
    case tinted

    var id: String { rawValue }

    /// How soft the wallpaper under the card looks, matching Apple's material of the same name.
    var backdropBlur: CGFloat {
        switch self {
        case .clear: 18
        case .frosted: 26
        case .tinted: 22
        }
    }

    var label: String {
        switch self {
        case .clear: "Klar"
        case .frosted: "Mattiert"
        case .tinted: "Getönt"
        }
    }

    @available(macOS 26.0, *)
    var glass: Glass {
        switch self {
        case .clear: .clear.interactive()
        case .tinted: .regular.tint(Palette.clawd).interactive()
        case .frosted: .regular.interactive()
        }
    }
}

private struct CardChrome: ViewModifier {
    let glass: Bool
    @AppStorage(Setting.glassStyle) private var style = GlassStyle.clear
    @AppStorage(Setting.cardText) private var text = CardText.automatic
    /// Set by the app from the wallpaper under the cards.
    @AppStorage("cardsOnBright") private var onBright = false
    /// Only the cards on the desktop have the wallpaper under them; previews elsewhere do not.
    @Environment(\.onDesktop) private var onDesktop

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WidgetMetrics.corner, style: .continuous)
        if #available(macOS 26.0, *), glass {
            // No extra shadow: the glass brings its own, and a second one around the backdrop turns square.
            // Clear glass needs a dimming layer to keep text legible (Apple's guidance); it leans
            // the way the text does not, so a busy wallpaper evens out without the glass going opaque.
            let light = text == .dark || (text == .automatic && onBright)
            content
                .background(shape.fill(light ? Color.white.opacity(0.38) : Color.black.opacity(0.28)))
                .background { if onDesktop { WallpaperUnder(shape: shape, blur: style.backdropBlur, tint: style == .tinted) } }
                .glassEffect(style.glass, in: shape)
                .environment(\.colorScheme, light ? .light : .dark)
        } else {
            content
                .background {
                    ZStack {
                        if glass { DesktopBlur() } else { Color(hex: 0x241A17) }
                        LinearGradient(colors: [Color(hex: 0x2A1A15, opacity: 0.55), Color(hex: 0x0E0A09, opacity: 0.70)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(.white.opacity(0.10), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .environment(\.colorScheme, .dark)
        }
    }
}

extension EnvironmentValues {
    @Entry var onDesktop = false
    /// The snapshot sheet: ImageRenderer draws no scroll views, so lists lay out flat there.
    @Entry var inSnapshot = false
}

/// The card's own piece of the desktop picture, placed exactly where it lies on screen.
private struct WallpaperUnder: View {
    let shape: RoundedRectangle
    let blur: CGFloat
    let tint: Bool

    var body: some View {
        if let image = DesktopBackdrop.shared.image {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: image.size.width, height: image.size.height)
                    .offset(x: -frame.minX, y: -frame.minY)
                    .blur(radius: blur, opaque: true)
                    .overlay { if tint { Palette.clawd.opacity(0.18) } }
            }
            .clipShape(shape)
        }
    }
}

/// Frosted glass that blurs the wallpaper behind the widget.
private struct DesktopBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
