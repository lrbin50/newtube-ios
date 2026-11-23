import SwiftUI
import AVKit
import WebKit

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
        TabView(selection: $selection) {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search or paste a YouTube link", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.search).onSubmit { browser.search(query) }
                    }
                    .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal).padding(.bottom, 6)
                    if let issue = browser.issue {
                        ContentUnavailableView {
                            Label("Unable to load YouTube", systemImage: "wifi.exclamationmark")
                        } description: { Text(issue) } actions: {
                            Button("Try again") {
                                if browser.web.url != nil { browser.web.reload() } else { browser.load(path: "/") }
                            }
                        }
                    } else { BrowseSurface(browser: browser) }
                }
                .navigationTitle("NewTube").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") { browser.web.goBack() }.disabled(!browser.canGoBack)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Home") { browser.load(path: "/") }
                            Button("Subscriptions") { browser.load(path: "/feed/subscriptions") }
                            Button("YouTube library") { browser.load(path: "/feed/library") }
                            Button("Reload") { browser.web.reload() }
                        } label: { Label("Browse destinations", systemImage: "ellipsis.circle") }
                    }
                }
            }.tabItem { Label("Browse", systemImage: "play.rectangle.on.rectangle") }.tag(0)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(1)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let video = playback.current {
                PlayerPanel(video: video, openWeb: {
                    playback.close()
                    webPlayer = video
                }, playerHeight: height == .compact ? 105 : width == .regular ? 260 : 190)
            }
        }
        .onAppear {
            browser.play = { playback.open($0) }
            if browser.web.url == nil && !browser.web.isLoading { browser.load(path: "/") }
        }
        .sheet(item: $webPlayer) { video in WebPlayer(url: video.watchURL).ignoresSafeArea() }
        .alert("NewTube", isPresented: Binding(get: { playback.message != nil }, set: { if !$0 { playback.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(playback.message ?? "") }
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
                }.buttonStyle(.bordered)
            }
            // Keep the AVKit controller attached while switching between compact and full controls.
            PlayerSurface(player: playback.player)
                .frame(height: playback.expanded && playback.failure == nil ? playerHeight : 0)
                .clipped().accessibilityHidden(!playback.expanded)
                .overlay { if playback.resolving && playback.expanded { ProgressView().tint(.white) } }
            HStack {
                Button {
                    playback.expanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: playback.expanded ? "chevron.down" : "chevron.up")
                        VStack(alignment: .leading) {
                            Text(playback.communityTitle ?? video.title).font(.subheadline.bold()).lineLimit(2)
                            if let count = playback.dislikes {
                                Text("\(count.formatted()) estimated dislikes").font(.caption2).foregroundStyle(.secondary)
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
                    Menu(playback.downloading == nil ? "Download" : "Downloading…") {
                        Button("Video and audio") { playback.save(video, audioOnly: false) }
                        Button("Audio only") { playback.save(video, audioOnly: true) }
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
                    ShareLink(item: video.watchURL)
                    Button("Close player", role: .destructive) { playback.close() }
                } label: { Label("Player actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
            }.padding(.horizontal).padding(.vertical, 6)
        }.background(.regularMaterial)
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
        NavigationStack {
            VStack {
                Picker("Collection", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0) }
                }.pickerStyle(.segmented).padding(.horizontal)
                if videos.isEmpty {
                    ContentUnavailableView(category, systemImage: category == "Downloads" ? "arrow.down.circle" : "rectangle.stack",
                        description: Text(category == "Downloads" ? "Download a video or its audio from the player menu to play it offline."
                            : category == "History" ? "Videos you play appear here." : "Save videos using Watch later in the player menu."))
                } else {
                    List(videos) { video in
                        Button { playback.open(video) } label: {
                            HStack {
                                AsyncImage(url: video.thumbnailURL) { image in image.resizable().scaledToFill() } placeholder: {
                                    Image(systemName: "film").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                                }.frame(width: 90, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(video.title).lineLimit(3).foregroundStyle(.primary)
                            }
                        }
                        .contextMenu {
                            Button("Add to queue") { playback.enqueue(video) }
                            Button(library.saved.contains(where: { $0.id == video.id }) ? "Remove from Watch later" : "Watch later") { library.bookmark(video) }
                            ShareLink(item: video.watchURL)
                            if category == "Downloads" { Button("Delete download", role: .destructive) {
                                do { try library.removeDownload(video) } catch { playback.message = error.localizedDescription }
                            } }
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("Library")
            .toolbar {
                if videos.count > 1 {
                    Menu("Play collection", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        Button("Play all") { play(videos) }
                        Button("Shuffle") { play(videos.shuffled()) }
                    }
                }
            }
        }
    }
    private func play(_ items: [Video]) {
        playback.playCollection(items)
    }
}
