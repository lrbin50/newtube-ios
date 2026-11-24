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
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            BrowseView().tabItem { Label("Browse", systemImage: "play.rectangle.on.rectangle") }.tag(0)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(1)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .onAppear {
            browser.play = { playback.open($0) }
        }
        // Any video being opened (from the web view or the Library tab) takes over
        // the whole screen instead of the old bottom third panel.
        .fullScreenCover(item: Binding(get: { playback.current }, set: { _ in })) { video in
            FullScreenPlayerView(video: video)
                .environmentObject(library)
                .environmentObject(playback)
                .environmentObject(tv)
        }
        .alert(isPresented: Binding(get: { playback.message != nil }, set: { if !$0 { playback.message = nil } })) {
            Alert(title: Text("NewTube"), message: Text(playback.message ?? ""), dismissButton: .default(Text("OK")))
        }
    }
}

/// Native home built on InnerTube instead of the YouTube web shell.
/// Shows the signed-in recommendation feed, subscriptions and search results.
struct BrowseView: View {
    @EnvironmentObject var playback: Playback
    @ObservedObject private var account = Account.shared
    @ObservedObject private var feed = Feed.shared
    @State private var query = ""
    @State private var showSignIn = false

    private var isSearching: Bool {
        if case .search = feed.mode { return true }
        return false
    }

    var body: some View {
        NavigationView {
            Group {
                if !account.isSignedIn {
                    SignInView(onSignIn: { showSignIn = true })
                } else {
                    feedContent
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { Task { await feed.load(.home) } } label: { Label("Home", systemImage: "house") }
                        Button { Task { await feed.load(.subscriptions) } } label: { Label("Subscriptions", systemImage: "rectangle.stack") }
                        Button { showSignIn = true } label: { Label("Account", systemImage: "person.circle") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .onAppear {
            if account.isSignedIn, feed.videos.isEmpty { Task { await feed.load(.home) } }
        }
    }

    private var title: String {
        switch feed.mode {
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .search(let q): return q
        }
    }

    private var feedContent: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search YouTube", text: $query, onCommit: submitSearch)
                    .autocapitalization(.none).disableAutocorrection(true)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(10)
            .padding(.horizontal, 12).padding(.vertical, 6)

            if feed.loading && feed.videos.isEmpty {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if let message = feed.message, feed.videos.isEmpty {
                EmptyStateView(title: message, systemImage: "exclamationmark.triangle",
                               description: Text("Try signing in again from the Account menu."),
                               buttonTitle: "Retry") {
                    Task { await feed.load(.home) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible())], spacing: 16) {
                        ForEach(feed.videos) { video in
                            Button { playback.open(video.video) } label: {
                                FeedCard(video: video)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if video == feed.videos.last { Task { await feed.loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    if feed.loading { ProgressView().padding() }
                }
            }
        }
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Pasted YouTube link plays directly.
        if let url = URL(string: text), let video = Video.parse(url) {
            playback.open(video); return
        }
        Task { await feed.load(.search(text)) }
    }
}

struct FeedCard: View {
    let video: FeedVideo
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RemoteThumbnail(url: video.thumbnailURL)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped().cornerRadius(8)
                if let duration = video.duration {
                    Text(duration).font(.caption2).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.75)).cornerRadius(3)
                        .padding(6)
                }
            }
            Text(video.title).font(.subheadline).foregroundColor(.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                if let channel = video.channel { Text(channel) }
                if let views = video.views { Text("· \(views)") }
                if let date = video.published { Text("· \(date)") }
            }
            .font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

/// First-run / signed-out prompt.
struct SignInView: View {
    let onSignIn: () -> Void
    var body: some View {
        EmptyStateView(
            title: "Sign in to YouTube",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Sign in with your Google account to see personalized recommendations, subscriptions and search."),
            buttonTitle: "Sign in",
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
    let video: Video

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                if landscape {
                    // Landscape: nothing but the player.
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
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            Spacer()
                        }.padding()
                        Spacer()
                    }
                } else {
                    // Portrait: player on top, details scrolling underneath.
                    ScrollView {
                        VStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                PlayerSurface(player: playback.player)
                                    .frame(height: geo.size.width * 9 / 16)
                                if playback.resolving { ProgressView().accentColor(.white) }
                                // Back button stays reachable while loading and playing.
                                Button { playback.close() } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
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
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title and stats
            VStack(alignment: .leading, spacing: 4) {
                Text(playback.communityTitle ?? video.title)
                    .font(.headline).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let views = meta.views { Text(views) }
                    if let date = meta.published { Text("· \(date)") }
                    if let count = playback.dislikes { Text("· \(count) dislikes") }
                }
                .font(.caption).foregroundColor(.secondary)
            }

            // Action buttons
            HStack(spacing: 8) {
                action(system: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                       label: meta.likes ?? "Like", active: liked) {
                    liked.toggle(); if liked { disliked = false }
                }
                action(system: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                       label: "Dislike", active: disliked) {
                    disliked.toggle(); if disliked { liked = false }
                }
                action(system: "square.and.arrow.up", label: "Share", active: false, tap: openWeb)
                action(system: "arrow.down.to.line", label: "Download", active: false) {
                    playback.save(video, audioOnly: false)
                }
                action(system: library.saved.contains(where: { $0.id == video.id }) ? "bookmark.fill" : "bookmark",
                       label: "Save", active: library.saved.contains(where: { $0.id == video.id })) {
                    library.bookmark(video)
                }
            }

            // Channel row
            HStack(spacing: 12) {
                Circle().fill(Color.accentColor.opacity(0.2))
                    .overlay(Text((meta.author ?? "?").prefix(1).uppercased())
                        .font(.headline).foregroundColor(.accentColor))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.author ?? "YouTube channel").font(.subheadline.bold())
                    Text("Channel").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button { subscribed.toggle() } label: {
                    Text(subscribed ? "Subscribed" : "Subscribe")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(subscribed ? Color.secondary.opacity(0.2) : Color.primary)
                        .foregroundColor(subscribed ? .primary : Color(UIColor.systemBackground))
                        .cornerRadius(20)
                }
            }

            // Comments
            Button(action: openWeb) {
                HStack {
                    Image(systemName: "bubble.left").foregroundColor(.primary)
                    Text("Comments").foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(.secondary)
                }
                .padding().background(Color.secondary.opacity(0.1)).cornerRadius(10)
            }

            // Up next
            if !related.isEmpty {
                Text("Up next").font(.headline)
                ForEach(related) { item in
                    Button { playback.open(item) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RemoteThumbnail(url: item.thumbnailURL)
                                .frame(width: 120, height: 68).clipped()
                                .cornerRadius(6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline).lineLimit(3)
                                    .foregroundColor(.primary)
                                Text(item.id).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            // More actions
            Menu {
                Button("Download audio only") { playback.save(video, audioOnly: true) }
                if let name = tv.name { Button("Play on \(name)", action: cast) }
                Button("Open in YouTube", action: openWeb)
            } label: {
                Label("More actions", systemImage: "ellipsis.circle")
            }
        }
        .padding()
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

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @State private var category = "Watch later"
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
            }.navigationTitle("Library")
            .toolbar {
                if videos.count > 1 {
                    Menu {
                        Button("Play all") { play(videos) }
                        Button("Shuffle") { play(videos.shuffled()) }
                    } label: {
                        Label("Play collection", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    private func play(_ items: [Video]) {
        playback.playCollection(items)
    }
}
