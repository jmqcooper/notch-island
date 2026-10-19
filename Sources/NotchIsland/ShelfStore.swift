import AppKit

/// Files parked in the notch. Stored as bookmarks, so the shelf follows a file
/// if it moves and never copies anything.
@MainActor
final class ShelfStore: ObservableObject {
    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        var bookmark: Data
        var name: String
    }

    @Published private(set) var items: [Item] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NotchIsland/shelf.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved.filter { url(for: $0) != nil }
        }
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.compactMap { url(for: $0)?.standardizedFileURL })
        for url in urls where url.isFileURL && !existing.contains(url.standardizedFileURL) {
            guard let bookmark = try? url.bookmarkData() else { continue }
            items.append(Item(id: UUID(), bookmark: bookmark, name: url.lastPathComponent))
        }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func url(for item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var urls: [URL] { items.compactMap(url(for:)) }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            Log.write("saving the shelf failed: \(error)")
        }
    }
}
