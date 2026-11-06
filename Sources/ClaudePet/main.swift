import AppKit
import SwiftUI

/// Borderless window that sits on the desktop like a macOS widget: above the
/// wallpaper and icons, below every app window, on all Spaces.
final class DesktopPanel: NSPanel {
    private static let autosaveName = "ClaudePet"

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own shadow; a window shadow would trail behind the walking critter.
        hasShadow = false
        level = Self.restingLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    /// Just above the desktop icons, below every app window.
    static let restingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Last dragged position, or the top right corner on first launch.
    /// Top right corner of the main screen.
    func moveToDefaultPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 10, y: visible.maxY - frame.height - 4))
    }

    func restorePosition() {
        let size = frame.size
        if setFrameUsingName(Self.autosaveName) {
            // The saved frame may come from an older, differently sized layout: keep its top edge.
            setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: false)
        } else {
            moveToDefaultPosition()
        }
        setFrameAutosaveName(Self.autosaveName)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PetModel()
    private let media = MediaCenter()
    private let agenda = Agenda()
    private let whatsapp = WhatsAppFeed()
    private lazy var notch = NotchController(claude: model, media: media, agenda: agenda, whatsapp: whatsapp)
    private lazy var settings = SettingsWindow(model: model, agenda: agenda, actions: settingsActions)
    private var panel: DesktopPanel?

    private var settingsActions: SettingsActions {
        SettingsActions(
            showCards: { [weak self] in self?.liftCards() },
            resetPosition: { [weak self] in self?.panel?.moveToDefaultPosition() },
            preview: { kind in
                DistributedNotificationCenter.default().postNotificationName(.init("io.github.maiki09k.claudepet.preview"), object: kind,
                                                                             userInfo: nil, deliverImmediately: true)
            },
            desktopArea: { [weak self] in
                guard let panel = self?.panel, let screen = panel.screen ?? NSScreen.main,
                      let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
                return (panel.frame, screen.frame, url)
            })
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) brings up the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    @objc func showSettings(_ sender: Any?) { settings.show() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let panel = DesktopPanel(size: WidgetMetrics.size)
        let host = NSHostingView(rootView: WidgetView(model: model, agenda: agenda, openSettings: { [weak self] in self?.settings.show() }))
        // Fixed-size window: no constraint updates on every animation frame.
        host.sizingOptions = []
        panel.contentView = host
        panel.restorePosition()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        // Preview "widget": lifts the cards above all windows for four seconds, to check them.
        // "settings:<page>" opens the settings window on general, desktop, notch, popups or calendar;
        // "settings:close" closes it.
        // "glass:clear", "glass:tinted", "glass:frosted" switch the glass look and lift them too.
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.maiki09k.claudepet.preview"), object: nil,
                                                            queue: .main) { [weak self] note in
            guard let kind = note.object as? String else { return }
            // "set:card.claude=false" flips a setting inside the app, like a click in the settings
            // window would (a `defaults write` from outside does not reach the views).
            if kind.hasPrefix("set:"), let equals = kind.firstIndex(of: "=") {
                let key = String(kind[kind.index(kind.startIndex, offsetBy: 4)..<equals])
                let raw = String(kind[kind.index(after: equals)...])
                let value: Any = raw == "true" ? true : raw == "false" ? false : Double(raw).map { $0 as Any } ?? raw
                UserDefaults.standard.set(value, forKey: key)
                return
            }
            // "stage:on" / "stage:off": a clean set for screen recordings (see setStage).
            if kind == "stage:on" || kind == "stage:off" {
                MainActor.assumeIsolated { self?.setStage(kind == "stage:on") }
                return
            }
            // "settings:notch" opens the settings on that page.
            if kind == "settings:close" {
                MainActor.assumeIsolated { self?.settings.close() }
                return
            }
            if kind.hasPrefix("settings:") {
                UserDefaults.standard.set(String(kind.dropFirst(9)), forKey: "settings.pane")
                MainActor.assumeIsolated { self?.settings.show() }
                return
            }
            guard kind == "widget" || kind.hasPrefix("glass:") else { return }
            if kind.hasPrefix("glass:"), let style = GlassStyle(rawValue: String(kind.dropFirst(6))) {
                UserDefaults.standard.set(style.rawValue, forKey: "glassStyle")
            }
            MainActor.assumeIsolated { self?.liftCards() }
        }
        self.panel = panel
        // Glass shows the wallpaper through, so the text colour follows how bright it is right there.
        updateBackdrop()
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBackdrop() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBackdrop() }
        }
        // Switches in the settings window take effect at once, not on the next tick.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        // A new desktop picture sends no notification.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBackdrop() }
        }
        model.start()
        media.start()
        whatsapp.start()
        notch.start()
        Task { await agenda.start() }
    }

    private var stage: NSWindow?

    /// For demo recordings: the desktop picture over every app window and above notification
    /// banners (level 22), the cards and the settings window just above it, the menu bar and the
    /// notch still on top. Nothing private ends up in the video.
    private func setStage(_ on: Bool) {
        guard let panel else { return }
        let lifted = NSWindow.Level(rawValue: 23)
        if on {
            guard stage == nil, let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let picture = Wallpaper.crop(behind: screen.frame, in: screen.frame, from: url) else { return }
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: 22)
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = NSImageView(image: NSImage(cgImage: picture, size: screen.frame.size))
            view.imageScaling = .scaleAxesIndependently
            window.contentView = view
            window.orderFrontRegardless()
            stage = window
            panel.level = lifted
            panel.orderFrontRegardless()
            settings.stageLevel = lifted
        } else {
            stage?.orderOut(nil)
            stage = nil
            panel.level = DesktopPanel.restingLevel
            settings.stageLevel = nil
            updateVisibility()
        }
    }

    /// Shown while the settings window is open; it also gives text fields copy and paste.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu(title: "Claude Pet")
        app.addItem(withTitle: "Einstellungen …", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Claude Pet ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Claude Pet beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Fenster")
        window.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for sub in [app, edit, window] {
            let item = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        return menu
    }

    private func liftCards() {
        guard let panel, let screen = panel.screen else { return }
        let resting = panel.level
        // The glass is judged against the wallpaper it normally sits on, so that slice of the
        // desktop picture goes behind the lifted cards.
        let backdrop = Self.wallpaperSlice(behind: panel.frame.insetBy(dx: -30, dy: -30), on: screen)
        backdrop?.orderFrontRegardless()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.orderFrontRegardless()
        model.visible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            backdrop?.orderOut(nil)
            panel.level = resting
            self?.updateVisibility()
        }
    }

    private var backdropKey = ""
    private var backdropBusy = false

    /// Light text on a dark wallpaper, dark text on a bright one, like Apple's own widgets.
    private func updateBackdrop() {
        guard !backdropBusy, let panel, let screen = panel.screen ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let rect = panel.frame.insetBy(dx: WidgetMetrics.margin, dy: WidgetMetrics.margin)
        let panelFrame = panel.frame
        let screenFrame = screen.frame
        let key = "\(url.path)|\(panelFrame)"
        guard key != backdropKey else { return }
        backdropBusy = true
        // A picture in Downloads or Documents waits for a privacy prompt on first read; that must
        // never stall the widget and the notch, so the picture is read off the main thread.
        Task.detached(priority: .utility) {
            let brightness = Wallpaper.crop(behind: rect, in: screenFrame, from: url).flatMap(Wallpaper.brightness(of:))
            let under = Wallpaper.crop(behind: panelFrame, in: screenFrame, from: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.backdropBusy = false
                DesktopBackdrop.shared.image = under.map { NSImage(cgImage: $0, size: panelFrame.size) }
                // Also on failure: a refused folder is not asked again until the picture changes.
                self.backdropKey = key
                guard let brightness else { return }
                let defaults = UserDefaults.standard
                // A little hysteresis, so a mid-grey picture does not flip the cards back and forth.
                let onBright = defaults.bool(forKey: "cardsOnBright") ? brightness > 0.40 : brightness > 0.50
                if defaults.bool(forKey: "cardsOnBright") != onBright { defaults.set(onBright, forKey: "cardsOnBright") }
            }
        }
    }

    /// A window showing exactly the part of the desktop picture that lies under `rect` (fill scaling).
    private static func wallpaperSlice(behind rect: NSRect, on screen: NSScreen) -> NSWindow? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let slice = Wallpaper.crop(behind: rect, in: screen.frame, from: url) else { return nil }
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        let view = NSImageView(image: NSImage(cgImage: slice, size: rect.size))
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        return window
    }

    /// macOS reports desktop-level windows as visible even when an app window covers
    /// them completely, so the windows above are checked as well.
    private func updateVisibility() {
        guard let panel else { return }
        // Both cards switched off in the settings: no window at all, so nothing blocks the desktop.
        let wanted = Setting.on(Setting.claudeCard) || Setting.on(Setting.agendaCard)
        if wanted != panel.isVisible { wanted ? panel.orderFrontRegardless() : panel.orderOut(nil) }
        // Only Clawd's drawing strip needs a frame clock. A visible agenda below a
        // covered Clawd must not keep the animation running behind another window.
        let strip = CGRect(x: panel.frame.minX, y: panel.frame.maxY - WidgetMetrics.band - 12,
                           width: panel.frame.width, height: WidgetMetrics.band + 12)
        let animates = wanted && Setting.on(Setting.critter) && panel.occlusionState.contains(.visible)
            && !isCovered(panel, area: strip)
        if model.visible != animates { model.visible = animates }
    }

    /// Several stacked windows can each hide a different part of the animation.
    private func isCovered(_ panel: NSWindow, area: CGRect) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]]
        else { return false }
        let appWindows = windows.compactMap { info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.95,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        // CoreGraphics counts from the top edge of the main screen. Include the whole
        // drawing strip so even a partly visible effect keeps its normal frame rate.
        let frame = CGRect(x: area.minX, y: mainHeight - area.maxY, width: area.width, height: area.height)
        return WindowCoverage.covers(frame, with: appWindows)
    }
}

MainActor.assumeIsolated {
    Setting.register()
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
        exit(Snapshot.write(to: URL(filePath: arguments[flag + 1])) ? 0 : 1)
    }
    // Claude Code's PreToolUse hook for AskUserQuestion (see AskBridge).
    if arguments.contains("--ask-hook") {
        exit(AskBridge.runHook())
    }
    if let flag = arguments.firstIndex(of: "--icon"), flag + 1 < arguments.count {
        exit(Snapshot.writeIcon(to: URL(filePath: arguments[flag + 1])) ? 0 : 1)
    }
    if let flag = arguments.firstIndex(of: "--notch-snapshot"), flag + 1 < arguments.count {
        exit(Snapshot.writeNotch(to: URL(filePath: arguments[flag + 1])) ? 0 : 1)
    }
    // `ClaudePet --status` prints what the widget would show, for debugging from the terminal.
    if arguments.contains("--status") {
        let activity = ActivityScanner.scan()
        print("Stimmung: \(activity.mood.rawValue) · arbeiten: \(activity.working) · warten: \(activity.asking) · Werkzeug: \(activity.tool ?? "-")")
        for session in activity.sessions {
            print("  · \(session.agent.rawValue) · \(session.title): \(session.mood.rawValue)")
            if let question = session.question { print("    fragt: \(question.title) \(question.options)") }
            if let summary = session.summary { print("    Ergebnis: \(summary.count) Zeichen") }
        }
        print(WhatsAppFeed().diagnose())
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            print("Limits: \(await UsageClient().fetch())")
            finished.signal()
        }
        finished.wait()
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

