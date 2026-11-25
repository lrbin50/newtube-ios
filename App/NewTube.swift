import SwiftUI
import AVKit
import WebKit
import UIKit

@main struct NewTubeApp: App {
    @StateObject private var library: Library
    @StateObject private var playback: Playback
    @StateObject private var browser = Browser()
    @StateObject private var tv = Television()

    init() {
        UserDefaults.standard.register(defaults: ["sponsorBlock": true, "deArrow": false, "showDislikes": false, "speed": 1.0])
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _playback = StateObject(wrappedValue: Playback(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library).environmentObject(playback)
                .environmentObject(browser).environmentObject(tv)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var browser: Browser
    @EnvironmentObject var tv: Television
    @ObservedObject private var l10n = L10n.shared
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            BrowseView()
                .tabItem { Label(L10n.tr("tab.home"), systemImage: "house.fill") }.tag(0)
            ShortsView()
                .tabItem { Label(L10n.tr("tab.shorts"), systemImage: "play.rectangle.fill") }.tag(1)
            BrowseView()
                .tabItem { Label(L10n.tr("tab.subscriptions"), systemImage: "rectangle.stack") }.tag(2)
            LibraryView()
                .tabItem { Label(L10n.tr("tab.you"), systemImage: "person.crop.circle") }.tag(3)
        }
        // Rebuild the tree when the language changes so every L10n.tr() call
        // re-resolves; environment objects survive the rebuild.
        .id(l10n.language)
        .onAppear {
            browser.play = { playback.open($0) }
        }
        // Reload the shared feed when switching between Home and Subscriptions.
        .onChange(of: selection) { index in
            if index == 0 { Task { await Feed.shared.load(.home) } }
            if index == 2 { Task { await Feed.shared.load(.subscriptions) } }
        }
        // Any video being opened takes over the whole screen.
        .fullScreenCover(item: Binding(get: { playback.current }, set: { _ in })) { video in
            FullScreenPlayerView(video: video)
                .environmentObject(library)
                .environmentObject(playback)
                .environmentObject(tv)
        }
        .alert(isPresented: Binding(get: { playback.message != nil }, set: { if !$0 { playback.message = nil } })) {
            Alert(title: Text("NewTube"), message: Text(playback.message ?? ""),
                  dismissButton: .default(Text(L10n.tr("common.ok"))))
        }
    }
}

/// Shorts tab: the mobile shorts feed in its own web view, independent of the
/// shared Browse web view so it cannot disturb the Home tab.
struct ShortsView: View {
    @StateObject private var store = ShortsWebStore()
    var body: some View {
        ShortsSurface(web: store.web).edgesIgnoringSafeArea(.all)
    }
}

@MainActor final class ShortsWebStore: ObservableObject {
    let web: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        let view = WKWebView(frame: .zero, configuration: config)
        view.scrollView.contentInsetAdjustmentBehavior = .never
        if let url = URL(string: "https://m.youtube.com/shorts") {
            view.load(URLRequest(url: url))
        }
        return view
    }()
}

struct ShortsSurface: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Native home built on InnerTube. Mirrors the YouTube phone/tablet app:
/// a top bar with logo and icons, horizontally scrolling category chips, and
/// an edge-to-edge two-column video grid (portrait) with rich metadata cards.
struct BrowseView: View {
    @EnvironmentObject var playback: Playback
    @ObservedObject private var account = Account.shared
    @ObservedObject private var feed = Feed.shared
    @State private var query = ""
    @State private var showSearch = false
    @State private var showSignIn = false
    @State private var selectedChip = 0

    private var chips: [String] {
        ["chip.all", "chip.music", "chip.podcasts", "chip.mixes", "chip.live",
         "chip.travel", "chip.recent", "chip.watched", "chip.newToYou"].map { L10n.tr($0) }
    }

    var body: some View {
        GeometryReader { geo in
            // Portrait is always two columns; only landscape gets more.
            let columns = geo.size.width > geo.size.height ? 3 : 2
            ZStack(alignment: .top) {
                if !account.isSignedIn {
                    SignInView(onSignIn: { showSignIn = true })
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 100) // space for pinned header + chips
                            if feed.loading && feed.videos.isEmpty {
                                VStack { ProgressView(L10n.tr("common.loading")).padding(.top, 80) }
                            } else if let message = feed.message, feed.videos.isEmpty {
                                EmptyStateView(title: message, systemImage: "exclamationmark.triangle",
                                               description: Text("Sign in again from the Account menu."),
                                               buttonTitle: L10n.tr("common.retry")) {
                                    Task { await feed.load(.home) }
                                }
                            } else {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                                    spacing: 18
                                ) {
                                    ForEach(feed.videos) { video in
                                        FeedCard(video: video)
                                            .contentShape(Rectangle())
                                            .onTapGesture { playback.open(video.video) }
                                            .onAppear {
                                                FastMedia.prewarm(video.id)
                                                if video.id == feed.videos.last?.id { Task { await feed.loadMore() } }
                                            }
                                    }
                                }
                                .padding(.horizontal, 10)
                                if feed.loadingMore { ProgressView().padding() }
                                Color.clear.frame(height: 40)
                                    .onAppear { Task { await feed.loadMore() } }
                            }
                        }
                    }
                }

                // Pinned top bar + category chips. The background is fully
                // opaque and extends into the top safe area so the iPad status
                // bar (time/battery) always sits on a solid bar — scrolling
                // cards pass underneath instead of showing through it.
                if account.isSignedIn {
                    VStack(spacing: 0) {
                        topBar
                        chipsBar
                    }
                    .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.top))
                }

                if showSearch {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                            TextField(L10n.tr("action.search"), text: $query, onCommit: submitSearch)
                                .autocapitalization(.none).disableAutocorrection(true)
                            Button { showSearch = false; query = "" } label: {
                                Image(systemName: "xmark").foregroundColor(.primary)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                        .padding(.horizontal, 12).padding(.top, 6)
                        Spacer()
                    }
                    .background(Color(UIColor.systemBackground).opacity(0.98).edgesIgnoringSafeArea(.top))
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .onAppear {
            if account.isSignedIn, feed.videos.isEmpty { Task { await feed.load(.home) } }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            // YouTube-style logo.
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4).fill(Color.red)
                    .frame(width: 28, height: 20)
                    .overlay(Image(systemName: "play.fill").foregroundColor(.white).font(.system(size: 11)))
                Text("YouTube").font(.system(size: 18, weight: .bold))
            }
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundColor(.primary)
            }
            Menu {
                Button { showSignIn = true } label: { Label(L10n.tr("action.account"), systemImage: "person.circle") }
                Button { UIApplication.shared.open(URL(string: "https://www.youtube.com/feed/you")!) } label: {
                    Label(L10n.tr("action.openYouTube"), systemImage: "safari")
                }
            } label: {
                Circle().fill(Color.accentColor.opacity(0.25))
                    .overlay(Text("Y").font(.system(size: 14, weight: .bold)).foregroundColor(.accentColor))
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, name in
                    Button {
                        selectedChip = index
                        if index == 0 { Task { await feed.load(.home) } }
                        else if index == 1 { Task { await feed.load(.search("music")) } }
                    } label: {
                        Text(name).font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(
                                Capsule().fill(selectedChip == index
                                    ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.15))
                            )
                            .foregroundColor(selectedChip == index
                                ? Color(UIColor.systemBackground) : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = URL(string: text), let video = Video.parse(url) {
            playback.open(video); showSearch = false; return
        }
        showSearch = false
        Task { await feed.load(.search(text)) }
    }
}

struct FeedCard: View {
    @EnvironmentObject var library: Library
    let video: FeedVideo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RemoteThumbnail(url: video.thumbnailURL)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped().cornerRadius(8)
                if let duration = video.duration {
                    Text(duration).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.8)).cornerRadius(4)
                        .padding(6)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                // Channel avatar (initial in a colored circle).
                Circle().fill(Color.accentColor.opacity(0.3))
                    .overlay(
                        Text((video.channel ?? "?").prefix(1).uppercased())
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.accentColor)
                    )
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title).font(.system(size: 13, weight: .medium)).foregroundColor(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 3) {
                        if let channel = video.channel { Text(channel) }
                        if let views = video.views { Text("· \(views)") }
                        if let date = video.published { Text("· \(date)") }
                    }
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }

                Spacer(minLength: 0)

                Menu {
                    Button { library.bookmark(video.video) } label: { Label(L10n.tr("card.watchLater"), systemImage: "clock") }
                    Button { } label: { Label(L10n.tr("common.share"), systemImage: "square.and.arrow.up") }
                    Button { } label: { Label(L10n.tr("card.notInterested"), systemImage: "hand.thumbsdown") }
                } label: {
                    Image(systemName: "ellipsis.vertical")
                        .font(.system(size: 16)).foregroundColor(.secondary)
                        .frame(width: 20)
                }
            }
        }
    }
}

/// First-run / signed-out prompt.
struct SignInView: View {
    let onSignIn: () -> Void
    var body: some View {
        EmptyStateView(
            title: L10n.tr("signin.title"),
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text(L10n.tr("signin.desc")),
            buttonTitle: L10n.tr("signin.button"),
            action: onSignIn
        )
    }
}

/// Device-code sign-in sheet: shows the code, opens google.com/device and polls.
struct SignInSheet: View {
    @ObservedObject private var account = Account.shared
    @Environment(\.presentationMode) private var presentation
    @State private var flow: DeviceCodeFlow?
    @State private var status = "Preparing sign-in…"
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "tv.and.hi.fi.signal").font(.system(size: 44)).foregroundColor(.accentColor)
                Text("Sign in with your Google account").font(.headline)
                if let flow {
                    VStack(spacing: 8) {
                        Text("Enter this code at \(flow.verificationURL):")
                            .font(.subheadline).foregroundColor(.secondary)
                        Text(flow.userCode).font(.system(size: 30, weight: .bold, design: .monospaced))
                        Button("Copy code") { UIPasteboard.general.string = flow.userCode }
                        Button("Open verification page") {
                            if let url = URL(string: flow.verificationURL) { UIApplication.shared.open(url) }
                        }
                    }
                    .padding().background(Color.secondary.opacity(0.1)).cornerRadius(12)
                }
                Text(status).font(.subheadline).foregroundColor(.secondary)
                if let error { Text(error).font(.caption).foregroundColor(.red) }
                Spacer()
            }
            .padding().navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { pollTask?.cancel(); presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: start)
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        Task {
            do {
                let result = try await account.beginSignIn()
                await MainActor.run {
                    flow = result
                    UIPasteboard.general.string = result.userCode
                    status = "Waiting for approval…"
                }
                let task = Task {
                    do {
                        try await account.awaitApproval(result)
                        await MainActor.run {
                            status = "Signed in"
                            presentation.wrappedValue.dismiss()
                            Task { await Feed.shared.load(.home) }
                        }
                    } catch {
                        await MainActor.run { self.error = error.localizedDescription }
                    }
                }
                await MainActor.run { pollTask = task }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

/// Player page styled after the Android app. Portrait shows a 16:9 player on
/// top with a scrollable detail list below (actions, channel, comments, up
/// next). Landscape keeps the player full screen with a minimal overlay.
struct FullScreenPlayerView: View {
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var library: Library
    @EnvironmentObject var tv: Television
    @State private var webPlayer: Video?
    @State private var meta = VideoMeta()
    @State private var related: [Video] = []
    @State private var liked = false
    @State private var disliked = false
    @State private var subscribed = false
    @State private var didLoadMeta = false
    @State private var showPlayerSettings = false
    @AppStorage("playerQuality") private var quality = "auto"
    @AppStorage("playerSubtitles") private var subtitles = false
    @AppStorage("speed") private var speed = 1.0
    let video: Video

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                if landscape {
                    // Landscape: nothing but the player + a settings gear.
                    PlayerSurface(player: playback.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(Group {
                            if playback.resolving { ProgressView().accentColor(.white) }
                        })
                    VStack {
                        HStack {
                            Button { playback.close() } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white).padding(8)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            Spacer()
                            Button { showPlayerSettings = true } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white).padding(8)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                        }.padding()
                        Spacer()
                    }
                } else {
                    // Portrait: player on top, details scrolling underneath.
                    ScrollView {
                        VStack(spacing: 0) {
                            ZStack {
                                PlayerSurface(player: playback.player)
                                    .frame(height: geo.size.width * 9 / 16)
                                if playback.resolving { ProgressView().accentColor(.white) }
                                VStack {
                                    HStack {
                                        // Back button stays reachable while loading and playing.
                                        Button { playback.close() } label: {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 18, weight: .semibold))
                                                .foregroundColor(.white).padding(8)
                                                .background(Circle().fill(Color.black.opacity(0.5)))
                                        }
                                        Spacer()
                                        // Top-right controls: cast, subtitles, settings.
                                        HStack(spacing: 6) {
                                            if tv.name != nil {
                                                Button(action: cast) {
                                                    Image(systemName: "airplayvideo")
                                                        .foregroundColor(.white).padding(7)
                                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                                }
                                            }
                                            Button { subtitles.toggle() } label: {
                                                Image(systemName: subtitles ? "captions.bubble.fill" : "captions.bubble")
                                                    .foregroundColor(.white).padding(7)
                                                    .background(Circle().fill(Color.black.opacity(0.5)))
                                            }
                                            Button { showPlayerSettings = true } label: {
                                                Image(systemName: "gearshape")
                                                    .foregroundColor(.white).padding(7)
                                                    .background(Circle().fill(Color.black.opacity(0.5)))
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(8)
                            }
                            detail
                        }
                    }
                }

                if let failure = playback.failure {
                    VStack(spacing: 10) {
                        Text(failure).font(.caption).multilineTextAlignment(.center).foregroundColor(.white)
                        HStack {
                            Button("Retry") { playback.open(video) }
                            Button("Use web player", action: openWeb)
                        }.accentColor(.white)
                    }
                    .padding().background(Color.black.opacity(0.75)).cornerRadius(10)
                    .padding()
                }
            }
        }
        // Defer detail/network-heavy work until the stream is ready, so it does
        // not compete with video resolution on a slow connection.
        .onAppear { if !playback.resolving { load() } }
        .onChange(of: playback.resolving) { resolving in
            if !resolving { load() }
        }
        .sheet(item: $webPlayer) { video in WebPlayer(url: video.watchURL).ignoresSafeArea() }
        .sheet(isPresented: $showPlayerSettings) { PlayerSettingsSheet() }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title + expandable description row.
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.communityTitle ?? video.title)
                        .font(.headline).foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let views = meta.views { Text(views) }
                        if let date = meta.published {
                            Text("· \(relativeDate(date))")
                        }
                    }
                    .font(.caption).foregroundColor(.secondary)
                    if playback.expanded {
                        Text(video.title)
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button { playback.expanded.toggle() } label: {
                    Image(systemName: playback.expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }

            // Action buttons: like / dislike / share / download / save.
            HStack(spacing: 8) {
                action(system: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                       label: meta.likes ?? L10n.tr("common.like"), active: liked) {
                    liked.toggle(); if liked { disliked = false }
                }
                action(system: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                       label: L10n.tr("common.dislike"), active: disliked) {
                    disliked.toggle(); if disliked { liked = false }
                }
                action(system: "square.and.arrow.up", label: L10n.tr("common.share"), active: false, tap: openWeb)
                action(system: "arrow.down.to.line", label: L10n.tr("common.download"), active: false) {
                    playback.save(video, audioOnly: false)
                }
                action(system: library.saved.contains(where: { $0.id == video.id }) ? "bookmark.fill" : "bookmark",
                       label: library.saved.contains(where: { $0.id == video.id }) ? L10n.tr("common.saved") : L10n.tr("common.save"),
                       active: library.saved.contains(where: { $0.id == video.id })) {
                    library.bookmark(video)
                }
            }

            // Channel row with subscriber count.
            HStack(spacing: 12) {
                Circle().fill(Color.accentColor.opacity(0.2))
                    .overlay(Text((meta.author ?? "?").prefix(1).uppercased())
                        .font(.headline).foregroundColor(.accentColor))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.author ?? L10n.tr("common.channel")).font(.subheadline.bold())
                    if let subs = meta.subscribers {
                        Text("\(subs) \(L10n.tr("common.subscribers"))")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(L10n.tr("common.channel")).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button { subscribed.toggle() } label: {
                    Text(subscribed ? L10n.tr("common.subscribed") : L10n.tr("common.subscribe"))
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(subscribed ? Color.secondary.opacity(0.2) : Color.primary)
                        .foregroundColor(subscribed ? .primary : Color(UIColor.systemBackground))
                        .cornerRadius(20)
                }
            }

            // Comments row with count.
            Button(action: openWeb) {
                HStack {
                    Image(systemName: "bubble.left").foregroundColor(.primary)
                    Text(L10n.tr("common.comments")).foregroundColor(.primary)
                    if let count = meta.comments {
                        Text(count).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(.secondary)
                }
                .padding().background(Color.secondary.opacity(0.1)).cornerRadius(10)
            }

            // Up next
            if !related.isEmpty {
                Text(L10n.tr("player.upNext")).font(.headline)
                ForEach(related) { item in
                    Button { playback.open(item) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RemoteThumbnail(url: item.thumbnailURL)
                                .frame(width: 120, height: 68).clipped().cornerRadius(6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline).lineLimit(3).foregroundColor(.primary)
                                Text(item.id).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            // More actions
            Menu {
                Button(L10n.tr("common.download") + " (audio)") { playback.save(video, audioOnly: true) }
                if let name = tv.name { Button("\(L10n.tr("settings.playOnTV")): \(name)", action: cast) }
                Button("\(L10n.tr("action.openYouTube"))", action: openWeb)
            } label: {
                Label(L10n.tr("player.moreActions"), systemImage: "ellipsis.circle")
            }
        }
        .padding()
    }

    private func relativeDate(_ iso: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: String(iso.prefix(10))) else { return iso }
        let days = max(0, Int(Date().timeIntervalSince(date) / 86400))
        if L10n.shared.effective == .simplifiedChinese {
            if days == 0 { return "今天" }
            if days == 1 { return "昨天" }
            if days < 30 { return "\(days)天前" }
            if days < 365 { return "\(days / 30)个月前" }
            return "\(days / 365)年前"
        }
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days) days ago" }
        if days < 365 { return "\(days / 30) months ago" }
        return "\(days / 365) years ago"
    }

    private func action(system: String, label: String, active: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 20))
                    .foregroundColor(active ? .accentColor : .primary)
                Text(label).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1)).cornerRadius(10)
        }
    }

    private func load() {
        guard !didLoadMeta else { return }
        didLoadMeta = true
        Task {
            // Run both requests concurrently instead of one after the other.
            async let loaded = Meta.load(video)
            async let suggestions = Meta.related(to: video)
            let (info, next) = await (loaded, suggestions)
            await MainActor.run { meta = info; related = next }
        }
    }

    private func openWeb() {
        playback.player.pause()
        webPlayer = video
    }

    private func cast() {
        Task {
            do {
                try await tv.cast(video, queue: playback.queue, position: playback.player.currentTime().seconds)
                if playback.current?.id == video.id { playback.player.pause() }
            } catch {
                playback.message = "Could not send to TV. " + error.localizedDescription
            }
        }
    }
}

/// Bottom settings panel opened from the player's gear icon.
/// Mirrors the YouTube player sheet: quality, subtitles, speed, PiP, more.
struct PlayerSettingsSheet: View {
    @Environment(\.presentationMode) private var presentation
    @AppStorage("playerQuality") private var quality = "auto"
    @AppStorage("playerSubtitles") private var subtitles = false
    @AppStorage("speed") private var speed = 1.0

    private let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Label(L10n.tr("player.quality"), systemImage: "slider.horizontal.3")
                        Spacer()
                        Text(qualityLabel).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $subtitles) {
                        Label(L10n.tr("player.subtitles"), systemImage: "captions.bubble")
                    }
                    HStack {
                        Label(L10n.tr("player.speed"), systemImage: "speedometer")
                        Spacer()
                        Picker("", selection: $speed) {
                            ForEach(speeds, id: \.self) { value in
                                Text(speedLabel(value)).tag(value)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                    }
                    Button { presentation.wrappedValue.dismiss() } label: {
                        Label(L10n.tr("player.pip"), systemImage: "rectangle.on.rectangle")
                    }
                    NavigationLink(destination: moreView) {
                        Label(L10n.tr("player.more"), systemImage: "gearshape.2")
                    }
                }
            }
            .navigationTitle(L10n.tr("player.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.tr("common.ok")) { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var qualityLabel: String {
        switch quality {
        case "1080": return "1080p"
        case "720": return "720p"
        case "480": return "480p"
        case "360": return "360p"
        default: return L10n.tr("player.auto")
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value == 1 ? L10n.tr("player.normal") : "\(value)×"
    }

    private var moreView: some View {
        Form {
            Section(header: Text(L10n.tr("player.quality"))) {
                ForEach(["auto", "1080", "720", "480", "360"], id: \.self) { q in
                    Button {
                        quality = q
                    } label: {
                        HStack {
                            Text(q == "auto" ? L10n.tr("player.auto") : "\(q)p")
                            Spacer()
                            if quality == q { Image(systemName: "checkmark").accentColor(.accentColor) }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            Section(header: Text(L10n.tr("player.subtitles"))) {
                Toggle(L10n.tr("player.off"), isOn: $subtitles)
            }
        }
        .navigationTitle(L10n.tr("player.more"))
    }
}

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var tv: Television
    @State private var category = "Watch later"
    @State private var showSettings = false
    let categories = ["Watch later", "Downloads", "History"]
    var videos: [Video] {
        switch category {
        case "Downloads": return library.downloads
        case "History": return library.history
        default: return library.saved
        }
    }
    var body: some View {
        NavigationView {
            VStack {
                Picker("Collection", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0) }
                }.pickerStyle(.segmented).padding(.horizontal)
                if videos.isEmpty {
                    EmptyStateView(
                        title: category,
                        systemImage: category == "Downloads" ? "arrow.down.circle" : "rectangle.stack",
                        description: Text(category == "Downloads" ? "Download a video or its audio from the player menu to play it offline."
                            : category == "History" ? "Videos you play appear here." : "Save videos using Watch later in the player menu.")
                    )
                } else {
                    List(videos) { video in
                        Button { playback.open(video) } label: {
                            HStack {
                                RemoteThumbnail(url: video.thumbnailURL)
                                    .frame(width: 90, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(video.title).lineLimit(3).foregroundColor(.primary)
                            }
                        }
                        .contextMenu {
                            Button("Add to queue") { playback.enqueue(video) }
                            Button(library.saved.contains(where: { $0.id == video.id }) ? "Remove from Watch later" : "Watch later") { library.bookmark(video) }
                            ShareButton(url: video.watchURL)
                            if category == "Downloads" { Button("Delete download") {
                                do { try library.removeDownload(video) } catch { playback.message = error.localizedDescription }
                            }.foregroundColor(.red) }
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("You")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if videos.count > 1 {
                        Menu {
                            Button("Play all") { play(videos) }
                            Button("Shuffle") { play(videos.shuffled()) }
                        } label: {
                            Label("Play", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(tv) }
    }
    private func play(_ items: [Video]) {
        playback.playCollection(items)
    }
}
