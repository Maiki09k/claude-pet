import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A file parked in the notch. Only its path is kept; the file stays where it is.
struct ShelfItem: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Files dropped on the notch, to drag out again later (into a mail, a chat, another folder).
/// Survives restarts as a list of paths in the settings.
@MainActor @Observable
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var items: [ShelfItem]
    /// Quick Look previews, made right after a drop while the file is surely reachable.
    private(set) var thumbnails: [String: NSImage] = [:]
    private static let key = "shelf.items"

    private init() {
        // No existence check here: touching files in Desktop or Documents at launch would ask for access.
        items = (UserDefaults.standard.stringArray(forKey: Self.key) ?? []).map { ShelfItem(url: URL(filePath: $0)) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.id == url.path }) {
            items.append(ShelfItem(url: url))
            makeThumbnail(for: url)
        }
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0 == item }
        thumbnails[item.id] = nil
        save()
    }

    func clear() {
        items = []
        thumbnails = [:]
        save()
    }

    /// The preview, or the icon of the file's type (which needs no access to the file itself).
    func image(for item: ShelfItem) -> NSImage {
        if let thumbnail = thumbnails[item.id] { return thumbnail }
        let type = UTType(filenameExtension: item.url.pathExtension) ?? (item.url.hasDirectoryPath ? .folder : .data)
        return NSWorkspace.shared.icon(for: type)
    }

    /// Opens the file; one that has gone away leaves the shelf.
    func open(_ item: ShelfItem) {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return remove(item) }
        NSWorkspace.shared.open(item.url)
    }

    private func makeThumbnail(for url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in ShelfStore.shared.thumbnails[url.path] = image }
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.id), forKey: Self.key)
    }
}
