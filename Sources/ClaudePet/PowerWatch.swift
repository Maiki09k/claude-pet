import Foundation
import IOKit.ps
import Observation

/// Notices the moment a charger is plugged in, for the notch's charging flash.
@MainActor @Observable
final class PowerWatch {
    /// Battery percentage to flash while it is set; cleared after a few seconds.
    var flash: Int?

    @ObservationIgnored private var charging = PowerWatch.read()?.charging ?? false
    @ObservationIgnored private var source: CFRunLoopSource?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watch = Unmanaged<PowerWatch>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watch.changed() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    /// For the preview trigger: flash without a real plug-in.
    func showFlash() {
        flash = Self.read()?.percent ?? 100
        Task {
            try? await Task.sleep(for: .seconds(4))
            flash = nil
        }
    }

    private func changed() {
        let now = Self.read()?.charging ?? false
        defer { charging = now }
        if now, !charging { showFlash() }
    }

    static func read() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (capacity, plugged)
        }
        return nil
    }
}
