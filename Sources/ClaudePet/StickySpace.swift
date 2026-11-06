import AppKit

/// A window-server space of its own at a fixed level. Windows in it take no part in Space
/// switches: macOS slides every other window, including ones that join all Spaces, while the
/// desktop changes (recorded 26.10.2026), but the notch has to stay over the camera. Same
/// approach as Boring Notch and other notch apps; it uses private CoreGraphics calls.
final class StickySpace {
    private let id: SpaceID
    private var members: Set<Int> = []

    init(level: Int = Int(Int32.max)) {
        // Flag 1: an ordinary user space (other values make Finder draw desktop icons into it).
        id = CGSSpaceCreate(_CGSDefaultConnection(), 1, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), id, level)
        CGSShowSpaces(_CGSDefaultConnection(), [id] as NSArray)
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [id] as NSArray)
        CGSSpaceDestroy(_CGSDefaultConnection(), id)
    }

    func add(_ window: NSWindow) {
        guard members.insert(window.windowNumber).inserted else { return }
        CGSAddWindowsToSpaces(_CGSDefaultConnection(), [window.windowNumber] as NSArray, [id] as NSArray)
    }

    func remove(_ window: NSWindow) {
        guard members.remove(window.windowNumber) != nil else { return }
        CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(), [window.windowNumber] as NSArray, [id] as NSArray)
    }
}

private typealias ConnectionID = UInt
private typealias SpaceID = UInt64

@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> ConnectionID
@_silgen_name("CGSSpaceCreate") private func CGSSpaceCreate(_ cid: ConnectionID, _ flag: Int, _ options: NSDictionary?) -> SpaceID
@_silgen_name("CGSSpaceDestroy") private func CGSSpaceDestroy(_ cid: ConnectionID, _ space: SpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel") private func CGSSpaceSetAbsoluteLevel(_ cid: ConnectionID, _ space: SpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces") private func CGSAddWindowsToSpaces(_ cid: ConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSRemoveWindowsFromSpaces") private func CGSRemoveWindowsFromSpaces(_ cid: ConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces") private func CGSShowSpaces(_ cid: ConnectionID, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces") private func CGSHideSpaces(_ cid: ConnectionID, _ spaces: NSArray)
