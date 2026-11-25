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
///
/// The player request itself has a 1-6s server-side latency, so cards call
/// `prewarm()` as they appear on screen. That way tapping a video usually hits
/// the cache and playback starts immediately instead of waiting on the network.
enum FastMedia {
    private static let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private static let agent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    /// Keep a rolling window of resolved URLs. A cached hit is the ONLY way to
    /// skip the /player endpoint's 1-6s server latency, so this is deliberately
    /// much larger than the old "current + next" two entries.
    private static var cache: [String: (url: URL, at: Date)] = [:]
    /// Resolution already in flight — shared by prewarm and real playback.
    private static var inflight: [String: Task<URL, Error>] = [:]
    /// FIFO of ids waiting to be warmed. Capped concurrency avoids a flood of
    /// /player requests while a fast scroll fires dozens of onAppear callbacks.
    private static var warmQueue: [String] = []
    private static var warmActive = 0
    private static let lock = NSLock()
    private static let cacheTTL: TimeInterval = 6 * 60 * 60
    private static let cacheLimit = 30
    private static let warmLimit = 2

    struct Failure: LocalizedError {
        var errorDescription: String? { "Fast stream resolution unavailable." }
    }

    /// Fire-and-forget warm-up from a feed card. Safe to call repeatedly:
    /// duplicates are coalesced and only `warmLimit` requests run at once.
    /// Cards drain in onAppear (top-to-bottom scroll) order, so the videos
    /// nearest the top of the screen are warmed before ones further down.
    static func prewarm(_ videoID: String) {
        lock.lock()
        guard cache[videoID] == nil, inflight["v:\(videoID)"] == nil,
              !warmQueue.contains(videoID) else { lock.unlock(); return }
        warmQueue.append(videoID)
        let canStart = warmActive < warmLimit
        if canStart { warmActive += 1 }
        lock.unlock()
        if canStart { Task(priority: .utility) { await drainWarmQueue() } }
    }

    private static func drainWarmQueue() async {
        while true {
            lock.lock()
            guard let id = warmQueue.first else {
                warmActive -= 1
                lock.unlock()
                return
            }
            warmQueue.removeFirst()
            lock.unlock()
            _ = try? await resolve(id)
        }
    }

    /// Drop a URL that YouTube rejected (403 / dead stream) so playback can
    /// re-resolve a fresh one instead of retrying the same expired address.
    static func invalidate(_ videoID: String) {
        lock.lock()
        cache.removeValue(forKey: videoID)
        lock.unlock()
    }

    /// Returns a natively playable direct URL, or throws to fall back.
    static func resolve(_ videoID: String, audioOnly: Bool = false, download: Bool = false) async throws -> URL {
        // A warmed cache entry makes playback instantaneous.
        if !audioOnly && !download, let hit = cached(videoID) { return hit }

        let key = cacheKey(videoID, audioOnly: audioOnly, download: download)

        lock.lock()
        if let running = inflight[key] {
            lock.unlock()
            return try await running.value
        }
        // Whoever creates the task is responsible for clearing it, so a second
        // waiter finishing early cannot remove a task others still await.
        let task = Task<URL, Error> {
            defer {
                lock.lock()
                inflight[key] = nil
                lock.unlock()
            }
            let url = try await fetch(videoID, audioOnly: audioOnly, download: download)
            if !audioOnly && !download { store(url, for: videoID) }
            return url
        }
        inflight[key] = task
        lock.unlock()
        return try await task.value
    }

    private static func cacheKey(_ id: String, audioOnly: Bool, download: Bool) -> String {
        if audioOnly { return "a:\(id)" }
        if download { return "d:\(id)" }
        return "v:\(id)"
    }

    private static func cached(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[id], Date().timeIntervalSince(hit.at) < cacheTTL else { return nil }
        return hit.url
    }

    private static func store(_ url: URL, for id: String) {
        lock.lock(); defer { lock.unlock() }
        cache[id] = (url, Date())
        guard cache.count > cacheLimit else { return }
        // LRU by insertion time: expire stale entries first, then evict the
        // oldest until the window fits. Most-recently resolved URLs stay hot.
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.at) < cacheTTL }
        if cache.count > cacheLimit {
            let oldest = cache.sorted { $0.value.at < $1.value.at }.prefix(cache.count - cacheLimit)
            for key in oldest.map({ $0.key }) { cache.removeValue(forKey: key) }
        }
    }

    private static func fetch(_ videoID: String, audioOnly: Bool, download: Bool) async throws -> URL {
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
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
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
        return url
    }

    private static func itag(_ format: [String: Any]) -> Int? {
        format["itag"] as? Int ?? (format["itag"] as? NSNumber)?.intValue
    }

    private static func bitrate(_ format: [String: Any]) -> Int {
        format["bitrate"] as? Int ?? (format["bitrate"] as? NSNumber)?.intValue ?? 0
    }
}
