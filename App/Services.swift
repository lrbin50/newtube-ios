import Foundation
import YouTubeKit

enum MediaError: LocalizedError {
    case unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .unavailable: return "YouTube did not offer a compatible stream for this video."
        case .invalidResponse: return "The media server could not complete the request."
        }
    }
}

enum Media {
    static func source(_ video: Video, audioOnly: Bool = false, download: Bool = false) async throws -> URL {
        let youtube = YouTube(videoID: video.id, methods: [.local])
        do {
            let streams = try await youtube.streams
            let playable = streams.filter { $0.isNativelyPlayable }
            let choice = audioOnly
                ? playable.filterAudioOnly().filter { $0.fileExtension == .m4a }.highestAudioBitrateStream()
                : playable.filterVideoAndAudio().filter { !download || $0.fileExtension == .mp4 }.highestResolutionStream()
            guard let choice else { throw MediaError.unavailable }
            try await choice.waitUntilAvailable()
            return choice.url
        } catch {
            try Task.checkCancellation()
            guard !download, let live = try await youtube.livestreams.first(where: { $0.streamType == .hls })
            else { throw error }
            return live.url
        }
    }

    static func download(_ video: Video, audioOnly: Bool) async throws -> URL {
        let address = try await source(video, audioOnly: audioOnly, download: true)
        let (file, response) = try await LegacyNetwork.download(from: address)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !(http.mimeType ?? "").hasPrefix("text/"),
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
        else { throw MediaError.invalidResponse }
        return file
    }
}

enum Community {
    struct Segment: Decodable { let segment: [Double] }
    private struct Branding: Decodable {
        struct Title: Decodable { let title: String; let votes: Int }
        let titles: [Title]
    }
    private struct Votes: Decodable { let dislikes: Int }

    private static func get<T: Decodable>(_ type: T.Type, _ endpoint: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: endpoint)!
        components.queryItems = query
        let (data, response) = try await LegacyNetwork.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalidResponse }
        return try JSONDecoder().decode(type, from: data)
    }

    static func segments(_ id: String) async -> [[Double]] {
        let items = try? await get([Segment].self, "https://sponsor.ajay.app/api/skipSegments", query: [
            .init(name: "videoID", value: id), .init(name: "categories", value: "[\"sponsor\",\"selfpromo\"]")
        ])
        guard let items else { return [] }
        var ranges: [[Double]] = []
        for item in items {
            let range = item.segment
            guard range.count == 2 else { continue }
            let start = range[0]
            let end = range[1]
            if start >= 0 && end > start { ranges.append(range) }
        }
        return ranges
    }

    static func title(_ id: String) async -> String? {
        let result = try? await get(Branding.self, "https://sponsor.ajay.app/api/branding", query: [.init(name: "videoID", value: id)])
        return result?.titles.first(where: { $0.votes >= 0 && !$0.title.isEmpty })?.title
    }

    static func dislikes(_ id: String) async -> Int? {
        let result = try? await get(Votes.self, "https://returnyoutubedislikeapi.com/votes", query: [.init(name: "videoId", value: id)])
        return result?.dislikes
    }
}
