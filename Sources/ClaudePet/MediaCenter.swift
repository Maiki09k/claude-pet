import AppKit
import Observation
import SwiftUI

struct Track: Equatable {
    var player: MediaPlayer
    var title: String
    var artist: String
    var artworkURL: URL?
    var playing: Bool
    var position: Double
    var duration: Double
    var fetched: Date
    var shuffling = false
    var repeating = false
    var volume = 50
}

enum MediaPlayer: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var appName: String { self == .spotify ? "Spotify" : "Music" }
}

/// What Spotify or Apple Music is playing, read and controlled over AppleScript.
/// Only apps that already run are asked, so polling never launches a player.
@MainActor @Observable
final class MediaCenter {
    var track: Track?
    var artwork: NSImage?
    /// Average colour of the cover, used to tint the equaliser.
    var accent = Color.white
    /// macOS refused the automation permission.
    var blocked = false
    /// Worth a place in the notch: playing, or paused for less than ten minutes.
    var relevant = false

    @ObservationIgnored private var pausedSince: Date?

    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private let runner = ScriptRunner()
    /// One question to the player at a time; a request meanwhile asks once more afterwards.
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var askAgain = false

    func start() {
        refresh()
        // Both players announce every play, pause and track change, so there is nothing to poll.
        let players = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            players.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Safety net for a missed announcement; the progress bar extrapolates in between.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Asks the player in the background: AppleScript waits ~80 ms for Spotify's answer, which
    /// on the main thread stalled the notch's opening spring (measured 26.10.2026).
    func refresh() {
        if asking { askAgain = true; return }
        asking = true
        let running = MediaPlayer.allCases.filter(isRunning)
        runner.perform { runner in
            var found: Track?
            var refused = false
            for player in running {
                let (next, code) = runner.query(player)
                refused = refused || code == -1743
                if let next { found = next; break }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(found, refused: refused) }
            }
        }
    }

    private func apply(_ next: Track?, refused: Bool) {
        asking = false
        // -1743: the person has not allowed this app to control the player.
        if blocked != refused { blocked = refused }
        if next != track { track = next }
        if let next { loadArtwork(next.artworkURL) }
        updateRelevance()
        if askAgain {
            askAgain = false
            refresh()
        }
    }

    private func updateRelevance() {
        if track?.playing == true {
            pausedSince = nil
        } else if track != nil, pausedSince == nil {
            pausedSince = .now
        }
        let now = track != nil && (track?.playing == true || (pausedSince?.timeIntervalSinceNow ?? 0) > -10 * 60)
        if now != relevant { relevant = now }
    }

    // Controls show their effect at once; the player's own answer follows from the background.
    func playPause() {
        if let current = track { track?.playing = !current.playing; track?.position = current.position; track?.fetched = .now }
        send("playpause")
    }
    func seek(to seconds: Double) {
        track?.position = seconds; track?.fetched = .now
        send("set player position to \(Int(seconds))")
    }
    func setVolume(_ volume: Int) {
        track?.volume = min(max(volume, 0), 100)
        send("set sound volume to \(min(max(volume, 0), 100))")
    }

    func toggleShuffle() {
        track?.shuffling.toggle()
        send(track?.player == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled")
    }

    func toggleRepeat() {
        track?.repeating.toggle()
        send(track?.player == .spotify
             ? "set repeating to not repeating"
             : "if song repeat is off then\nset song repeat to all\nelse\nset song repeat to off\nend if")
    }

    func openPlayer() {
        guard let player = track?.player else { return }
        NotchActions.open(player.rawValue)
    }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ command: String) {
        guard let player = track?.player else { return }
        let source = "tell application \"\(player.appName)\"\n\(command)\nend tell"
        runner.perform { runner in
            _ = runner.run(source)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func isRunning(_ player: MediaPlayer) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty
    }

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        guard let url else {
            artwork = nil
            accent = .white
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
                  url == artworkURL else { return }
            artwork = image
            accent = Self.averageColor(of: image)
        }
    }

    private static func averageColor(of image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Lift dark covers so the bars stay visible on black.
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: min(saturation * 1.2, 0.85), brightness: max(brightness, 0.85))
    }
}

/// Every AppleScript lives and runs on one serial background queue (NSAppleScript is not
/// thread-safe, so its instances never leave that queue).
private final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.maiki09k.claudepet.applescript", qos: .userInitiated)
    /// Compiled once per player; compiling every second cost more than the query itself.
    private var scripts: [MediaPlayer: NSAppleScript] = [:]

    func perform(_ work: @escaping @Sendable (ScriptRunner) -> Void) {
        queue.async { work(self) }
    }

    /// The script's text result, or the AppleScript error number.
    func run(_ source: String) -> (String?, Int?) {
        guard let script = NSAppleScript(source: source) else { return (nil, nil) }
        return run(script)
    }

    func query(_ player: MediaPlayer) -> (Track?, Int?) {
        let (output, code) = run(script(for: player))
        guard let output else { return (nil, code) }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 6 else { return (nil, nil) }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var track = Track(player: player, title: lines[1], artist: lines[2], artworkURL: URL(string: lines[3]),
                          playing: lines[0] == "playing", position: number(lines[4]), duration: number(lines[5]), fetched: .now)
        if lines.count >= 9 {
            track.shuffling = lines[6] == "true"
            track.repeating = lines[7] == "true"
            track.volume = Int(number(lines[8]))
        }
        return (track, nil)
    }

    private func script(for player: MediaPlayer) -> NSAppleScript {
        if let cached = scripts[player] { return cached }
        // Spotify reports the duration in milliseconds and has cover URLs, Music in seconds without.
        let duration = player == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let artwork = player == .spotify ? "(artwork url of t)" : "\"\""
        let modes = player == .spotify
            ? "(shuffling as string) & linefeed & (repeating as string)"
            : "(shuffle enabled as string) & linefeed & ((song repeat is not off) as string)"
        let source = """
        tell application "\(player.appName)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & \(artwork) & linefeed & (player position as string) & linefeed & (\(duration) as string) & linefeed & \(modes) & linefeed & (sound volume as string)
        end tell
        """
        let script = NSAppleScript(source: source)!
        script.compileAndReturnError(nil)
        scripts[player] = script
        return script
    }

    private func run(_ script: NSAppleScript) -> (String?, Int?) {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int { return (nil, code) }
        return (result.stringValue, nil)
    }
}
