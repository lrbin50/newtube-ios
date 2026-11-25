import Foundation

// MARK: - Films (Movies storefront)
//
// Loads the YouTube movies storefront (`FEstorefront`, TVHTML5 client) and
// groups it into titled shelves. Movie tiles are the new `tileRenderer` shape
// with the poster image, genre • year line, price badge (Buy or rent / Buy /
// Free with ads), rating badge and runtime. Signed-in requests also unlock
// the "Free with ads" tab, which is empty for anonymous callers.

struct MovieItem: Identifiable, Equatable {
    /// Video id of the movie (playable via the normal player).
    let id: String
    var title: String
    var poster: URL?
    /// "Action & adventure • 2026" style info line.
    var info: String?
    /// Price/availability badge, e.g. "Free with ads", "Buy or rent".
    var badge: String?
    /// Age rating badge, e.g. "PG-13".
    var rating: String?
    /// Runtime text, e.g. "1:54:49".
    var duration: String?
}

struct MovieSection: Identifiable, Equatable {
    let id: String
    var title: String
    var movies: [MovieItem]
}

enum MoviesTab: String, CaseIterable, Identifiable {
    case browse, free, live, purchases, store

    var id: String { rawValue }

    /// Server-issued browse params captured from the storefront's own tab
    /// endpoints (`ogUCKA*` selects the storefront sub-feed).
    var params: String {
        switch self {
        case .browse: return "ogUCKAU="
        case .free: return "ogUCKAY="
        case .live: return "ogUCKAg="
        case .purchases: return "ogUCKAQ="
        case .store: return "ogUCKAc="
        }
    }
}

@MainActor final class MoviesStore: ObservableObject {
    static let shared = MoviesStore()

    @Published private(set) var sections: [MovieSection] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvClientVersion = "7.20260311.12.00"

    func load(tab: MoviesTab, force: Bool = false) async {
        loading = true
        message = nil
        defer { loading = false }
        // Anonymous browsing works; a token additionally unlocks the
        // "Free with ads" feed for signed-in users.
        let token = try? await Account.shared.validToken()
        let json = try? await browse(tab: tab, token: token)
        let parsed = Self.parse(json ?? [:])
        if parsed.isEmpty {
            message = L10n.tr("movies.empty", fallback: "No movies here yet.")
        }
        sections = parsed
    }

    private func browse(tab: MoviesTab, token: String?) async throws -> [String: Any]? {
        var body: [String: Any] = [
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
            "browseId": "FEstorefront"
        ]
        // Sub-tabs (Free with ads, Store…) are selected by a server-issued
        // params value; the default Browse tab needs none.
        if tab != .browse { body["params"] = tab.params }
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
                         forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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

    static func parse(_ json: [String: Any]) -> [MovieSection] {
        var sections: [MovieSection] = []
        var shelves: [(title: String, movies: [MovieItem])] = []

        func collectShelves(_ value: Any) {
            guard let dict = value as? [String: Any] else { return }
            if let shelf = dict["shelfRenderer"] as? [String: Any] {
                let title = shelfTitle(shelf)
                var movies: [MovieItem] = []
                collectMovieTiles(shelf) { movies.append($0) }
                if !movies.isEmpty {
                    shelves.append((title, movies))
                }
                return
            }
            for child in dict.values { collectShelves(child) }
        }
        collectShelves(json)

        for shelf in shelves {
            let title = shelf.title.isEmpty
                ? L10n.tr("movies.more", fallback: "More")
                : shelf.title
            // De-duplicate shelves that repeat on the storefront.
            if let existing = sections.firstIndex(where: { $0.title == title }) {
                var movies = sections[existing].movies
                let known = Set(movies.map { $0.id })
                for movie in shelf.movies where !known.contains(movie.id) {
                    movies.append(movie)
                }
                sections[existing].movies = movies
            } else {
                sections.append(MovieSection(id: title, title: title, movies: shelf.movies))
            }
        }
        return sections
    }

    private static func shelfTitle(_ shelf: [String: Any]) -> String {
        // Title lives in headerRenderer.shelfHeaderRenderer inside either an
        // avatarLockupRenderer or a plain title field.
        if let header = shelf["headerRenderer"] as? [String: Any],
           let shelfHeader = header["shelfHeaderRenderer"] as? [String: Any] {
            if let lockup = shelfHeader["avatarLockup"] as? [String: Any],
               let lockupRenderer = lockup["avatarLockupRenderer"] as? [String: Any] {
                let title = text(lockupRenderer["title"])
                if !title.isEmpty { return title }
            }
            let title = text(shelfHeader["title"])
            if !title.isEmpty { return title }
        }
        return text(shelf["title"])
    }

    private static func collectMovieTiles(_ value: Any, into handler: (MovieItem) -> Void) {
        if let dict = value as? [String: Any] {
            if let tile = dict["tileRenderer"] as? [String: Any],
               tile["contentType"] as? String == "TILE_CONTENT_TYPE_VIDEO",
               let id = tile["contentId"] as? String, id.count == 11,
               let movie = movie(from: tile, id: id) {
                handler(movie)
            }
            for child in dict.values { collectMovieTiles(child, into: handler) }
        } else if let array = value as? [Any] {
            for child in array { collectMovieTiles(child, into: handler) }
        }
    }

    /// Movies nest their metadata inside `header.tileHeaderRenderer`:
    /// the poster in `thumbnail.thumbnails` (portrait movieposter_*.jpg),
    /// title/lines in `thumbnailOverlays[0].tileMetadataRenderer`, and the
    /// runtime in a later `thumbnailOverlayTimeStatusRenderer`.
    private static func movie(from tile: [String: Any], id: String) -> MovieItem? {
        guard let header = tile["header"] as? [String: Any],
              let tileHeader = header["tileHeaderRenderer"] as? [String: Any]
        else { return nil }

        var poster: URL?
        if let thumbnail = tileHeader["thumbnail"] as? [String: Any],
           let thumbs = thumbnail["thumbnails"] as? [[String: Any]] {
            let best = thumbs.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
            if let urlString = best?["url"] as? String {
                poster = URL(string: urlString)
            }
        }

        var title = ""
        var info: String?
        var badge: String?
        var rating: String?
        var duration: String?
        if let overlays = tileHeader["thumbnailOverlays"] as? [[String: Any]] {
            for overlay in overlays {
                if let metadata = overlay["tileMetadataRenderer"] as? [String: Any] {
                    title = text(metadata["title"])
                    if let lines = metadata["lines"] as? [[String: Any]] {
                        var lineTexts: [String] = []
                        for line in lines {
                            let items = (line["lineRenderer"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
                            let joined = items.compactMap { item -> String? in
                                guard let itemRenderer = item["lineItemRenderer"] as? [String: Any] else { return nil }
                                if let badgeDict = itemRenderer["badge"] as? [String: Any],
                                   let badgeRenderer = badgeDict["metadataBadgeRenderer"] as? [String: Any] {
                                    return text(badgeRenderer["label"])
                                }
                                let s = text(itemRenderer["text"])
                                return s.isEmpty ? nil : s
                            }.joined(separator: " • ")
                            if !joined.isEmpty { lineTexts.append(joined) }
                        }
                        // Line 1: "Genre • Year". Line 2: price badge(s) • rating.
                        if lineTexts.count > 0 { info = lineTexts[0] }
                        if lineTexts.count > 1 {
                            let badgeParts = lineTexts[1].split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
                            let ratings = ["G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-G", "TV-PG",
                                           "TV-14", "TV-MA", "Unrated", "NR"]
                            for part in badgeParts {
                                if ratings.contains(part) { rating = part }
                                else if badge == nil { badge = part }
                            }
                        }
                    }
                }
                if let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any],
                   let runtime = status["text"] as? [String: Any],
                   let simple = runtime["simpleText"] as? String {
                    duration = simple
                }
            }
        }
        // Older rollouts keep metadata in the usual `metadata` field.
        if title.isEmpty, let metadata = tile["metadata"] as? [String: Any],
           let tileMetadata = metadata["tileMetadataRenderer"] as? [String: Any] {
            title = text(tileMetadata["title"])
            if info == nil, let lines = tileMetadata["lines"] as? [[String: Any]], !lines.isEmpty {
                var texts: [String] = []
                for line in lines {
                    let items = (line["lineRenderer"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
                    let joined = items.compactMap { item -> String? in
                        guard let itemRenderer = item["lineItemRenderer"] as? [String: Any] else { return nil }
                        if let badgeDict = itemRenderer["badge"] as? [String: Any],
                           let badgeRenderer = badgeDict["metadataBadgeRenderer"] as? [String: Any] {
                            return text(badgeRenderer["label"])
                        }
                        let s = text(itemRenderer["text"])
                        return s.isEmpty ? nil : s
                    }.joined(separator: " • ")
                    if !joined.isEmpty { texts.append(joined) }
                }
                if texts.count > 0 { info = texts[0] }
                if texts.count > 1 {
                    let parts = texts[1].split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
                    let ratings = ["G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-G", "TV-PG",
                                   "TV-14", "TV-MA", "Unrated", "NR"]
                    for part in parts {
                        if ratings.contains(part) { rating = part }
                        else if badge == nil { badge = part }
                    }
                }
            }
        }
        guard !title.isEmpty else { return nil }
        return MovieItem(id: id, title: title, poster: poster,
                         info: info, badge: badge, rating: rating, duration: duration)
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
