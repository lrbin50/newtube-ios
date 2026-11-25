import SwiftUI

/// Subscriptions tab — channel-first browsing (layout A):
/// a pinned title bar, a horizontal strip of subscribed-channel avatars that
/// filters the feed, and a two-column video grid below. Uses real InnerTube
/// data via SubscriptionsStore; no placeholder content.
struct SubscriptionsView: View {
    @EnvironmentObject var playback: Playback
    @ObservedObject private var account = Account.shared
    @ObservedObject private var store = SubscriptionsStore.shared
    @ObservedObject private var avatars = ChannelAvatarStore.shared
    @State private var showSignIn = false
    @State private var showSearch = false
    @State private var query = ""

    var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width > geo.size.height ? 3 : 2
            ZStack(alignment: .top) {
                if !account.isSignedIn {
                    SignInView(onSignIn: { showSignIn = true })
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 132) // room for pinned bar + channel strip
                            if store.loading && store.videos.isEmpty {
                                VStack { ProgressView(L10n.tr("common.loading")).padding(.top, 80) }
                            } else if let message = store.message, store.videos.isEmpty {
                                EmptyStateView(title: message, systemImage: "exclamationmark.triangle",
                                               description: Text(L10n.tr("subscriptions.empty")),
                                               buttonTitle: L10n.tr("common.retry")) {
                                    Task { await store.load(force: true) }
                                }
                            } else {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                                    spacing: 18
                                ) {
                                    ForEach(store.videos) { video in
                                        FeedCard(video: video)
                                            .contentShape(Rectangle())
                                            .onTapGesture { playback.open(video.video) }
                                            .onAppear {
                                                FastMedia.prewarm(video.id)
                                                if video.id == store.videos.last?.id {
                                                    Task { await store.loadMore() }
                                                }
                                            }
                                    }
                                }
                                .padding(.horizontal, 10)
                                if store.loadingMore { ProgressView().padding() }
                                Color.clear.frame(height: 40)
                                    .onAppear { Task { await store.loadMore() } }
                            }
                        }
                    }
                }

                if account.isSignedIn {
                    VStack(spacing: 0) {
                        topBar
                        channelStrip
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
            if account.isSignedIn { Task { await store.load() } }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(L10n.tr("tab.subscriptions"))
                .font(.system(size: 20, weight: .bold))
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundColor(.primary)
            }
            Button { } label: {
                Image(systemName: "square.on.square").font(.system(size: 18)).foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                channelChip(id: "all", name: L10n.tr("chip.all"), url: nil)
                ForEach(store.channels) { channel in
                    channelChip(id: channel.id, name: channel.name, url: channel.avatarURL)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    /// A representative video id for a channel, used only to resolve its avatar
    /// via the anonymous `next` endpoint when the feed did not carry one.
    private func sampleVideoID(for channelName: String) -> String? {
        store.videos.first { $0.channel == channelName }?.id
    }

    @ViewBuilder
    private func channelChip(id: String, name: String, url: URL?) -> some View {
        let selected = store.selectedChannelId == id
        let resolved = url ?? avatars.byChannel[name]
        Button { Task { await store.select(id) } } label: {
            VStack(spacing: 5) {
                Group {
                    if let resolved {
                        RemoteThumbnail(url: resolved)
                            .frame(width: 46, height: 46).clipped().clipShape(Circle())
                    } else if id == "all" {
                        Circle().fill(Color(UIColor.secondarySystemFill))
                            .overlay(Image(systemName: "square.grid.2x2")
                                .font(.system(size: 18)).foregroundColor(.primary))
                            .frame(width: 46, height: 46)
                    } else {
                        Circle().fill(Color.accentColor.opacity(0.25))
                            .overlay(Text(name.prefix(1).uppercased())
                                .font(.system(size: 18, weight: .bold)).foregroundColor(.accentColor))
                            .frame(width: 46, height: 46)
                    }
                }
                .overlay(Circle().stroke(selected ? Color.primary : Color.clear, lineWidth: 2))
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: 62)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            // Avatar resolution is deferred to a low-priority task so the video
            // grid (and its thumbnails) loads first. Reuses any avatar already
            // resolved on the home feed via the shared ChannelAvatarStore.
            if id != "all", resolved == nil {
                avatars.load(channel: name, sampleVideoID: sampleVideoID(for: name))
            }
        }
    }

    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = URL(string: text), let video = Video.parse(url) {
            playback.open(video); showSearch = false; return
        }
        showSearch = false
        Task { await store.loadSearch(query: text) }
    }
}
