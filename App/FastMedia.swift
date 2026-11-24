import Foundation

/// Fast stream resolution via the public ANDROID InnerTube client.
///
/// YouTubeKit's `.local` extractor queries multiple web/TV clients and then
/// runs a heavy JavaScriptCore-based descrambler on-device (meriyah + AST
/// rewrite) to defeat signature + n-parameter throttling. On older devices
/// this costs several seconds of CPU per video.
///
/// The ANDROID player client instead returns ready-to-use progressive URLs
/// (no cipher, no n-parameter) in a single request — the same trick native
/// Android clients use. We try that first and keep YouTubeKit as a fallback.
enum FastMedia {
    private static let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private static let agent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    /// Two entries are enough: the video being played plus the next one.
    private static var cache: [String: (url: URL, at: Date)] = [:]
    private static let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 60 * 60

    private static func cached(_ id: String) -> URL? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let hit = cache[id], Date().timeIntervalSince(hit.at) < cacheTTL else { return nil }
        return hit.url
    }

    private static func store(_ url: URL, for id: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[id] = (url, Date())
        // Keep the cache small; drop entries older than TTL.
        if cache.count > 8 {
            cache = cache.filter { Date().timeIntervalSince($0.value.at) < cacheTTL }
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "Fast stream resolution unavailable." }
    }

    /// Returns a natively playable direct URL, or throws to fall back.
    static func resolve(_ videoID: String, audioOnly: Bool = false, download: Bool = false) async throws -> URL {
        if let hit = cached(videoID) { return hit }

        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "ANDROID",
                "clientVersion": "20.10.38",
                "androidSdkVersion": 30,
                "hl": "en", "gl": "US"
            ]],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LegacyNetwork.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streaming = json["streamingData"] as? [String: Any]
        else { throw Failure() }
        let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String
        guard status == "OK" else { throw Failure() }

        let formats = (streaming["formats"] as? [[String: Any]] ?? [])
            + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])

        // Only direct URLs — anything ciphered would need the JS descrambler.
        let direct = formats.filter { $0["url"] as? String != nil && $0["signatureCipher"] == nil }
        var chosen: [String: Any]?

        if audioOnly {
            chosen = direct
                .filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/mp4") }
                .max { bitrate($0) < bitrate($1) }
        } else if download {
            // A direct mp4 progressive stream is easiest to download.
            chosen = direct.first { ($0["mimeType"] as? String ?? "").hasPrefix("video/mp4") }
        } else {
            // Progressive (has both audio + video) that AVPlayer can decode:
            // itag 18 is avc1 + mp4a in an mp4 container — always present.
            chosen = direct.first { itag($0) == 18 }
            if chosen == nil {
                chosen = direct.first { ($0["mimeType"] as? String ?? "").hasPrefix("video/mp4")
                    && (($0["mimeType"] as? String ?? "").contains("avc1")) }
            }
        }

        guard let pick = chosen, let urlString = pick["url"] as? String, let url = URL(string: urlString)
        else { throw Failure() }

        store(url, for: videoID)
        return url
    }

    private static func itag(_ format: [String: Any]) -> Int? {
        format["itag"] as? Int ?? (format["itag"] as? NSNumber)?.intValue
    }

    private static func bitrate(_ format: [String: Any]) -> Int {
        format["bitrate"] as? Int ?? (format["bitrate"] as? NSNumber)?.intValue ?? 0
    }
}
