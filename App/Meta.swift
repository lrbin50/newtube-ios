import Foundation

/// Extra information shown on the player page: channel, view count, likes and
/// the "Up next" list. Fetched from YouTube's public endpoints so no account
/// or OAuth is required. Everything degrades gracefully to empty values.
struct VideoMeta {
    var author: String?
    var authorURL: URL?
    var views: String?
    var likes: String?
    var published: String?
    var subscribers: String?
    var comments: String?
}

enum Meta {
    private static let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private static let agent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

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
        return meta
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
