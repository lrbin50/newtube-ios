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

enum FeedMode: Equatable {
    case home
    case subscriptions
    case search(String)
}

struct FeedPage {
    var videos: [FeedVideo]
    var continuation: String?
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
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published private(set) var mode: FeedMode = .home

    private var continuation: String?
    private let cacheFile: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("newtube-home-feed.json")
    }()
    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    /// Loads a mode. Home shows cached results instantly, then refreshes.
    func load(_ next: FeedMode, force: Bool = false) async {
        mode = next
        videos = []
        continuation = nil
        message = nil
        if next == .home, videos.isEmpty { loadCache() }
        guard let token = try? await Account.shared.validToken() else {
            if videos.isEmpty { message = FeedError.notSignedIn.errorDescription }
            return
        }
        await refresh(token: token, continuation: nil)
    }

    func loadMore() async {
        guard let token = try? await Account.shared.validToken(),
              let cont = continuation else { return }
        guard let page = try? await request(token: token, continuation: cont) else { return }
        merge(page)
    }

    private func refresh(token: String, continuation: String?) async {
        loading = true
        defer { loading = false }
        guard let page = try? await request(token: token, continuation: continuation) else {
            if videos.isEmpty { message = FeedError.badResponse.errorDescription }
            return
        }
        message = nil
        if continuation == nil {
            videos = page.videos
            self.continuation = page.continuation
            if mode == .home { saveCache(page.videos) }
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

    private func request(token: String, continuation: String?) async throws -> FeedPage? {
        switch mode {
        case .home, .subscriptions:
            return try await browse(token: token, continuation: continuation)
        case .search(let query):
            // Search has no continuation here; only the first page is shown.
            if continuation != nil { return nil }
            return try await search(query: query, token: token)
        }
    }

    private func browse(token: String, continuation: String?) async throws -> FeedPage? {
        let context: [String: Any] = [
            "client": [
                "clientName": "TVHTML5",
                "clientVersion": "7.20260311.12.00",
                "hl": "en", "gl": "US",
                "platform": "TV",
                "clientFormFactor": "UNKNOWN_FORM_FACTOR"
            ],
            "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
            "request": ["useSsl": true, "internalExperimentFlags": []]
        ]
        var body: [String: Any] = ["context": context]
        if let cont = continuation {
            body["continuation"] = cont
        } else {
            body["browseId"] = mode == .subscriptions ? "FEsubscriptions" : "FEwhat_to_watch"
        }
        return try await post(endpoint: "browse", body: body, token: token, agent: tvAgent,
                              extraHeaders: [
                                "X-YOUTUBE-CLIENT-NAME": "7",
                                "X-YOUTUBE-CLIENT-VERSION": "7.20260311.12.00"
                              ])
    }

    private func search(query: String, token: String) async throws -> FeedPage? {
        let context: [String: Any] = [
            "client": [
                "clientName": "ANDROID", "clientVersion": "20.10.38",
                "androidSdkVersion": 30, "hl": "en", "gl": "US"
            ]
        ]
        let body: [String: Any] = ["context": context, "query": query]
        return try await post(endpoint: "search", body: body, token: token, agent: tvAgent, extraHeaders: [:])
    }

    private func post(endpoint: String, body: [String: Any], token: String,
                      agent: String, extraHeaders: [String: String]) async throws -> FeedPage? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?key=\(apiKey)&prettyPrint=false") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        var cont: String?
        walk(json, into: &found, seen: &seen, continuation: &cont)
        return FeedPage(videos: found, continuation: cont)
    }

    private static func walk(_ value: Any, into result: inout [FeedVideo],
                             seen: inout Set<String>, continuation: inout String?) {
        if let dict = value as? [String: Any] {
            if let video = video(from: dict), seen.insert(video.id).inserted {
                result.append(video)
            }
            if continuation == nil,
               let cmd = dict["continuationCommand"] as? [String: Any],
               let token = cmd["token"] as? String, !token.isEmpty {
                continuation = token
            }
            for item in dict.values { walk(item, into: &result, seen: &seen, continuation: &continuation) }
        } else if let array = value as? [Any] {
            for item in array { walk(item, into: &result, seen: &seen, continuation: &continuation) }
        }
    }

    private static func video(from dict: [String: Any]) -> FeedVideo? {
        var renderer: [String: Any]?
        for key in ["videoRenderer", "compactVideoRenderer", "gridVideoRenderer",
                    "richItemRenderer", "tileRenderer", "playlistVideoRenderer"] {
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
            } else if let header = r["header"] as? [String: Any],
                      let inner = header["tileHeaderRenderer"] as? [String: Any] {
                renderer = inner
            }
            let rr = renderer!
            id = rr["videoId"] as? String
            titleField = rr["title"]
            byline = rr["ownerText"] ?? rr["longBylineText"] ?? rr["shortBylineText"]
            viewField = rr["viewCountText"] ?? rr["shortViewCountText"]
            durationField = rr["lengthText"]
            publishedField = rr["publishedTimeText"]
        } else if let lockup = dict["lockupViewModel"] as? [String: Any] {
            id = lockup["contentId"] as? String
            if let meta = lockup["metadata"] as? [String: Any],
               let lock = meta["lockupMetadataViewModel"] as? [String: Any] {
                titleField = lock["title"]
            }
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
