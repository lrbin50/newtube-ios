import SwiftUI

/// Circular channel avatar: real remote image when we have a URL, otherwise a
/// colored initial placeholder. Kept small and explicitly sized so it never
/// overflows a tab bar or a row (the old unbounded-image blue-circle bug).
struct ChannelAvatarView: View {
    let name: String?
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url {
                RemoteThumbnail(url: url)
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(
                        Text((name ?? "?").prefix(1).uppercased())
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundColor(.accentColor)
                    )
                    .frame(width: size, height: size)
            }
        }
    }
}

/// A creator channel page opened from the player's channel row.
/// Header (banner + avatar + name + subscribers) plus five tabs. The Home
/// tab shows the channel's real videos in a two-column grid, newest first;
/// the other tabs are lightweight placeholders for now.
struct ChannelProfileView: View {
    let channelID: String?
    let name: String?
    let avatarURL: URL?
    let bannerURL: URL?
    let subscribers: String?

    @Environment(\.presentationMode) private var presentation
    @EnvironmentObject var playback: Playback
    @State private var tab: Int = 0
    @State private var videos: [FeedVideo] = []
    @State private var loading = false
    @State private var headerAvatar: URL?
    @State private var headerBanner: URL?
    @State private var headerSubs: String?
    @State private var videoCount: String?

    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
    private let tvVersion = "7.20261123.19.00"
    private let tabs = ["channel.tab.home", "channel.tab.videos", "channel.tab.shorts",
                        "channel.tab.playlists", "channel.tab.community"]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    banner
                    header
                    tabBar
                    if tab == 0 || tab == 1 {
                        videoGrid
                    } else {
                        placeholder(tab: tab)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { presentation.wrappedValue.dismiss() } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { } label: { Image(systemName: "magnifyingglass") }
                        Button { presentation.wrappedValue.dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear { Task { await load() } }
    }

    // MARK: - Header

    private var banner: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let url = headerBanner ?? bannerURL {
                    RemoteThumbnail(url: url)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.22))
                }
            }
            .frame(height: 110)
            .clipped()
            Rectangle().fill(Color(UIColor.systemBackground).opacity(0.35)).frame(height: 1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ChannelAvatarView(name: name, url: headerAvatar ?? avatarURL, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name ?? L10n.tr("common.channel"))
                        .font(.system(size: 19, weight: .bold))
                    if let subs = headerSubs ?? subscribers {
                        Text(subs).font(.caption).foregroundColor(.secondary)
                    }
                    if let count = videoCount {
                        Text(count).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { } label: {
                    Text(L10n.tr("common.subscribe"))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.primary)
                        .foregroundColor(Color(UIColor.systemBackground))
                        .cornerRadius(18)
                }
                .buttonStyle(.plain)
                Button { } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 40).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.16))
                        .foregroundColor(.primary)
                        .cornerRadius(18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, -18).padding(.bottom, 6)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    Button { tab = index } label: {
                        VStack(spacing: 0) {
                            Text(L10n.tr(tabs[index]))
                                .font(.system(size: 14, weight: tab == index ? .semibold : .regular))
                                .foregroundColor(tab == index ? .primary : .secondary)
                            Rectangle().fill(tab == index ? Color.accentColor : Color.clear)
                                .frame(height: 2).padding(.top, 8)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Video grid

    private var videoGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("channel.latest", fallback: "Latest")).font(.subheadline.bold())
                Spacer()
                Text(L10n.tr("channel.sort.newest", fallback: "Newest")).font(.caption).foregroundColor(.secondary)
            }
            if loading && videos.isEmpty {
                HStack { Spacer(); ProgressView(L10n.tr("common.loading")); Spacer() }
                    .padding(.vertical, 50)
            } else if videos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(L10n.tr("channel.videos.empty", fallback: "No videos yet"))
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 50)
            } else {
                ForEach(Array(stride(from: 0, to: videos.count, by: 2)), id: \.self) { row in
                    HStack(alignment: .top, spacing: 10) {
                        videoCard(videos[row])
                        if row + 1 < videos.count {
                            videoCard(videos[row + 1])
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func videoCard(_ item: FeedVideo) -> some View {
        Button {
            presentation.wrappedValue.dismiss()
            playback.open(Video(id: item.id, title: item.title))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteThumbnail(url: item.thumbnailURL)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipped().cornerRadius(8)
                    if let duration = item.duration {
                        Text(duration).font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.black.opacity(0.8)).cornerRadius(4).padding(5)
                    }
                }
                Text(item.title).font(.caption).foregroundColor(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text([item.views, item.published].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func placeholder(tab: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: tab == 2 ? "video.badge.plus" : (tab == 3 ? "square.stack" : "bubble.left.and.bubble.right"))
                .font(.system(size: 32)).foregroundColor(.secondary)
            Text(L10n.tr("channel.tab.coming", fallback: "Coming soon"))
                .font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    // MARK: - Data

    private func load() async {
        guard let cid = channelID, cid.hasPrefix("UC") else {
            await loadBySearch()
            return
        }
        loading = true
        defer { loading = false }
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tvAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("7", forHTTPHeaderField: "X-YOUTUBE-CLIENT-NAME")
        request.setValue(tvVersion, forHTTPHeaderField: "X-YOUTUBE-CLIENT-VERSION")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": ["client": [
                "clientName": "TVHTML5", "clientVersion": tvVersion,
                "hl": "en", "gl": "US", "platform": "TV",
                "clientFormFactor": "UNKNOWN_FORM_FACTOR"
            ]],
            "browseId": cid
        ])
        guard let (data, response) = try? await LegacyNetwork.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        parseHeader(json)
        videos = Feed.parse(json).videos
    }

    /// If the player response did not expose a channel id, fall back to a
    /// public search for the channel name and take the first channel result.
    private func loadBySearch() async {
        guard let query = name, !query.isEmpty else { return }
        loading = true
        defer { loading = false }
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/search?key=\(apiKey)&prettyPrint=false")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tvAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": ["client": [
                "clientName": "TVHTML5", "clientVersion": tvVersion,
                "hl": "en", "gl": "US", "platform": "TV"
            ]],
            "query": query, "type": "channel"
        ])
        guard let (data, response) = try? await LegacyNetwork.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var foundID: String?
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if foundID == nil, let cid = dict["channelId"] as? String,
                   cid.hasPrefix("UC"), cid.count == 24 { foundID = cid }
                for child in dict.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(json)
        if let cid = foundID { await load() }
    }

    private func parseHeader(_ json: [String: Any]) {
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
        func largest(_ value: Any?) -> URL? {
            guard let dict = value as? [String: Any],
                  let thumbs = dict["thumbnails"] as? [[String: Any]] else { return nil }
            let best = thumbs.max { (a["width"] as? Int ?? 0) < (b["width"] as? Int ?? 0) }
            guard let raw = best?["url"] as? String else { return nil }
            return URL(string: raw)
        }
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let header = dict["channelHeaderRenderer"] as? [String: Any] {
                    if headerAvatar == nil { headerAvatar = largest(header["avatar"]) }
                    if headerBanner == nil { headerBanner = largest(header["banner"]) }
                    if headerSubs == nil {
                        let s = textOf(header["subscriberCountText"])
                        if !s.isEmpty { headerSubs = s }
                    }
                    if videoCount == nil {
                        let s = textOf(header["videoCountText"])
                        if !s.isEmpty { videoCount = s }
                    }
                }
                for child in dict.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(json)
    }
}
