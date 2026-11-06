import AppKit
import AVFoundation
import Observation

/// Profile pictures and media previews for the notch, fetched from the local whatsapp-mcp bridge
/// (`/api/avatar`, `/api/download`) only for what the notch actually shows. Nothing leaves the
/// Mac except the bridge's own download from WhatsApp.
@MainActor @Observable
final class WhatsAppMedia {
    static let shared = WhatsAppMedia()

    /// Settable for the snapshot sheet's sample pictures.
    var avatars: [String: NSImage] = [:]
    /// Keyed by `ChatMessage.mediaKey`.
    var previews: [String: NSImage] = [:]

    @ObservationIgnored private var asked: [String: Date] = [:]
    /// Downloaded files by `ChatMessage.mediaKey`, to open them with a click.
    @ObservationIgnored private var files: [String: String] = [:]
    /// What opens straight in its app. Anything else (a script, an app, an archive) is only shown in the
    /// Finder: the bridge's downloads carry no quarantine flag, so macOS would not warn before running them.
    private static let openable: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp", "mp4", "mov", "m4v", "pdf",
                                                "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
                                                "txt", "csv", "rtf", "ogg", "m4a", "mp3"]
    private static let bridge = URL(string: "http://127.0.0.1:8080")!
    /// Videos above this size get no preview frame: the whole file would have to come down.
    private static let videoLimit: Int64 = 40 * 1024 * 1024

    func avatar(for jid: String) -> NSImage? { avatars[jid] }
    func preview(for message: ChatMessage) -> NSImage? { previews[message.mediaKey] }

    func loadAvatar(_ jid: String) {
        guard !jid.isEmpty, avatars[jid] == nil, mayAsk("avatar|" + jid) else { return }
        Task {
            guard let path = await Self.post("api/avatar", ["jid": jid]),
                  let image = await Task.detached(priority: .utility, operation: { NSImage(contentsOfFile: path) }).value else { return }
            avatars[jid] = image
        }
    }

    /// Voice messages on disk and their length, keyed by `ChatMessage.mediaKey`.
    var voices: [String: (path: String, duration: TimeInterval)] = [:]

    /// Fetches a voice message so it plays at once (a few dozen kilobytes; nothing is marked as heard).
    func loadVoice(_ message: ChatMessage) {
        guard message.media == "audio", !message.messageID.isEmpty, voices[message.mediaKey] == nil, mayAsk(message.mediaKey) else { return }
        Task {
            guard let path = await Self.post("api/download", ["message_id": message.messageID, "chat_jid": message.jid]) else { return }
            let duration = await Task.detached(priority: .utility) { (try? AVAudioPlayer(contentsOf: URL(filePath: path)))?.duration ?? 0 }.value
            voices[message.mediaKey] = (path, duration)
        }
    }

    func loadPreview(_ message: ChatMessage) {
        guard message.showsPreview, previews[message.mediaKey] == nil, mayAsk(message.mediaKey) else { return }
        if message.media == "video", message.size > Self.videoLimit { return }
        Task {
            guard let path = await Self.post("api/download", ["message_id": message.messageID, "chat_jid": message.jid]) else { return }
            files[message.mediaKey] = path
            let video = message.media == "video"
            let image = await Task.detached(priority: .utility) { video ? Self.firstFrame(of: path) : NSImage(contentsOfFile: path) }.value
            if let image { previews[message.mediaKey] = image }
        }
    }

    /// A photo, video or document from a chat in its own app (Vorschau, QuickTime, Pages …); fetched first if needed.
    func open(_ message: ChatMessage) {
        guard !message.messageID.isEmpty else { return }
        if let path = files[message.mediaKey] {
            Self.reveal(path)
            return
        }
        Task {
            guard let path = await Self.post("api/download", ["message_id": message.messageID, "chat_jid": message.jid]) else { return }
            files[message.mediaKey] = path
            Self.reveal(path)
        }
    }

    private static func reveal(_ path: String) {
        let url = URL(filePath: path)
        if openable.contains(url.pathExtension.lowercased()) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// One try per item, another after ten minutes (older media can vanish from WhatsApp's servers).
    private func mayAsk(_ key: String) -> Bool {
        if let last = asked[key], Date.now.timeIntervalSince(last) < 600 { return false }
        asked[key] = .now
        return true
    }

    private static func post(_ endpoint: String, _ body: [String: String]) async -> String? {
        var request = URLRequest(url: bridge.appending(path: endpoint), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              reply["success"] as? Bool == true, let path = reply["path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    nonisolated private static func firstFrame(of path: String) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(filePath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height))
    }
}

/// Plays WhatsApp voice messages right in the notch. macOS reads their Ogg/Opus format itself.
/// One at a time; closing the notch stops it.
@MainActor @Observable
final class VoicePlayer {
    static let shared = VoicePlayer()

    /// The message playing or paused, by `mediaKey`.
    private(set) var current: String?
    private(set) var playing = false
    private(set) var position: TimeInterval = 0
    private(set) var rate: Float = 1

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func toggle(_ message: ChatMessage) {
        if current == message.mediaKey, let player {
            if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true; tick() }
            return
        }
        stop()
        guard let voice = WhatsAppMedia.shared.voices[message.mediaKey],
              let next = try? AVAudioPlayer(contentsOf: URL(filePath: voice.path)) else {
            WhatsAppMedia.shared.loadVoice(message)
            return
        }
        next.enableRate = true
        next.rate = rate
        next.play()
        player = next
        current = message.mediaKey
        playing = true
        tick()
    }

    /// For checks without sound: plays at volume 0 for 1.5 s and records how far it got.
    func checkMuted(_ message: ChatMessage) {
        guard let voice = WhatsAppMedia.shared.voices[message.mediaKey],
              let probe = try? AVAudioPlayer(contentsOf: URL(filePath: voice.path)) else {
            UserDefaults.standard.set("nicht geladen", forKey: "voice.check")
            return
        }
        probe.volume = 0
        probe.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UserDefaults.standard.set(String(format: "lief %.1f s von %.1f s", probe.currentTime, probe.duration), forKey: "voice.check")
            probe.stop()
        }
    }

    /// 1× → 1,5× → 2×, like WhatsApp.
    func cycleRate() {
        rate = rate >= 2 ? 1 : rate + 0.5
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        current = nil
        playing = false
        position = 0
    }

    private func tick() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying, self.playing {
                    // Played to the end.
                    self.stop()
                }
            }
        }
    }
}

extension ChatMessage {
    var mediaKey: String { "\(jid)|\(messageID)" }
    /// Photos, stickers and videos get a picture in the notch.
    var showsPreview: Bool { ["image", "sticker", "video"].contains(media) && !messageID.isEmpty }

    /// What the chat list and the pop-up show: in a group with the writer's name, as in WhatsApp.
    var preview: String { group && !sender.isEmpty && !fromMe ? "\(sender.split(separator: " ").first ?? ""): \(text)" : text }

    /// A small symbol before "Foto", "Video" and the like, as WhatsApp shows it in the chat list.
    var mediaSymbol: String? {
        switch media {
        case "image": "camera.fill"
        case "video": "video.fill"
        case "audio": "mic.fill"
        case "document": "doc.fill"
        case "sticker": "face.smiling"
        default: nil
        }
    }
}
