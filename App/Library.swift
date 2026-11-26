import Foundation
import Combine

struct Video: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var watchURL: URL { URL(string: "https://m.youtube.com/watch?v=\(id)")! }
    var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }

    static func parse(_ url: URL, title: String = "") -> Self? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if ["m.youtube.com", "www.youtube.com", "youtube.com", "music.youtube.com"].contains(host) {
            if url.path == "/watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count == 2, ["live", "shorts", "embed"].contains(parts[0]) {
                id = parts[1]
            } else { return nil }
        } else { return nil }
        guard let id, id.utf8.count == 11, id.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Video(id: id, title: clean.isEmpty ? id : String(clean.prefix(300)))
    }
}

@MainActor final class Library: ObservableObject {
    @Published private(set) var saved: [Video]
    @Published private(set) var history: [Video]
    @Published private(set) var downloads: [Video]
    private var positions: [String: Double]
    private let defaults = UserDefaults.standard

    init() {
        func read(_ key: String) -> [Video] {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Video].self, from: data)) ?? []
        }
        saved = read("saved")
        history = read("history")
        downloads = read("downloads")
        positions = UserDefaults.standard.dictionary(forKey: "positions") as? [String: Double] ?? [:]
        downloads = downloads.filter { file(for: $0) != nil }
    }

    private func persist(_ videos: [Video], _ key: String) {
        defaults.set(try? JSONEncoder().encode(videos), forKey: key)
    }

    func bookmark(_ video: Video) {
        if saved.contains(where: { $0.id == video.id }) { saved.removeAll { $0.id == video.id } }
        else { saved.insert(video, at: 0) }
        persist(saved, "saved")
    }

    func played(_ video: Video) {
        history = Array(([video] + history.filter { $0.id != video.id }).prefix(150))
        persist(history, "history")
    }

    func clearHistory() {
        history.removeAll()
        positions.removeAll()
        persist(history, "history")
        defaults.removeObject(forKey: "positions")
    }

    /// Remove a single entry from the History shelf (long-press action).
    func removeHistory(_ video: Video) {
        history.removeAll { $0.id == video.id }
        positions.removeValue(forKey: video.id)
        persist(history, "history")
        defaults.set(positions, forKey: "positions")
    }

    func resumeTime(_ video: Video) -> Double { positions[video.id] ?? 0 }
    func mark(_ video: Video, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[video.id] = seconds
        defaults.set(positions, forKey: "positions")
    }

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private func path(_ video: Video, _ ext: String) -> URL {
        directory.appendingPathComponent(video.id).appendingPathExtension(ext)
    }

    func file(for video: Video) -> URL? {
        ["mp4", "m4a"].map { path(video, $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func store(_ temporary: URL, video: Video, audioOnly: Bool) throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
        let target = path(video, audioOnly ? "m4a" : "mp4")
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: target) }
        downloads = [video] + downloads.filter { $0.id != video.id }
        persist(downloads, "downloads")
    }

    func removeDownload(_ video: Video) throws {
        for ext in ["mp4", "m4a"] where FileManager.default.fileExists(atPath: path(video, ext).path) {
            try FileManager.default.removeItem(at: path(video, ext))
        }
        downloads.removeAll { $0.id == video.id }
        persist(downloads, "downloads")
    }
}
