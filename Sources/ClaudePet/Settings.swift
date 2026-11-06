import AppKit
import ImageIO

/// Everything the settings window can switch. Stored in UserDefaults, so views read it with
/// `@AppStorage(Setting.x)` and the controllers on their next tick, without any wiring.
enum Setting {
    // Desktop cards
    static let claudeCard = "card.claude"
    static let agendaCard = "card.agenda"
    static let critter = "card.critter"
    static let glassStyle = "glassStyle"
    static let cardText = "card.text"

    // Notch
    static let notch = "notch.enabled"
    static let music = "notch.music"
    static let whatsapp = "notch.whatsapp"
    static let agenda = "notch.agenda"
    static let claude = "notch.claude"
    static let codex = "notch.codex"
    static let ears = "notch.ears"
    static let charging = "notch.charging"
    static let openDelay = "notch.openDelay"
    /// How many hours ahead an appointment earns its place in the open notch.
    static let agendaHours = "notch.agendaHours"

    // Pop-ups
    static let whatsappBanner = "banner.whatsapp"
    static let groupBanner = "banner.groups"
    static let whatsappSeconds = "banner.whatsappSeconds"
    /// How long an unread WhatsApp message stays in the notch, in hours.
    static let whatsappHours = "notch.whatsappHours"
    static let questionBanner = "banner.questions"
    static let questionSeconds = "banner.questionSeconds"

    // Pop-up when Claude or Codex finished, and before an appointment
    static let doneBanner = "banner.done"
    static let doneSeconds = "banner.doneSeconds"
    static let meetingAlert = "banner.meeting"
    /// Minutes before the start.
    static let meetingLead = "banner.meetingLead"

    // Shelf for files dropped on the notch
    static let shelf = "notch.shelf"

    // Answering Claude's questions in the notch
    static let askInNotch = "ask.enabled"
    /// How long a question waits in the notch before Claude shows it itself.
    static let askSeconds = "ask.seconds"

    // Calendar
    static let hiddenCalendars = "agenda.hiddenCalendars"

    /// The defaults every `@AppStorage` in the views repeats.
    static func register() {
        UserDefaults.standard.register(defaults: [
            claudeCard: true, agendaCard: true, critter: true,
            glassStyle: GlassStyle.clear.rawValue, cardText: CardText.automatic.rawValue,
            notch: true, music: true, whatsapp: true, agenda: true, claude: true, codex: true,
            ears: true, charging: true, openDelay: 0.15, agendaHours: 12.0,
            whatsappBanner: true, groupBanner: false, whatsappSeconds: 5.0, whatsappHours: 12.0,
            questionBanner: true, questionSeconds: 8.0,
            askInNotch: true, askSeconds: 30.0,
            doneBanner: true, doneSeconds: 6.0, meetingAlert: true, meetingLead: 2.0, shelf: true,
        ])
    }

    static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func value(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
}

/// Text colour on the desktop cards.
enum CardText: String, CaseIterable, Identifiable {
    /// Follows how bright the wallpaper is under the cards.
    case automatic
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatisch"
        case .dark: "Dunkel"
        case .light: "Hell"
        }
    }
}

/// The desktop picture under a part of the screen, read without AppKit so it works off the main
/// thread: a picture in Downloads or Documents waits for a privacy prompt on first read.
enum Wallpaper {
    /// The part of the picture at `url` that lies under `rect`, as macOS draws it (fill scaling).
    nonisolated static func crop(behind rect: NSRect, in frame: NSRect, from url: URL) -> CGImage? {
        guard let image = decoded(url) else { return nil }
        let pixels = CGSize(width: image.width, height: image.height)
        let scale = max(frame.width / pixels.width, frame.height / pixels.height)
        let drawn = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let origin = CGPoint(x: frame.minX + (frame.width - drawn.width) / 2, y: frame.minY + (frame.height - drawn.height) / 2)
        // CGImage rows run top-down, screen coordinates bottom-up.
        let crop = CGRect(x: (rect.minX - origin.x) / scale, y: (origin.y + drawn.height - rect.maxY) / scale,
                          width: rect.width / scale, height: rect.height / scale)
        return image.cropping(to: crop.integral)
    }

    private nonisolated(unsafe) static var cache: (url: URL, image: CGImage)?
    private static let cacheLock = NSLock()

    /// The whole picture, decoded once per file.
    nonisolated static func decoded(_ url: URL) -> CGImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache, cache.url == url { return cache.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        cache = (url, image)
        return image
    }

    /// Mean relative luminance (0 black, 1 white) of an image.
    nonisolated static func brightness(of image: CGImage) -> Double? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Grey values are gamma encoded; luminance is linear.
        let linear = pixels.map { value -> Double in
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return linear.reduce(0, +) / Double(linear.count)
    }
}

/// The piece of desktop picture under the desktop panel. The cards lay it under their glass:
/// after a Space change Apple's glass shows a grey stand-in for ~0.7 s until it has sampled the
/// new wallpaper (recorded 26.10.2026), and this picture covers exactly that moment.
@MainActor @Observable
final class DesktopBackdrop {
    static let shared = DesktopBackdrop()
    var image: NSImage?
}
