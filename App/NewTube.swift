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
            if browser.web.url == nil && !browser.web.isLoading { browser.load(path: "/") }
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

/// Immersive browser: the YouTube mobile site fills the whole tab, with no app
/// title bar or duplicate search field. Navigation is available from a small
/// translucent floating menu, so the page itself stays untouched.
struct BrowseView: View {
    @EnvironmentObject var browser: Browser

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let issue = browser.issue {
                    EmptyStateView(
                        title: "Unable to load YouTube",
                        systemImage: "wifi.exclamationmark",
                        description: Text(issue),
                        buttonTitle: "Try again"
                    ) {
                        if browser.web.url != nil { browser.web.reload() } else { browser.load(path: "/") }
                    }
                } else {
                    BrowseSurface(browser: browser).edgesIgnoringSafeArea(.all)
                }
            }
            Menu {
                Button { browser.web.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!browser.canGoBack)
                Button { browser.load(path: "/") } label: { Label("Home", systemImage: "house") }
                Button { browser.load(path: "/feed/subscriptions") } label: { Label("Subscriptions", systemImage: "rectangle.stack") }
                Button { browser.load(path: "/feed/library") } label: { Label("YouTube library", systemImage: "folder") }
                Button { browser.web.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                if let url = browser.web.url {
                    Button { UIApplication.shared.open(url) } label: { Label("Open in Safari", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.primary)
                    .padding(7)
                    .background(Circle().fill(Color(UIColor.systemBackground).opacity(0.8)))
            }
            .padding()
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
                            ZStack {
                                PlayerSurface(player: playback.player)
                                    .frame(height: geo.size.width * 9 / 16)
                                if playback.resolving { ProgressView().accentColor(.white) }
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
        .onAppear(perform: load)
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
        Task {
            let loaded = await Meta.load(video)
            let suggestions = await Meta.related(to: video)
            await MainActor.run { meta = loaded; related = suggestions }
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
