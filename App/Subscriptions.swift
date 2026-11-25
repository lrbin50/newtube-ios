import Foundation

/// A subscribed channel shown in the horizontal filter bar.
struct FeedChannel: Identifiable, Equatable {
    let id: String          // "UC..." for real channels, "name:..." fallback
    var name: String
    var avatarURL: URL?
}

/// Data source for the Subscriptions tab. Loads the signed-in user's channel
/// list plus their latest videos, and can filter to a single channel by
/// browsing that channel's UC id. Parsing is structure-agnostic on purpose:
/// InnerTube moves channel data between renderers on every rollout.
@MainActor final class SubscriptionsStore: ObservableObject {
    static let shared = SubscriptionsStore()

    @Published private(set) var channels: [FeedChannel] = []
    @Published private(set) var videos: [FeedVideo] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var message: String?
    @Published private(set) var selectedChannelId = "all"

    private var continuation: String?

    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let agent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
    private let clientVersion = "7.20261123.19.00"

    private func context() -> [String: Any] {
        [
            "client": [
                "clientName": "TVHTML5", "clientVersion": clientVersion,
                "hl": "en", "gl": "US", "platform": "TV",
                "clientFormFactor": "UNKNOWN_FORM_FACTOR"
            ],
            "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
            "request": ["useSsl": true, "internalExperimentFlags": []]
        ]
    }

    // MARK: - Loading

    func load(force: Bool = false) async {
        if !force && !videos.isEmpty { return }
        selectedChannelId = "all"
        await loadFeed(browseId: "FEsubscriptions")
    }

    func select(_ id: String) async {
        guard selectedChannelId != id else { return }
        selectedChannelId = id
        videos = []
        continuation = nil
        message = nil
        if id == "all" {
            await loadFeed(browseId: "FEsubscriptions")
            return
        }
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        if channel.id.hasPrefix("UC") {
            await loadFeed(browseId: channel.id)
        } else {
            // Fallback channel built from a video byline (no UC id): use a
            // public search with the channel name as the query.
            await loadSearch(query: channel.name)
        }
    }

    func loadMore() async {
        guard !loadingMore, let cont = continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        let token = try? await Account.shared.validToken()
        guard let json = try? await post(endpoint: "browse",
                                         body: ["context": context(), "continuation": cont],
                                         token: token) else { return }
        let page = Feed.parse(json)
        merge(page)
    }

    private func loadFeed(browseId: String) async {
        loading = true
        defer { loading = false }
        let token = try? await Account.shared.validToken()
        guard let json = try? await post(endpoint: "browse",
                                         body: ["context": context(), "browseId": browseId],
                                         token: token) else {
            if videos.isEmpty { message = FeedError.badResponse.errorDescription }
            return
        }
        let page = Feed.parse(json)
        videos = page.videos
        continuation = page.continuation
        message = videos.isEmpty ? FeedError.badResponse.errorDescription : nil
        let parsed = Self.extractChannels(json)
        if !parsed.isEmpty { channels = parsed }
        else if browseId == "FEsubscriptions" { channels = Self.channelsFromVideos(page.videos) }
        resolveChannelAvatars()
    }

    /// Kick off deferred avatar resolution for the channel strip once videos are
    /// available. Runs on low-priority tasks via ChannelAvatarStore so it never
    /// slows down the video grid; results are shared with the home feed.
    private func resolveChannelAvatars() {
        guard !videos.isEmpty else { return }
        for channel in channels {
            let sample = videos.first { $0.channel == channel.name }?.id
            ChannelAvatarStore.shared.load(channel: channel.name, sampleVideoID: sample)
        }
    }

    func loadSearch(query: String) async {
        loading = true
        defer { loading = false }
        let body: [String: Any] = ["context": context(), "query": query]
        guard let json = try? await post(endpoint: "search", body: body, token: nil) else {
            if videos.isEmpty { message = FeedError.badResponse.errorDescription }
            return
        }
        let page = Feed.parse(json)
        videos = page.videos
        continuation = page.continuation
        message = videos.isEmpty ? FeedError.badResponse.errorDescription : nil
    }

    private func merge(_ page: FeedPage) {
        var seen = Set(videos.map { $0.id })
        for video in page.videos where seen.insert(video.id).inserted {
            videos.append(video)
        }
        continuation = page.continuation
    }

    // MARK: - Network

    private func post(endpoint: String, body: [String: Any],
                      token: String?) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?key=\(apiKey)&prettyPrint=false")
        else { throw FeedError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("7", forHTTPHeaderField: "X-YOUTUBE-CLIENT-NAME")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YOUTUBE-CLIENT-VERSION")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await LegacyNetwork.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FeedError.badResponse }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FeedError.badResponse }
        return json
    }

    // MARK: - Parsing

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

    private static func thumbnailURL(_ value: Any?) -> URL? {
        guard let dict = value as? [String: Any] else { return nil }
        let thumbs = (dict["thumbnails"] as? [[String: Any]])
            ?? (dict["sources"] as? [[String: Any]])
        guard let last = thumbs?.last, let url = last["url"] as? String else { return nil }
        return URL(string: url)
    }

    /// Deep-walks the subscriptions response for channel cards in any of the
    /// shapes InnerTube currently uses. Keeps the first name seen per UC id.
    static func extractChannels(_ json: [String: Any]) -> [FeedChannel] {
        var found: [String: FeedChannel] = [:]

        func collect(_ value: Any) {
            guard let dict = value as? [String: Any] else {
                if let array = value as? [Any] { for child in array { collect(child) } }
                return
            }

            if let renderer = dict["channelRenderer"] as? [String: Any],
               let cid = renderer["channelId"] as? String, cid.hasPrefix("UC") {
                let name = text(renderer["title"])
                if !name.isEmpty {
                    found[cid] = FeedChannel(id: cid, name: name,
                                             avatarURL: thumbnailURL(renderer["thumbnail"]))
                }
            }

            var cid: String?
            var name: String?
            var avatar: Any?
            if let lockup = dict["lockupViewModel"] as? [String: Any],
               let contentId = lockup["contentId"] as? String, contentId.hasPrefix("UC") {
                cid = contentId
                let meta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
                name = text(meta?["title"])
                avatar = lockup["image"]
            } else if let tile = dict["tileRenderer"] as? [String: Any],
                      let contentId = tile["contentId"] as? String, contentId.hasPrefix("UC") {
                let type = tile["contentType"] as? String ?? ""
                if type.contains("CHANNEL") {
                    cid = contentId
                    let meta = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
                    name = text(meta?["title"])
                    avatar = tile["image"]
                }
            }
            if let cid, let name, !name.isEmpty {
                if found[cid] == nil || found[cid]?.avatarURL == nil {
                    found[cid] = FeedChannel(id: cid, name: name, avatarURL: thumbnailURL(avatar))
                }
            }

            for child in dict.values { collect(child) }
        }

        collect(json)
        return Array(found.values)
    }

    /// If the server response carries no explicit channel cards, derive the
    /// filter list from the bylines of the loaded videos so the bar is useful.
    static func channelsFromVideos(_ videos: [FeedVideo]) -> [FeedChannel] {
        var seen = Set<String>()
        var result: [FeedChannel] = []
        for video in videos {
            guard let name = video.channel, !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(FeedChannel(id: "name:\(name)", name: name, avatarURL: nil))
        }
        return Array(result.prefix(30))
    }
}
