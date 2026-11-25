import Foundation

// MARK: - Native home feed
//
// Fetches the signed-in personalized home via InnerTube `browse` with
// `FEwhat_to_watch`, using the TV client context + bearer token (the same
// combination native clients use). Parsing is deliberately structure-agnostic:
// YouTube ships videos under videoRenderer / richItemRenderer / tileRenderer /
// lockupViewModel depending on client and rollout, so we deep-walk the JSON and
// pull out any object that looks like a video. A disk cache gives instant cold
// starts and survives a failed refresh.

struct FeedVideo: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var channel: String?
    var views: String?
    var duration: String?
    var published: String?

    var thumbnailURL: URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }
    var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }
    var video: Video { Video(id: id, title: title) }
}

/// One home-feed category chip. `params` is the opaque browse parameter the
/// server ships with the current home response; when it is unavailable we
/// fall back to a public TV search for `searchQuery`.
struct FeedChip: Identifiable, Codable, Equatable {
    var id: String { title }
    let title: String
    var params: String?
    var browseId: String?
    var searchQuery: String?
}

enum FeedMode: Equatable {
    case home
    case category(FeedChip)
    case subscriptions
    case search(String)
}

struct FeedPage {
    var videos: [FeedVideo]
    var continuation: String?
    var chips: [FeedChip] = []
}

enum FeedError: LocalizedError {
    case notSignedIn
    case badResponse
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to see your home feed"
        case .badResponse: return "Couldn't load the feed"
        }
    }
}

@MainActor final class Feed: ObservableObject {
    static let shared = Feed()

    @Published private(set) var videos: [FeedVideo] = []
    @Published private(set) var chips: [FeedChip] = Feed.defaultChips
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var message: String?
    @Published private(set) var mode: FeedMode = .home

    private var continuation: String?
    private let cacheFile: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("newtube-home-feed.json")
    }()
    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
    private let tvClientVersion = "7.20261123.19.00"

    /// Display order matches the YouTube phone/tablet home chips. Titles are
    /// kept in English and localized by the view; `searchQuery` is the fallback
    /// used when the server did not hand us a browse `params` for that chip.
    static let defaultChips: [FeedChip] = [
        FeedChip(title: "All", searchQuery: nil),
        FeedChip(title: "Music", searchQuery: "music"),
        FeedChip(title: "Podcasts", searchQuery: "podcasts"),
        FeedChip(title: "Mixes", searchQuery: "mixes"),
        FeedChip(title: "Live", searchQuery: "live"),
        FeedChip(title: "Travel", searchQuery: "travel"),
        FeedChip(title: "Recently uploaded", searchQuery: "recently uploaded"),
        FeedChip(title: "Watched", searchQuery: "watched"),
        FeedChip(title: "New to you", searchQuery: "new to you")
    ]

    /// Loads a mode. Home shows cached results instantly, then refreshes.
    func load(_ next: FeedMode, force: Bool = false) async {
        mode = next
        videos = []
        continuation = nil
        message = nil
        if next == .home { loadCache() }
        let token = try? await Account.shared.validToken()
        // Only personalized feeds require a token; categories and searches
        // are public and must still work if token refresh transiently fails.
        if token == nil && (next == .home || next == .subscriptions) {
            if videos.isEmpty { message = FeedError.notSignedIn.errorDescription }
            return
        }
        await refresh(token: token, continuation: nil)
    }

    func loadMore() async {
        guard !loadingMore, let cont = continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        let token = try? await Account.shared.validToken()
        guard let page = try? await request(token: token, continuation: cont) else { return }
        merge(page)
    }

    private func refresh(token: String?, continuation: String?) async {
        loading = true
        defer { loading = false }
        guard let page = try? await request(token: token, continuation: continuation) else {
            // A server-issued category `params` can expire. Never leave the
            // chip stuck on an error: retry the same category as a public
            // TV search (no bearer token — that combination returns 401).
            if case .category(let chip) = mode, chip.params != nil,
               let fallback = try? await search(query: chip.searchQuery ?? chip.title, token: nil) {
                apply(fallback, continuation: continuation)
                return
            }
            if videos.isEmpty { message = FeedError.badResponse.errorDescription }
            return
        }
        apply(page, continuation: continuation)
    }

    private func apply(_ page: FeedPage, continuation: String?) {
        message = nil
        if continuation == nil {
            videos = page.videos
            self.continuation = page.continuation
            if mode == .home {
                saveCache(page.videos)
                // Pick up the freshest chip params the server gave us.
                if !page.chips.isEmpty { chips = Self.mergeChips(page.chips) }
            }
        } else {
            merge(page)
        }
    }

    private func merge(_ page: FeedPage) {
        var seen = Set(videos.map { $0.id })
        for video in page.videos where seen.insert(video.id).inserted {
            videos.append(video)
        }
        continuation = page.continuation
    }

    // MARK: - Network

    private func request(token: String?, continuation: String?) async throws -> FeedPage? {
        switch mode {
        case .home, .subscriptions:
            return try await browse(token: token, continuation: continuation)
        case .category(let chip):
            if continuation != nil {
                return try await browse(token: token, continuation: continuation)
            }
            if let params = chip.params {
                return try await browse(token: token, continuation: nil,
                                        params: params,
                                        browseId: chip.browseId ?? "FEwhat_to_watch")
            }
            // No server params: public TV search. The OAuth token belongs to
            // the TV client, so sending it with an ANDROID search yields 401.
            return try await search(query: chip.searchQuery ?? chip.title, token: nil)
        case .search(let query):
            if continuation != nil { return nil }
            return try await search(query: query, token: nil)
        }
    }

    private func context(clientName: String, clientVersion: String, platform: Bool) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName, "clientVersion": clientVersion,
            "hl": "en", "gl": "US"
        ]
        if platform {
            client["platform"] = "TV"
            client["clientFormFactor"] = "UNKNOWN_FORM_FACTOR"
        }
        var ctx: [String: Any] = ["client": client]
        if platform {
            ctx["user"] = ["enableSafetyMode": false, "lockedSafetyMode": false]
            ctx["request"] = ["useSsl": true, "internalExperimentFlags": []]
        }
        return ctx
    }

    private func browse(token: String?, continuation: String?,
                        params: String? = nil,
                        browseId: String? = nil) async throws -> FeedPage? {
        var body: [String: Any] = ["context": context(clientName: "TVHTML5",
                                                      clientVersion: tvClientVersion,
                                                      platform: true)]
        if let cont = continuation {
            body["continuation"] = cont
        } else {
            body["browseId"] = browseId ?? (mode == .subscriptions ? "FEsubscriptions" : "FEwhat_to_watch")
            if let params = params { body["params"] = params }
        }
        return try await post(endpoint: "browse", body: body, token: token, agent: tvAgent,
                              extraHeaders: [
                                "X-YOUTUBE-CLIENT-NAME": "7",
                                "X-YOUTUBE-CLIENT-VERSION": tvClientVersion
                              ])
    }

    private func search(query: String, token: String?) async throws -> FeedPage? {
        // TVHTML5 search works anonymously and returns `lockupViewModel`
        // entries the parser understands. Keep it token-free on purpose.
        let body: [String: Any] = [
            "context": context(clientName: "TVHTML5", clientVersion: tvClientVersion, platform: true),
            "query": query
        ]
        return try await post(endpoint: "search", body: body, token: token, agent: tvAgent,
                              extraHeaders: [
                                "X-YOUTUBE-CLIENT-NAME": "7",
                                "X-YOUTUBE-CLIENT-VERSION": tvClientVersion
                              ])
    }

    private func post(endpoint: String, body: [String: Any], token: String?,
                      agent: String, extraHeaders: [String: String]) async throws -> FeedPage? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?key=\(apiKey)&prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await LegacyNetwork.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.parse(json)
    }

    // MARK: - Parsing (structure-agnostic deep walk)

    static func parse(_ json: [String: Any]) -> FeedPage {
        var found: [FeedVideo] = []
        var seen = Set<String>()
        var tokens: [String] = []
        walk(json, into: &found, seen: &seen, tokens: &tokens)
        // YouTube carries continuation tokens in several shapes depending on
        // client/rollout. The main feed's token is typically the longest one.
        let cont = tokens.filter { $0.count > 40 }.max { $0.count < $1.count }
        return FeedPage(videos: found, continuation: cont, chips: extractChips(json))
    }

    private static func walk(_ value: Any, into result: inout [FeedVideo],
                             seen: inout Set<String>, tokens: inout [String]) {
        if let dict = value as? [String: Any] {
            if let video = video(from: dict), seen.insert(video.id).inserted {
                result.append(video)
            }
            // Collect every known continuation shape; parse() picks the main one.
            if let cmd = dict["continuationCommand"] as? [String: Any],
               let token = cmd["token"] as? String { tokens.append(token) }
            if let token = dict["continuation"] as? String { tokens.append(token) }
            for key in ["nextContinuationData", "reloadContinuationData"] {
                if let data = dict[key] as? [String: Any],
                   let token = data["continuation"] as? String { tokens.append(token) }
            }
            for item in dict.values { walk(item, into: &result, seen: &seen, tokens: &tokens) }
        } else if let array = value as? [Any] {
            for item in array { walk(item, into: &result, seen: &seen, tokens: &tokens) }
        }
    }

    private static func video(from dict: [String: Any]) -> FeedVideo? {
        // New TVHTML5 home/channel format (2026): a `tileRenderer` carries the
        // video id in `contentId`, the title in `metadata.tileMetadataRenderer`,
        // and channel/views/date in that renderer's `lines`. No `*Renderer`
        // wrapper holds a `videoId` any more — this shape is what made the
        // feed render blank. Detect it first.
        if let tile = dict["tileRenderer"] as? [String: Any],
           let id = tile["contentId"] as? String, id.count == 11,
           let type = tile["contentType"] as? String, type.contains("VIDEO") {
            return tileVideo(tile, id: id)
        }
        // `lockupViewModel` (TV search / channel grids): contentId plus
        // lockup metadata. TVHTML5 labels normal videos as MUSIC as well as
        // VIDEO — accepting only VIDEO made every category chip look empty.
        if let lockup = dict["lockupViewModel"] as? [String: Any],
           let id = lockup["contentId"] as? String, id.count == 11 {
            let type = lockup["contentType"] as? String ?? "LOCKUP_CONTENT_TYPE_VIDEO"
            guard type.contains("VIDEO") || type.contains("MUSIC") else { return nil }
            var titleField: Any?
            var channel: String?
            var views: String?
            var published: String?
            if let meta = lockup["metadata"] as? [String: Any],
               let lock = meta["lockupMetadataViewModel"] as? [String: Any] {
                titleField = lock["title"]
                if let cm = lock["metadata"] as? [String: Any],
                   let model = cm["contentMetadataViewModel"] as? [String: Any],
                   let rows = model["metadataRows"] as? [[String: Any]] {
                    var lines: [String] = []
                    for row in rows {
                        let parts = row["metadataParts"] as? [[String: Any]] ?? []
                        let joined = parts.compactMap { part -> String? in
                            let s = text(part["text"])
                            return s.isEmpty ? nil : s
                        }.joined(separator: " ")
                        if !joined.isEmpty { lines.append(joined) }
                    }
                    channel = lines.first
                    if lines.count > 1 { views = lines[1] }
                    if lines.count > 2 { published = lines[2] }
                }
            }
            let title = text(titleField)
            guard !title.isEmpty else { return nil }
            return FeedVideo(id: id, title: title, channel: channel?.nilIfEmpty,
                             views: views?.nilIfEmpty, duration: nil,
                             published: published?.nilIfEmpty)
        }

        var renderer: [String: Any]?
        for key in ["videoRenderer", "compactVideoRenderer", "gridVideoRenderer",
                    "richItemRenderer", "playlistVideoRenderer"] {
            if let candidate = dict[key] as? [String: Any] { renderer = candidate; break }
        }
        var id: String?
        var titleField: Any?
        var byline: Any?
        var viewField: Any?
        var durationField: Any?
        var publishedField: Any?

        if let r = renderer {
            if let content = r["content"] as? [String: Any],
               let inner = content["videoRenderer"] as? [String: Any] {
                renderer = inner
            }
            let rr = renderer!
            id = rr["videoId"] as? String
            titleField = rr["title"]
            byline = rr["ownerText"] ?? rr["longBylineText"] ?? rr["shortBylineText"]
            viewField = rr["viewCountText"] ?? rr["shortViewCountText"]
            durationField = rr["lengthText"]
            publishedField = rr["publishedTimeText"]
        }
        guard let videoId = id, videoId.count == 11 else { return nil }
        let title = text(titleField)
        guard !title.isEmpty else { return nil }
        return FeedVideo(
            id: videoId, title: title,
            channel: text(byline).nilIfEmpty,
            views: text(viewField).nilIfEmpty,
            duration: text(durationField).nilIfEmpty,
            published: text(publishedField).nilIfEmpty
        )
    }

    /// Parses the new `tileRenderer` shape: title from tileMetadataRenderer,
    /// channel/views/date from its `lines`, duration from a header overlay.
    private static func tileVideo(_ tile: [String: Any], id: String) -> FeedVideo? {
        let meta = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
        let title = text(meta?["title"])
        guard !title.isEmpty else { return nil }

        var lineTexts: [String] = []
        if let lines = meta?["lines"] as? [[String: Any]] {
            for line in lines {
                let items = (line["lineRenderer"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
                let joined = items.compactMap { item -> String? in
                    guard let li = item["lineItemRenderer"] as? [String: Any] else { return nil }
                    var value = li["text"]
                    if value == nil, let badge = li["badge"] as? [String: Any],
                       let meta = badge["metadataBadgeRenderer"] as? [String: Any] {
                        value = meta["label"]
                    }
                    let s = text(value)
                    return s.isEmpty ? nil : s
                }.joined(separator: " ")
                if !joined.isEmpty { lineTexts.append(joined) }
            }
        }
        // First line is the channel; the second typically holds badges + views • date.
        let channel = lineTexts.first
        var views: String?
        var published: String?
        if lineTexts.count > 1 {
            let parts = lineTexts[1].split(separator: " ").map(String.init)
            // e.g. ["4K", "CC", "100M", "views", "•", "9", "days", "ago"]
            var viewTokens: [String] = []
            var dateTokens: [String] = []
            var afterBullet = false
            for part in parts {
                if part == "•" { afterBullet = true; continue }
                // Skip short quality/language badges such as 4K, CC, HD.
                if !afterBullet && part.count <= 3 && !part.lowercased().contains("view") {
                    if viewTokens.isEmpty { continue }
                }
                if afterBullet { dateTokens.append(part) }
                else { viewTokens.append(part) }
            }
            if viewTokens.contains(where: { $0.lowercased().contains("view") || $0 == "观看" }) {
                views = viewTokens.joined(separator: " ")
            }
            if !dateTokens.isEmpty { published = dateTokens.joined(separator: " ") }
        }

        var duration: String?
        if let header = tile["header"] as? [String: Any],
           let tileHeader = header["tileHeaderRenderer"] as? [String: Any],
           let overlays = tileHeader["thumbnailOverlays"] as? [[String: Any]] {
            for overlay in overlays {
                if let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any],
                   let s = status["text"] as? [String: Any], (s["simpleText"] as? String) != nil {
                    duration = text(s); break
                }
            }
        }
        return FeedVideo(id: id, title: title, channel: channel?.nilIfEmpty,
                         views: views, duration: duration, published: published)
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

    // MARK: - Category chips

    /// Pull the current category params out of the home response instead of
    /// hard-coding them: YouTube changes these server-side on every rollout.
    /// Only titles we actually display are accepted, which keeps unrelated
    /// navigation items (sidebar, footer) out of the chip bar.
    private static func extractChips(_ json: [String: Any]) -> [FeedChip] {
        let known = Set(defaultChips.map { $0.title })
        var found: [String: FeedChip] = [:]

        func collect(_ value: Any, title: String?) {
            if let dict = value as? [String: Any] {
                var currentTitle = title
                for key in ["title", "text", "content", "label"] {
                    let candidate = text(dict[key])
                    if !candidate.isEmpty { currentTitle = candidate; break }
                }
                var endpoint = dict["browseEndpoint"] as? [String: Any]
                if endpoint == nil, let command = dict["command"] as? [String: Any] {
                    endpoint = command["browseEndpoint"] as? [String: Any]
                }
                if endpoint == nil, let command = dict["innertubeCommand"] as? [String: Any] {
                    endpoint = command["browseEndpoint"] as? [String: Any]
                }
                if endpoint == nil,
                   let executor = dict["commandExecutorCommand"] as? [String: Any],
                   let commands = executor["commands"] as? [[String: Any]] {
                    for command in commands {
                        if let e = command["browseEndpoint"] as? [String: Any] {
                            endpoint = e
                            break
                        }
                        if let inner = command["innertubeCommand"] as? [String: Any],
                           let e = inner["browseEndpoint"] as? [String: Any] {
                            endpoint = e
                            break
                        }
                    }
                }
                if let e = endpoint, let params = e["params"] as? String, !params.isEmpty,
                   let chipTitle = currentTitle, known.contains(chipTitle), found[chipTitle] == nil {
                    found[chipTitle] = FeedChip(title: chipTitle, params: params,
                                                browseId: e["browseId"] as? String,
                                                searchQuery: nil)
                }
                for child in dict.values { collect(child, title: currentTitle) }
            } else if let array = value as? [Any] {
                for child in array { collect(child, title: title) }
            }
        }
        collect(json, title: nil)
        return Array(found.values)
    }

    /// Keep the canonical display order and fill any chip the server omitted
    /// with its public-search fallback, so the bar never changes shape.
    private static func mergeChips(_ remote: [FeedChip]) -> [FeedChip] {
        let byTitle = Dictionary(uniqueKeysWithValues: remote.map { ($0.title, $0) })
        return defaultChips.map { base in
            guard let fresh = byTitle[base.title] else { return base }
            return FeedChip(title: base.title, params: fresh.params,
                            browseId: fresh.browseId,
                            searchQuery: fresh.params == nil ? base.searchQuery : nil)
        }
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let items = try? JSONDecoder().decode([FeedVideo].self, from: data)
        else { return }
        videos = items
    }

    private func saveCache(_ items: [FeedVideo]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: cacheFile)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
