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

/// Full-screen playback page. AVKit supplies the player controls, Picture in
/// Picture and AirPlay; the bars around it provide NewTube specific actions.
struct FullScreenPlayerView: View {
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var library: Library
    @EnvironmentObject var tv: Television
    @State private var webPlayer: Video?
    let video: Video

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { playback.close() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold))
                    }
                    Text(playback.communityTitle ?? video.title)
                        .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                    Menu {
                        Button(library.saved.contains(where: { $0.id == video.id }) ? "Remove from Watch later" : "Watch later") {
                            library.bookmark(video)
                        }
                        Button("Download video") { playback.save(video, audioOnly: false) }
                        Button("Download audio") { playback.save(video, audioOnly: true) }
                        if let name = tv.name {
                            Button("Play on \(name)", action: cast)
                        }
                        Button("Open in YouTube", action: openWeb)
                        ShareButton(url: video.watchURL)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 20))
                    }
                }
                .padding(.horizontal).padding(.vertical, 10)
                .foregroundColor(.white)

                ZStack {
                    PlayerSurface(player: playback.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if playback.resolving {
                        ProgressView().accentColor(.white)
                    }
                }

                if let failure = playback.failure {
                    VStack(spacing: 8) {
                        Text(failure).font(.caption).lineLimit(3)
                            .foregroundColor(.white).multilineTextAlignment(.center)
                        HStack {
                            Button("Retry") { playback.open(video) }
                            Button("Use web player", action: openWeb)
                        }.accentColor(.white)
                    }.padding()
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.communityTitle ?? video.title)
                            .font(.subheadline).foregroundColor(.white).lineLimit(2)
                        if let count = playback.dislikes {
                            Text("\(count) estimated dislikes").font(.caption2).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    if !playback.queue.isEmpty {
                        Button("Next (\(playback.queue.count))") { playback.next() }
                    }
                }
                .padding()
            }
        }
        .sheet(item: $webPlayer) { video in WebPlayer(url: video.watchURL).ignoresSafeArea() }
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
