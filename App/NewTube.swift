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
    @State private var query = ""
    @State private var selection = 0
    @State private var webPlayer: Video?
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.verticalSizeClass) private var height

    var body: some View {
        let playerHeight: CGFloat = height == .compact ? 105 : width == .regular ? 260 : 190
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                NavigationView {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                            TextField("Search or paste a YouTube link", text: $query, onCommit: { browser.search(query) })
                                .autocapitalization(.none).disableAutocorrection(true)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
                        .padding(.horizontal).padding(.bottom, 6)
                        if let issue = browser.issue {
                            EmptyStateView(
                                title: "Unable to load YouTube",
                                systemImage: "wifi.exclamationmark",
                                description: Text(issue),
                                buttonTitle: "Try again"
                            ) {
                                if browser.web.url != nil { browser.web.reload() } else { browser.load(path: "/") }
                            }
                        } else { BrowseSurface(browser: browser) }
                    }
                    .navigationTitle("NewTube").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button { browser.web.goBack() } label: {
                                Label("Back", systemImage: "chevron.backward")
                            }.disabled(!browser.canGoBack)
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                Button("Home") { browser.load(path: "/") }
                                Button("Subscriptions") { browser.load(path: "/feed/subscriptions") }
                                Button("YouTube library") { browser.load(path: "/feed/library") }
                                Button("Reload") { browser.web.reload() }
                            } label: { Label("Browse destinations", systemImage: "ellipsis.circle") }
                        }
                    }
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem { Label("Browse", systemImage: "play.rectangle.on.rectangle") }.tag(0)
                LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(1)
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
            }
            .padding(.bottom, playback.current == nil ? 0 : playerHeight + 56)
            if let video = playback.current {
                PlayerPanel(video: video, openWeb: {
                    playback.close()
                    webPlayer = video
                }, playerHeight: playerHeight)
                .padding(.bottom, 49)
            }
        }
        .onAppear {
            browser.play = { playback.open($0) }
            if browser.web.url == nil && !browser.web.isLoading { browser.load(path: "/") }
        }
        .sheet(item: $webPlayer) { video in WebPlayer(url: video.watchURL).ignoresSafeArea() }
        .alert(isPresented: Binding(get: { playback.message != nil }, set: { if !$0 { playback.message = nil } })) {
            Alert(title: Text("NewTube"), message: Text(playback.message ?? ""), dismissButton: .default(Text("OK")))
        }
    }
}

struct PlayerPanel: View {
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var library: Library
    @EnvironmentObject var tv: Television
    let video: Video
    let openWeb: () -> Void
    let playerHeight: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Divider()
            if playback.expanded, let failure = playback.failure {
                Text(failure).font(.caption).lineLimit(3).padding(.horizontal)
                HStack {
                    Button("Retry") { playback.open(video) }
                    Button("Use web player", action: openWeb)
                }
            }
            // Keep the AVKit controller attached while switching between compact and full controls.
            PlayerSurface(player: playback.player)
                .frame(height: playback.expanded && playback.failure == nil ? playerHeight : 0)
                .clipped().accessibilityHidden(!playback.expanded)
                .overlay(Group {
                    if playback.resolving && playback.expanded { ProgressView().accentColor(.white) }
                })
            HStack {
                Button {
                    playback.expanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: playback.expanded ? "chevron.down" : "chevron.up")
                        VStack(alignment: .leading) {
                            Text(playback.communityTitle ?? video.title).font(.subheadline.bold()).lineLimit(2)
                            if let count = playback.dislikes {
                                Text("\(count) estimated dislikes").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityLabel("Toggle player, \(video.title)")
                if !playback.expanded {
                    Button(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill") { playback.toggle() }
                    .labelStyle(.iconOnly)
                }
                Menu {
                    Button(library.saved.contains(where: { $0.id == video.id }) ? "Remove from Watch later" : "Watch later") { library.bookmark(video) }
                    if !playback.queue.isEmpty { Button("Play next (\(playback.queue.count) queued)") { playback.next() } }
                    Menu {
                        Button("Video and audio") { playback.save(video, audioOnly: false) }
                        Button("Audio only") { playback.save(video, audioOnly: true) }
                    } label: {
                        Label(playback.downloading == nil ? "Download" : "Downloading…", systemImage: "arrow.down.circle")
                    }.disabled(playback.downloading != nil)
                    if let name = tv.name {
                        Button("Play on \(name)") {
                            Task {
                                do {
                                    try await tv.cast(video, queue: playback.queue, position: playback.player.currentTime().seconds)
                                    if playback.current?.id == video.id { playback.player.pause() }
                                } catch { playback.message = "Could not send to TV. " + error.localizedDescription }
                            }
                        }
                    }
                    Button("Open YouTube player and comments", action: openWeb)
                    ShareButton(url: video.watchURL)
                    Button("Close player") { playback.close() }.foregroundColor(.red)
                } label: { Label("Player actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
            }.padding(.horizontal).padding(.vertical, 6)
        }.background(Color.secondary.opacity(0.12))
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
