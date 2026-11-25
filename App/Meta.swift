import Foundation

/// Extra information shown on the player page: channel, view count, likes and
/// the "Up next" list. Fetched from YouTube's public endpoints so no account
/// or OAuth is required. Everything degrades gracefully to empty values.
struct VideoMeta {
    var author: String?
    var authorURL: URL?
    var channelID: String?
    var avatarURL: URL?
    var bannerURL: URL?
    var views: String?
    var likes: String?
    var published: String?
    var subscribers: String?
    var comments: String?
}

/// Supplies real channel avatars across the whole app. Feed payloads (`tileRenderer`,
/// `lockupViewModel`) carry no avatar, so this resolves one on demand via the
/// anonymous TV `next` endpoint (same one `Meta.load` uses) and caches it by both
/// channel name and video id. Because the cache is keyed by channel NAME too, an
/// avatar already resolved on the home feed is instantly reused by the
/// subscriptions strip/cards with zero extra network requests. Concurrent
/// lookups for the same key are coalesced; failures degrade to the initial
/// placeholder and are not retried during the session.
@MainActor final class ChannelAvatarStore: ObservableObject {
    static let shared = ChannelAvatarStore()

    /// channel name -> resolved avatar URL (shared between home + subscriptions).
    @Published private(set) var byChannel: [String: URL] = [:]
    /// video id -> resolved avatar URL (fallback when the channel name is unknown).
    @Published private(set) var avatars: [String: URL] = [:]

    private var attemptedVideos = Set<String>()
    private var attemptedChannels = Set<String>()
    private var inflightVideos: [String: Task<Void, Never>] = [:]
    private var inflightChannels: [String: Task<Void, Never>] = [:]

    /// Feed card lookup by video id. If the channel name is known we first reuse
    /// a previously resolved avatar, and after resolving we also index it by
    /// name so every other card/chip of that channel benefits immediately.
    func load(video id: String, channel: String? = nil) {
        if let name = channel, let cached = byChannel[name] {
            if avatars[id] == nil { avatars[id] = cached }
            return
        }
        guard avatars[id] == nil, !attemptedVideos.contains(id), inflightVideos[id] == nil else { return }
        attemptedVideos.insert(id)
        let task = Task(priority: .utility) { [weak self] in
            let url = await Meta.channelAvatar(for: id)
            guard let self = self else { return }
            if let url = url {
                self.avatars[id] = url
                if let name = channel { self.byChannel[name] = url }
            }
            self.inflightVideos[id] = nil
        }
        inflightVideos[id] = task
    }

    /// Subscription chip lookup by channel name. A representative video id is
    /// used only for the `next` request; results are shared with every other
    /// surface. Safe to call from every chip's `.onAppear`.
    func load(channel name: String, sampleVideoID: String?) {
        if byChannel[name] != nil { return }
        guard !name.isEmpty, !attemptedChannels.contains(name), inflightChannels[name] == nil else { return }
        guard let id = sampleVideoID, id.count == 11 else { return } // not ready yet; retry on next appearance
        attemptedChannels.insert(name)
        let task = Task(priority: .utility) { [weak self] in
            let url = await Meta.channelAvatar(for: id)
            guard let self = self else { return }
            if let url = url {
                self.byChannel[name] = url
                self.avatars[id] = url
            }
            self.inflightChannels[name] = nil
        }
        inflightChannels[name] = task
    }

    /// Synchronous read used by views to pick the best available avatar.
    func avatar(channel: String?, forVideo id: String) -> URL? {
        if let name = channel, let url = byChannel[name] { return url }
        return avatars[id]
    }
}

enum Meta {
    private static let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private static let agent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    /// Lightweight, anonymous avatar lookup for a single video. Reuses the TV
    /// `next` payload and picks the largest owner thumbnail.
    static func channelAvatar(for id: String) async -> URL? {
        guard let json = try? await post("next", body: [
            "context": ["client": [
                "clientName": "TVHTML5", "clientVersion": "7.20261123.19.00",
                "hl": "en", "gl": "US", "platform": "TV"
            ]],
            "videoId": id
        ]) else { return nil }
        var found: URL?
        func walk(_ value: Any) {
            guard found == nil else { return }
            if let dict = value as? [String: Any] {
                if let owner = dict["videoOwnerRenderer"] as? [String: Any],
                   let url = largestThumb(owner["thumbnail"]) {
                    found = url
                    return
                }
                for child in dict.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(json)
        return found
    }

    private static func largestThumb(_ value: Any?) -> URL? {
        guard let d = value as? [String: Any],
              let thumbs = d["thumbnails"] as? [[String: Any]] else { return nil }
        let best = thumbs.max { a, b in
            (a["width"] as? Int ?? 0) < (b["width"] as? Int ?? 0)
        }
        guard let raw = best?["url"] as? String else { return nil }
        return URL(string: raw)
    }

    static func load(_ video: Video) async -> VideoMeta {
        var meta = VideoMeta()

        // oEmbed gives a clean channel name without signing in.
        if var comps = URLComponents(string: "https://www.youtube.com/oembed") {
            comps.queryItems = [
                .init(name: "url", value: "https://www.youtube.com/watch?v=\(video.id)"),
                .init(name: "format", value: "json")
            ]
            if let url = comps.url,
               let (data, response) = try? await LegacyNetwork.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                meta.author = json["author_name"] as? String
                if let link = json["author_url"] as? String { meta.authorURL = URL(string: link) }
            }
        }

        // Player endpoint supplies view count, likes and publish date.
        if let json = try? await post("player", body: [
            "context": ["client": [
                "clientName": "ANDROID", "clientVersion": "20.10.38", "androidSdkVersion": 30
            ]],
            "videoId": video.id
        ]) {
            if let details = json["videoDetails"] as? [String: Any] {
                if meta.author == nil { meta.author = details["author"] as? String }
                if let raw = details["viewCount"] as? String { meta.views = formatted(raw) }
                if let raw = details["commentCount"] as? String { meta.comments = formattedBare(raw) }
            }
            if let micro = json["microformat"] as? [String: Any],
               let renderer = micro["playerMicroformatRenderer"] as? [String: Any] {
                meta.published = renderer["publishDate"] as? String
                if let raw = renderer["likeCount"] as? String { meta.likes = formattedBare(raw) }
                if let raw = renderer["ownerChannelName"] as? String { meta.author = meta.author ?? raw }
            }
        }
        // TV `next` carries the real channel avatar, channel id and banner.
        // The Android client's next response no longer has videoOwnerRenderer,
        // so use TVHTML5 here (small payload, no account required).
        if let next = try? await post("next", body: [
            "context": ["client": [
                "clientName": "TVHTML5", "clientVersion": "7.20261123.19.00",
                "hl": "en", "gl": "US", "platform": "TV"
            ]],
            "videoId": video.id
        ]) {
            applyChannelInfo(next, to: &meta)
        }
        return meta
    }

    /// Deep-walks the `next` response for the video owner (avatar, channel id,
    /// subscriber count) and the channel banner. Structure differs across
    /// rollouts, so accept both the classic `videoOwnerRenderer` and the newer
    /// `compactChannelBarViewModel` shapes.
    private static func applyChannelInfo(_ json: [String: Any], to meta: inout VideoMeta) {
        func textOf(_ value: Any?) -> String {
            guard let value else { return "" }
            if let dict = value as? [String: Any] {
                if let simple = dict["simpleText"] as? String { return simple }
                if let runs = dict["runs"] as? [[String: Any]] {
                    return runs.compactMap { $0["text"] as? String }.joined()
                }
            }
            return ""
        }
        func largestURL(_ value: Any?) -> URL? {
            guard let dict = value as? [String: Any],
                  let thumbs = dict["thumbnails"] as? [[String: Any]] else { return nil }
            let best = thumbs.max { a, b in
                (a["width"] as? Int ?? 0) < (b["width"] as? Int ?? 0)
            }
            guard let raw = best?["url"] as? String else { return nil }
            return URL(string: raw)
        }
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let owner = dict["videoOwnerRenderer"] as? [String: Any] {
                    if meta.avatarURL == nil { meta.avatarURL = largestURL(owner["thumbnail"]) }
                    if meta.channelID == nil,
                       let endpoint = owner["navigationEndpoint"] as? [String: Any],
                       let browse = endpoint["browseEndpoint"] as? [String: Any],
                       let cid = browse["browseId"] as? String, cid.hasPrefix("UC") {
                        meta.channelID = cid
                    }
                    if meta.subscribers == nil {
                        let subs = textOf(owner["subscriberCountText"])
                        if !subs.isEmpty { meta.subscribers = subs }
                    }
                    if meta.author == nil {
                        let name = textOf(owner["title"])
                        if !name.isEmpty { meta.author = name }
                    }
                }
                if let header = dict["channelHeaderRenderer"] as? [String: Any],
                   meta.bannerURL == nil {
                    meta.bannerURL = largestURL(header["banner"])
                }
                for child in dict.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(json)
    }

    /// A handful of related videos, parsed from the public search endpoint.
    static func related(to video: Video) async -> [Video] {
        guard let json = try? await post("search", body: [
            "context": ["client": [
                "clientName": "ANDROID", "clientVersion": "20.10.38", "androidSdkVersion": 30
            ]],
            "query": video.title
        ]) else { return [] }

        var result: [Video] = []
        var seen = Set([video.id])
        collect(json, into: &result, seen: &seen, limit: 12)
        return result
    }

    private static func post(_ endpoint: String, body: [String: Any]) async throws -> [String: Any]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?key=\(apiKey)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await LegacyNetwork.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func collect(_ value: Any, into result: inout [Video], seen: inout Set<String>, limit: Int) {
        guard result.count < limit else { return }
        if let dict = value as? [String: Any] {
            // YouTube's Android client returns compactVideoRenderer for search
            // results; older clients use videoRenderer. Support both.
            var renderer = dict["compactVideoRenderer"] as? [String: Any]
            if renderer == nil { renderer = dict["videoRenderer"] as? [String: Any] }
            if let renderer, let id = renderer["videoId"] as? String, id.count == 11, !seen.contains(id) {
                var title = ""
                if let field = renderer["title"] as? [String: Any] {
                    if let runs = field["runs"] as? [[String: Any]] {
                        title = runs.compactMap { $0["text"] as? String }.joined()
                    } else {
                        title = (field["simpleText"] as? String) ?? ""
                    }
                }
                if !title.isEmpty {
                    seen.insert(id)
                    result.append(Video(id: id, title: title))
                }
            }
            for item in dict.values { collect(item, into: &result, seen: &seen, limit: limit) }
        } else if let array = value as? [Any] {
            for item in array { collect(item, into: &result, seen: &seen, limit: limit) }
        }
    }

    private static func formatted(_ raw: String) -> String? {
        guard let body = formattedBare(raw) else { return nil }
        let isZh = L10n.shared.effective == .simplifiedChinese
        return body + (isZh ? "次观看" : " views")
    }

    /// Compact number without a suffix (for likes/subscribers).
    private static func formattedBare(_ raw: String) -> String? {
        guard let value = Double(raw) else { return nil }
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return "\(Int(value))"
        }
    }
}
