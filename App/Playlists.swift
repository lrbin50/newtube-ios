import Foundation

// MARK: - Account playlists
//
// Fetches the signed-in user's playlists (Watch later, private playlists,
// saved playlists) via InnerTube `browse`. `FEplaylists` is the dedicated
// playlist page (requires a token); `FElibrary` is the fallback shelf source.
// Parsing accepts both the new TVHTML5 `lockupViewModel` shape and the older
// gridPlaylistRenderer / playlistRenderer shapes.

struct YTPlaylist: Identifiable, Equatable {
    /// Playlist id with the `VL` prefix InnerTube expects for browsing.
    let id: String
    var title: String
    var thumbnail: URL?
    var count: Int?
}

@MainActor final class PlaylistsStore: ObservableObject {
    static let shared = PlaylistsStore()

    @Published private(set) var playlists: [YTPlaylist] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvClientVersion = "7.20260311.12.00"

    func load(force: Bool = false) async {
        if !force && !playlists.isEmpty { return }
        loading = true
        defer { loading = false }
        guard let token = try? await Account.shared.validToken() else {
            message = FeedError.notSignedIn.errorDescription
            return
        }
        var found: [YTPlaylist] = []
        for browseId in ["FEplaylists", "FElibrary"] {
            let json = try? await browse(browseId: browseId, token: token)
            found = Self.parse(json ?? [:])
            if !found.isEmpty { break }
        }
        if found.isEmpty {
            message = FeedError.badResponse.errorDescription
        }
        playlists = found
    }

    /// Videos inside a playlist, reusing the shared structure-agnostic
    /// video parser from Feed.
    func videos(of playlist: YTPlaylist) async -> [Video] {
        guard let token = try? await Account.shared.validToken() else { return [] }
        let json = try? await browse(browseId: playlist.id, token: token)
        return Feed.parse(json ?? [:]).videos.map { $0.video }
    }

    private func browse(browseId: String, token: String) async throws -> [String: Any]? {
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "TVHTML5",
                    "clientVersion": tvClientVersion,
                    "hl": "en", "gl": "US",
                    "platform": "TV",
                    "clientFormFactor": "UNKNOWN_FORM_FACTOR"
                ],
                "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
                "request": ["useSsl": true, "internalExperimentFlags": []]
            ],
            "browseId": browseId
        ]
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("7", forHTTPHeaderField: "X-YOUTUBE-CLIENT-NAME")
        request.setValue(tvClientVersion, forHTTPHeaderField: "X-YOUTUBE-CLIENT-VERSION")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await LegacyNetwork.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Parsing

    static func parse(_ json: [String: Any]) -> [YTPlaylist] {
        var found: [YTPlaylist] = []
        var seen = Set<String>()
        walk(json) { dict in
            if let playlist = playlist(from: dict), seen.insert(playlist.id).inserted {
                found.append(playlist)
            }
        }
        return found
    }

    private static func walk(_ value: Any, into handler: ([String: Any]) -> Void) {
        if let dict = value as? [String: Any] {
            handler(dict)
            for child in dict.values { walk(child, into: handler) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, into: handler) }
        }
    }

    private static func playlist(from dict: [String: Any]) -> YTPlaylist? {
        // New TVHTML5 shape: lockupViewModel with a VL-prefixed contentId.
        if let lockup = dict["lockupViewModel"] as? [String: Any],
           let id = lockup["contentId"] as? String {
            let type = lockup["contentType"] as? String ?? ""
            guard id.hasPrefix("VL") || type.contains("PLAYLIST") else { return nil }
            var title = ""
            if let meta = lockup["metadata"] as? [String: Any],
               let model = meta["lockupMetadataViewModel"] as? [String: Any] {
                title = text(model["title"])
            }
            guard !title.isEmpty else { return nil }
            var count: Int?
            if let meta = lockup["metadata"] as? [String: Any],
               let model = meta["lockupMetadataViewModel"] as? [String: Any],
               let content = model["metadata"] as? [String: Any],
               let rows = content["contentMetadataViewModel"] as? [String: Any],
               let metadataRows = rows["metadataRows"] as? [[String: Any]] {
                for row in metadataRows {
                    for part in (row["metadataParts"] as? [[String: Any]]) ?? [] {
                        let line = text(part["text"])
                        if let number = Int(line.replacingOccurrences(of: ",", with: "")
                            .filter("0123456789".contains)), number > 0 {
                            count = number
                        }
                    }
                }
            }
            return YTPlaylist(id: id, title: title,
                              thumbnail: firstThumbnail(in: lockup), count: count)
        }
        // Legacy shapes.
        for (key, idField) in [("gridPlaylistRenderer", "playlistId"),
                               ("playlistRenderer", "playlistId"),
                               ("radioRenderer", "playlistId")] {
            if let renderer = dict[key] as? [String: Any],
               let id = renderer[idField] as? String, id.hasPrefix("VL") || id.hasPrefix("PL") {
                let title = text(renderer["title"])
                guard !title.isEmpty else { return nil }
                let countText = text(renderer["videoCountText"])
                let count = Int(countText.filter("0123456789".contains))
                return YTPlaylist(id: id.hasPrefix("VL") ? id : "VL" + id,
                                  title: title,
                                  thumbnail: firstThumbnail(in: renderer),
                                  count: count)
            }
        }
        return nil
    }

    /// First (largest) thumbnail anywhere inside a renderer — playlist lockups
    /// carry their cover image in a nested image model, shape varies.
    private static func firstThumbnail(in value: Any) -> URL? {
        var best: (Int, URL)?
        walk(value) { dict in
            guard let thumbs = dict["thumbnails"] as? [[String: Any]] else { return }
            for thumb in thumbs {
                guard let urlString = thumb["url"] as? String else { continue }
                // Movie poster URLs are for films, skip any stray match.
                guard !urlString.contains("movieposter") else { continue }
                let width = thumb["width"] as? Int ?? 0
                let url = urlString.hasPrefix("http") ? URL(string: urlString)
                    : URL(string: "https:\(urlString)")
                if let url, best == nil || width > best!.0 {
                    best = (width, url)
                }
            }
        }
        return best?.1
    }

    private static func text(_ value: Any?) -> String {
        guard let value else { return "" }
        if let dict = value as? [String: Any] {
            if let simple = dict["simpleText"] as? String { return simple }
            if let runs = dict["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
            if let content = dict["content"] as? String { return content }
        } else if let string = value as? String {
            return string
        }
        return ""
    }
}
