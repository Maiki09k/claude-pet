import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class PetModel {
    var activity = ActivitySnapshot()
    /// Starts with the last numbers from before a restart, so the card is never empty for minutes.
    var usage = PetModel.savedUsage() ?? UsageState.loading
    var pokedAt = Date.distantPast
    /// False while the widget is covered, so the animation stops costing anything.
    var visible = true
    var opensAtLogin = SMAppService.mainApp.status == .enabled
    let startedAt = Date.now
    /// Stepped from inside the animation, so it must not trigger view updates itself.
    @ObservationIgnored let critter = Critter()

    private let usageClient = UsageClient()
    private var lastUsageFetch = Date.distantPast
    private var usageInterval: TimeInterval = 180

    var sessionPercent: Double? {
        guard case .ready(let bars, _) = usage else { return nil }
        return bars.first { $0.id == "five_hour" }?.percent
    }

    func start() {
        Task {
            while !Task.isCancelled {
                await refreshActivity()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task {
            while !Task.isCancelled {
                await refreshUsage(minimumAge: usageInterval)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func poke() {
        pokedAt = .now
    }

    private func refreshActivity() async {
        let next = await Task.detached(priority: .utility) { ActivityScanner.scan() }.value
        let turnEnded = next.working < activity.working
        if next != activity { activity = next }
        // A finished turn is the moment the limits actually moved.
        if turnEnded { Task { await refreshUsage(minimumAge: 45) } }
    }

    func refreshUsage(minimumAge: TimeInterval) async {
        guard Date.now.timeIntervalSince(lastUsageFetch) > minimumAge else { return }
        lastUsageFetch = .now
        let next = await usageClient.fetch()
        usageInterval = next == .failed("zu viele Abfragen") ? 600 : 180
        // Offline for a moment: keep showing the last numbers instead of an error.
        if case .failed = next, case .ready = usage { return }
        usage = next
        if case .ready(let bars, let fetched) = next { Self.save(bars, fetched: fetched) }
    }

    private static let usageKey = "usage.last"

    /// The last limits, at most a day old (the five-hour window has long moved on after that).
    private static func savedUsage() -> UsageState? {
        guard let stored = UserDefaults.standard.dictionary(forKey: usageKey),
              let fetched = stored["fetched"] as? Date, Date.now.timeIntervalSince(fetched) < 86400,
              let rows = stored["bars"] as? [[String: Any]] else { return nil }
        let bars = rows.compactMap { row -> UsageBar? in
            guard let id = row["id"] as? String, let label = row["label"] as? String, let percent = row["percent"] as? Double else { return nil }
            let reset = row["resetsAt"] as? Date
            // A window that has reset since then starts again from zero.
            if let reset, reset < .now { return UsageBar(id: id, label: label, percent: 0, resetsAt: nil) }
            return UsageBar(id: id, label: label, percent: percent, resetsAt: reset)
        }
        return bars.isEmpty ? nil : .ready(bars, fetched: fetched)
    }

    private static func save(_ bars: [UsageBar], fetched: Date) {
        let rows: [[String: Any]] = bars.map { bar in
            var row: [String: Any] = ["id": bar.id, "label": bar.label, "percent": bar.percent]
            if let reset = bar.resetsAt { row["resetsAt"] = reset }
            return row
        }
        UserDefaults.standard.set(["fetched": fetched, "bars": rows], forKey: usageKey)
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudePet: Anmeldeobjekt nicht geändert: \(error.localizedDescription)")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
