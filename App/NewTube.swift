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
    @ObservedObject private var account = Account.shared
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            homeTab
            shortsTab
            subsTab
            youTab
        }
        // Rebuild the tree when the language changes so every L10n.tr() call
        // re-resolves; environment objects survive the rebuild.
        .id(l10n.language)
        .overlay(miniPlayerOverlay)
        .onAppear {
            browser.play = { playback.open($0) }
        }
        // Reload the shared feed when switching between Home and Subscriptions.
        .onChange(of: selection) { index in
            if index == 0 { Task { await Feed.shared.load(.home) } }
            if index == 2 { Task { await Feed.shared.load(.subscriptions) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToHomeTab)) { _ in
            selection = 0
        }
        // Any video being opened takes over the whole screen. When the player
        // minimizes into the mini window the cover releases the full-screen
        // page by yielding a nil item.
        .fullScreenCover(item: playerBinding) { video in
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

    private var homeTab: some View {
        BrowseView()
            .tabItem { Label(L10n.tr("tab.home"), systemImage: "house.fill") }.tag(0)
    }

    private var shortsTab: some View {
        ShortsView()
            .tabItem { Label(L10n.tr("tab.shorts"), systemImage: "play.rectangle.fill") }.tag(1)
    }

    private var subsTab: some View {
        BrowseView()
            .tabItem { Label(L10n.tr("tab.subscriptions"), systemImage: "rectangle.stack") }.tag(2)
    }

    private var youTab: some View {
        LibraryView()
            .tabItem { youTabContent }.tag(3)
    }

    @ViewBuilder
    private var youTabContent: some View {
        // iOS 14's UITabBar renders tab images as *templates* at the bitmap's
        // intrinsic pixel size. A real avatar UIImage (200px, already cropped
        // to a circle) therefore overflows the tab bar and is painted as a
        // huge solid circle — blue when selected, translucent grey otherwise —
        // which shows up as the large half-circle in the bottom-right corner
        // on every tab. SwiftUI .frame/.clipShape cannot override UITabBarItem.
        // A system symbol is template-rendered correctly; the full photo is
        // shown at 54pt in the You tab's title bar instead.
        Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
        Text(L10n.tr("tab.you"))
    }

    /// Floating bottom-right mini window while the player is minimized;
    /// playback keeps running on top of every tab. (overlay(alignment:) is
    /// iOS 15+, so the alignment is built with spacer stacks for iOS 14.)
    private var miniPlayerOverlay: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                miniPlayer
            }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if playback.minimized, let video = playback.current {
            MiniPlayerView(video: video)
        }
    }

    private var playerBinding: Binding<Video?> {
        Binding(get: { playback.minimized ? nil : playback.current },
                set: { _ in })
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

    private let chipKeys = ["chip.all", "chip.music", "chip.podcasts", "chip.mixes", "chip.live",
                            "chip.travel", "chip.recent", "chip.watched", "chip.newToYou"]

    private var chips: [String] { chipKeys.map { L10n.tr($0) } }

    /// Every chip must actually load something. Category chips use the params
    /// harvested from the latest home response; when absent, Feed falls back
    /// to a public TV search instead of the 401-prone ANDROID+bearer request.
    private func selectChip(_ index: Int) {
        selectedChip = index
        if index == 0 {
            Task { await feed.load(.home) }
            return
        }
        let chip = feed.chips.indices.contains(index) ? feed.chips[index] : Feed.defaultChips[index]
        Task { await feed.load(.category(chip)) }
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
                Group {
                    if let image = account.avatarImage {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 30, height: 30).clipShape(Circle())
                    } else {
                        Circle().fill(Color.accentColor.opacity(0.25))
                            .overlay(Text("Y").font(.system(size: 14, weight: .bold))
                                .foregroundColor(.accentColor))
                            .frame(width: 30, height: 30)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, name in
                    Button { selectChip(index) } label: {
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
    @State private var showComments = false
    // iOS 14 only reliably presents one sheet per view, so settings and the
    // playlist picker share a single attachment keyed by an enum.
    @State private var activeSheet: ActiveSheet?
    @State private var playhead: Double = 0
    @State private var duration: Double = 0
    @State private var seeking = false
    @State private var ticker: Timer?
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
                    // Landscape: the player fills the screen with the same
                    // control layer used in portrait.
                    ZStack {
                        PlayerSurface(player: playback.player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if playback.resolving { ResolvingOverlay() }
                        playerControls
                    }
                } else {
                    // Portrait: player on top, details scrolling underneath.
                    ScrollView {
                        VStack(spacing: 0) {
                            ZStack {
                                PlayerSurface(player: playback.player)
                                    .frame(height: geo.size.width * 9 / 16)
                                if playback.resolving { ResolvingOverlay() }
                                playerControls
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

                // Bottom-half comments overlay: the player stays visible on
                // top while the panel slides up, like the Android app.
                if showComments {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        CommentsPanel(videoId: video.id) {
                            withAnimation(.easeIn(duration: 0.2)) { showComments = false }
                        }
                        .frame(height: landscape
                                ? geo.size.height * 0.72
                                : geo.size.height * 0.58)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
                }
            }
        }
        // Defer detail/network-heavy work until the stream is ready, so it does
        // not compete with video resolution on a slow connection.
        .onAppear {
            if !playback.resolving { load() }
            startTicker()
        }
        .onDisappear { ticker?.invalidate() }
        .onChange(of: playback.resolving) { resolving in
            if !resolving { load() }
        }
        .sheet(item: $webPlayer) { video in WebPlayer(url: video.watchURL).ignoresSafeArea() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings: PlayerSettingsSheet()
            case .save: SaveToPlaylistSheet(video: video)
            }
        }
    }

    enum ActiveSheet: Identifiable {
        case settings, save
        var id: Self { self }
    }

    /// A single, high-contrast control layer. AVPlayerViewController's grey
    /// controls are disabled, so no second set of buttons can overlap ours
    /// while the stream is resolving.
    private var playerControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Collapse into the bottom-right mini window (playback keeps
                // running); the player page dismisses.
                controlButton(system: "chevron.down", size: 18) { playback.minimize() }
                Spacer()
                if tv.name != nil {
                    controlButton(system: "airplayvideo", size: 16, action: cast)
                }
                controlButton(system: subtitles ? "captions.bubble.fill" : "captions.bubble", size: 16) {
                    subtitles.toggle()
                }
                controlButton(system: "gearshape", size: 16) { activeSheet = .settings }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Spacer()

            if !playback.resolving {
                HStack(spacing: 10) {
                    controlButton(system: playback.playing ? "pause.fill" : "play.fill", size: 15) {
                        if playback.playing { playback.player.pause() } else { playback.resume() }
                    }
                    Text(timeString(playhead))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(radius: 1)
                    Slider(value: $playhead, in: 0...max(duration, 1), onEditingChanged: { editing in
                        self.seeking = editing
                        if !editing { self.playback.seek(self.playhead) }
                    })
                    .accentColor(.red)
                    Text(timeString(duration))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(radius: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private func controlButton(system: String, size: CGFloat,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .padding(8)
                .background(Circle().fill(Color.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private func startTicker() {
        ticker?.invalidate()
        let player = playback.player
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let current = player.currentTime().seconds
            let total = player.currentItem?.duration.seconds ?? 0
            DispatchQueue.main.async {
                if !self.seeking, current.isFinite { self.playhead = current }
                if total.isFinite { self.duration = total }
            }
        }
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
                       label: L10n.tr("common.save"),
                       active: library.saved.contains(where: { $0.id == video.id })) {
                    // Choose which playlist to save into.
                    activeSheet = .save
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

            // Comments row opens the bottom-half comments panel in place.
            Button {
                withAnimation(.easeOut(duration: 0.25)) { showComments = true }
            } label: {
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
        .background(Color(UIColor.systemBackground))
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

/// The You tab, styled after the YouTube tablet app: account header,
/// horizontally scrolling History/Playlists shelves, then a settings-style
/// list. Downloads stays as its own entry right below Your videos.
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var tv: Television
    @ObservedObject private var account = Account.shared
    @ObservedObject private var playlists = PlaylistsStore.shared
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showSignIn = false
    @State private var showChannel = false
    @State private var confirmSignOut = false
    @State private var searchText = ""

    enum Collection: String {
        case myVideos, downloads, films, watchTime
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    accountHeader
                    if !library.history.isEmpty {
                        shelf(title: L10n.tr("you.history"), videos: library.history)
                    }
                    playlistsArea
                    VStack(spacing: 0) {
                        row(icon: "video", title: L10n.tr("you.myVideos"), kind: .myVideos)
                        row(icon: "arrow.down.circle", title: L10n.tr("common.download"), kind: .downloads)
                        row(icon: "film", title: L10n.tr("you.films"), kind: .films)
                        row(icon: "clock", title: L10n.tr("you.watchTime"), kind: .watchTime)
                    }
                    .padding(.top, 6)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Avatar on the LEFT at its original 54pt size; name sits
                // beside it. Tapping the avatar opens the channel page; the
                // chevron reveals account actions (switch / sign out).
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 6) {
                        Button { showChannel = true } label: { accountAvatar(size: 54) }
                            .buttonStyle(.plain)
                        if account.isSignedIn {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.accountName ?? L10n.tr("you.signedIn"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary).lineLimit(1)
                                Text("@" + (account.accountName ?? "you"))
                                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                            Menu {
                                Button { showChannel = true } label: {
                                    Label(L10n.tr("you.viewChannel"), systemImage: "person.circle")
                                }
                                Button { showSignIn = true } label: {
                                    Label(L10n.tr("you.switchAccount"), systemImage: "arrow.left.arrow.right")
                                }
                                Button { confirmSignOut = true } label: {
                                    Label(L10n.tr("settings.signOut"), systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption).foregroundColor(.primary)
                            }
                        } else {
                            Button { showSignIn = true } label: {
                                Text(L10n.tr("signin.button"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    // Leave a little breathing room below the system status
                    // bar: a 54pt avatar in a 44pt nav bar sits too high.
                    .offset(y: 4)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { } label: { Image(systemName: "bell") }
                        Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            Task {
                await account.validateSession()
                await playlists.load(force: true)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(tv) }
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .sheet(isPresented: $showChannel) {
            ChannelView(avatar: account.avatarImage, name: account.accountName)
        }
        .actionSheet(isPresented: $confirmSignOut) {
            ActionSheet(
                title: Text(L10n.shared.effective == .simplifiedChinese
                    ? "退出登录并重新授权？"
                    : "Sign out and re-authorize?"),
                buttons: [
                    .destructive(Text(L10n.tr("settings.signOut"))) { account.signOut() },
                    .cancel()
                ]
            )
        }
        .sheet(isPresented: $showSearch) {
            NavigationView {
                VStack {
                    TextField(L10n.tr("action.search"), text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle()).padding()
                    Button(L10n.tr("action.search")) {
                        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else { return }
                        showSearch = false
                        Task {
                            await Feed.shared.load(.search(query))
                            NotificationCenter.default.post(name: .switchToHomeTab, object: nil)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    Spacer()
                }
                .navigationTitle(L10n.tr("action.search"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.tr("common.ok")) { showSearch = false }
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }

    /// Reusable circular account avatar: real Google photo, a remote URL, or
    /// an initial-letter gradient placeholder while signed out.
    @ViewBuilder
    private func accountAvatar(size: CGFloat) -> some View {
        if let image = account.avatarImage {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
        } else if let url = account.avatarURL {
            RemoteThumbnail(url: url)
                .frame(width: size, height: size).clipped().clipShape(Circle())
        } else {
            Circle()
                .fill(LinearGradient(gradient: Gradient(colors: [Color.blue, Color(UIColor.systemTeal)]),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(
                    Text((account.accountName ?? "Y").prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white)
                )
        }
    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    Button { } label: { Text(L10n.tr("you.creator")) }
                    Button { } label: { Text(L10n.tr("you.googleAccount")) }
                    Button { } label: { Text(L10n.tr("you.incognito")) }
                    Button { showSettings = true } label: { Text(L10n.tr("you.shareSettings")) }
                }
                .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    /// Real account playlists from InnerTube; falls back to the local
    /// watch-later list while loading or when signed out.
    @ViewBuilder
    private var playlistsArea: some View {
        if !playlists.playlists.isEmpty {
            playlistsShelf
        } else if playlists.loading {
            HStack {
                Spacer()
                ProgressView(L10n.tr("common.loading"))
                Spacer()
            }.padding(.vertical, 24)
        } else if !library.saved.isEmpty {
            shelf(title: L10n.tr("you.watchLater"), videos: library.saved)
        } else {
            // No playlists and no cache: explain why and offer a way in
            // instead of leaving an empty gap.
            VStack(spacing: 8) {
                Text(playlists.message ?? L10n.tr("you.playlists.empty"))
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    if account.isSignedIn {
                        Task { await playlists.load(force: true) }
                    } else {
                        showSignIn = true
                    }
                } label: {
                    Text(account.isSignedIn ? L10n.tr("common.retry") : L10n.tr("signin.button"))
                        .font(.caption).foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private var playlistsShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("you.playlists")).font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(playlists.playlists.prefix(20)) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    Group {
                                        if let url = playlist.thumbnail {
                                            RemoteThumbnail(url: url)
                                        } else {
                                            Rectangle().fill(Color.secondary.opacity(0.15))
                                                .overlay(Image(systemName: "list.bullet.rectangle")
                                                    .font(.system(size: 28)).foregroundColor(.secondary))
                                        }
                                    }
                                    .frame(width: 190, height: 107).clipped().cornerRadius(8)
                                    if let count = playlist.count {
                                        HStack(spacing: 3) {
                                            Image(systemName: "line.3.horizontal")
                                                .font(.system(size: 10, weight: .bold))
                                            Text("\(count)").font(.system(size: 11, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.black.opacity(0.8)).cornerRadius(4)
                                        .padding(6)
                                    }
                                }
                                Text(playlist.title)
                                    .font(.caption).foregroundColor(.primary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Text(L10n.tr("you.private.playlist"))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            .frame(width: 190, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
        }.padding(.bottom, 14)
    }

    private func shelf(title: String, videos: [Video]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(videos.prefix(16)) { video in
                        Button { playback.open(video) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RemoteThumbnail(url: video.thumbnailURL)
                                    .frame(width: 190, height: 107).clipped().cornerRadius(8)
                                Text(video.title)
                                    .font(.caption).foregroundColor(.primary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .frame(width: 190, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
        }.padding(.bottom, 14)
    }

    private func row(icon: String, title: String, kind: Collection) -> some View {
        NavigationLink(destination: collectionView(kind)) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18)).frame(width: 24).foregroundColor(.primary)
                Text(title).font(.body).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func collectionView(_ kind: Collection) -> some View {
        if kind == .watchTime {
            EmptyStateView(title: L10n.tr("you.watchTime"), systemImage: "clock",
                           description: Text(L10n.tr("you.watchTime.desc")))
                .navigationTitle(L10n.tr("you.watchTime"))
        } else if kind == .films {
            // Films opens the real YouTube movies storefront.
            MoviesView()
        } else {
            CollectionListView(kind: kind)
        }
    }
}

/// Films page, mirroring the YouTube movies storefront: a header, sub-tabs
/// (Browse / Free with ads / Live / Purchases / Store) and titled shelves of
/// portrait-poster movie cards.
struct MoviesView: View {
    @EnvironmentObject var playback: Playback
    @ObservedObject private var store = MoviesStore.shared
    @State private var tab: MoviesTab = .browse

    private func tabLabel(_ tab: MoviesTab) -> String {
        switch tab {
        case .browse: return L10n.tr("movies.tab.browse")
        case .free: return L10n.tr("movies.tab.free")
        case .live: return L10n.tr("movies.tab.live")
        case .purchases: return L10n.tr("movies.tab.purchases")
        case .store: return L10n.tr("movies.tab.store")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12).fill(Color.red)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "film.fill").foregroundColor(.white)
                        .font(.system(size: 20)))
                Text(L10n.tr("you.films")).font(.system(size: 28, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(MoviesTab.allCases) { candidate in
                        Button {
                            guard tab != candidate else { return }
                            tab = candidate
                        } label: {
                            VStack(spacing: 6) {
                                Text(tabLabel(candidate))
                                    .font(.system(size: 14,
                                                  weight: tab == candidate ? .semibold : .regular))
                                    .foregroundColor(tab == candidate ? .primary : .secondary)
                                Rectangle()
                                    .fill(tab == candidate ? Color.primary : Color.clear)
                                    .frame(height: 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            if store.loading && store.sections.isEmpty {
                VStack { ProgressView(L10n.tr("common.loading")).padding(.top, 60) }
            } else if let message = store.message, store.sections.isEmpty {
                EmptyStateView(title: message, systemImage: "film",
                               description: Text(L10n.tr("common.retry")),
                               buttonTitle: L10n.tr("common.retry")) {
                    Task { await store.load(tab: tab, force: true) }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(store.sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.title).font(.headline)
                                    .padding(.horizontal, 16)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
                                          spacing: 16) {
                                    ForEach(section.movies) { movie in
                                        MovieCard(movie: movie)
                                            .onAppear { FastMedia.prewarm(movie.id) }
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { Task { await store.load(tab: tab) } }
        .onChange(of: tab) { _ in
            Task { await store.load(tab: tab) }
        }
    }
}

/// A movie poster card: portrait poster, title, genre • year, price badge
/// and age rating, matching the mobile movies page.
struct MovieCard: View {
    @EnvironmentObject var playback: Playback
    let movie: MovieItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let url = movie.poster {
                        RemoteThumbnail(url: url)
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "film").foregroundColor(.secondary))
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipped().cornerRadius(8)
                if let duration = movie.duration {
                    Text(duration).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.8)).cornerRadius(4)
                        .padding(5)
                }
            }
            Text(movie.title)
                .font(.system(size: 13, weight: .medium)).foregroundColor(.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
            if let info = movie.info {
                Text(info).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            if let badge = movie.badge {
                Text(badge).font(.caption2.weight(.medium)).foregroundColor(.green).lineLimit(1)
            }
            if let rating = movie.rating {
                Text(rating)
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { playback.open(Video(id: movie.id, title: movie.title)) }
    }
}

/// Videos inside an account playlist, loaded from InnerTube on open.
struct PlaylistDetailView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    let playlist: YTPlaylist
    @State private var videos: [Video] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                VStack { ProgressView(L10n.tr("common.loading")).padding(.top, 60) }
            } else if videos.isEmpty {
                EmptyStateView(title: playlist.title, systemImage: "list.bullet.rectangle",
                               description: Text(L10n.tr("playlist.empty")))
            } else {
                List(videos) { video in
                    Button { playback.open(video) } label: {
                        HStack {
                            RemoteThumbnail(url: video.thumbnailURL)
                                .frame(width: 120, height: 68).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(video.title).lineLimit(3).foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .contextMenu {
                        Button(L10n.tr("you.addToQueue")) { playback.enqueue(video) }
                        Button(library.saved.contains(where: { $0.id == video.id })
                               ? L10n.tr("you.removeSaved") : L10n.tr("card.watchLater")) {
                            library.bookmark(video)
                        }
                        ShareButton(url: video.watchURL)
                    }
                }.listStyle(.plain)
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if videos.count > 1 {
                    Button {
                        playback.playCollection(videos)
                    } label: {
                        Label(L10n.tr("you.playAll"),
                              systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
            }
        }
        .onAppear {
            guard loading else { return }
            Task {
                videos = await PlaylistsStore.shared.videos(of: playlist)
                loading = false
            }
        }
    }
}

/// Video list behind a You-tab row (Your videos / Downloads / Films).
struct CollectionListView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    let kind: LibraryView.Collection

    private var videos: [Video] {
        switch kind {
        case .downloads: return library.downloads
        case .films: return library.history
        default: return library.saved
        }
    }

    private var title: String {
        switch kind {
        case .downloads: return L10n.tr("common.download")
        case .films: return L10n.tr("you.films")
        default: return L10n.tr("you.myVideos")
        }
    }

    private var description: String {
        switch kind {
        case .downloads: return L10n.tr("you.downloads.desc")
        case .films: return L10n.tr("you.history.desc")
        default: return L10n.tr("you.saved.desc")
        }
    }

    private var icon: String {
        switch kind {
        case .downloads: return "arrow.down.circle"
        case .films: return "film"
        default: return "rectangle.stack"
        }
    }

    var body: some View {
        Group {
            if videos.isEmpty {
                EmptyStateView(title: title, systemImage: icon, description: Text(description))
            } else {
                List(videos) { video in
                    Button { playback.open(video) } label: {
                        HStack {
                            RemoteThumbnail(url: video.thumbnailURL)
                                .frame(width: 90, height: 52).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            Text(video.title).lineLimit(3).foregroundColor(.primary)
                        }
                    }
                    .contextMenu {
                        Button(L10n.tr("you.addToQueue")) { playback.enqueue(video) }
                        Button(library.saved.contains(where: { $0.id == video.id })
                               ? L10n.tr("you.removeSaved") : L10n.tr("card.watchLater")) {
                            library.bookmark(video)
                        }
                        ShareButton(url: video.watchURL)
                        if kind == .downloads {
                            Button(L10n.tr("you.deleteDownload")) {
                                do { try library.removeDownload(video) }
                                catch { playback.message = error.localizedDescription }
                            }.foregroundColor(.red)
                        }
                    }
                }.listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if videos.count > 1 {
                    Menu {
                        Button(L10n.tr("you.playAll")) { playback.playCollection(videos) }
                        Button(L10n.tr("you.shuffle")) { playback.playCollection(videos.shuffled()) }
                    } label: {
                        Label(L10n.tr("you.play"), systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let switchToHomeTab = Notification.Name("switchToHomeTab")
}
