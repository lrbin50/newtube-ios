import SwiftUI

/// Signed-in user's channel page, opened by tapping the You-tab avatar.
/// Mirrors the YouTube channel layout: big avatar + handle, a "Your channel"
/// style header, Analytics / Edit-channel shortcuts, then the Playlists and
/// Posts tabs. Playlists come from the live InnerTube store so every card can
/// be opened into its real video list.
struct ChannelView: View {
    let avatar: UIImage?
    let name: String?

    @Environment(\.presentationMode) private var presentation
    @ObservedObject private var playlists: PlaylistsStore
    @ObservedObject private var account = Account.shared
    @State private var tab = 0
    @State private var showSearch = false

    init(avatar: UIImage?, name: String?) {
        self.avatar = avatar
        self.name = name
        _playlists = ObservedObject(wrappedValue: PlaylistsStore.shared)
    }

    private var handle: String {
        "@" + (name ?? "you")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    quickActions
                    tabBar
                    if tab == 0 {
                        playlistGrid
                    } else {
                        postsPlaceholder
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { presentation.wrappedValue.dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 18) {
                        Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        Menu {
                            Button { showSearch = true } label: {
                                Label(L10n.tr("action.search"), systemImage: "magnifyingglass")
                            }
                            Button { presentation.wrappedValue.dismiss() } label: {
                                Label(L10n.tr("common.back"), systemImage: "xmark")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear { Task { await playlists.load(force: true) } }
        .sheet(isPresented: $showSearch) { channelSearch }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let avatar {
                    Image(uiImage: avatar).resizable().scaledToFill()
                        .frame(width: 72, height: 72).clipShape(Circle())
                } else {
                    Circle()
                        .fill(LinearGradient(gradient: Gradient(colors: [Color.blue, Color(UIColor.systemTeal)]),
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 72, height: 72)
                        .overlay(Text((name ?? "Y").prefix(1).uppercased())
                            .font(.system(size: 30, weight: .bold)).foregroundColor(.white))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name ?? L10n.tr("you.signedIn"))
                    .font(.system(size: 24, weight: .bold)).foregroundColor(.primary)
                Text(handle).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button { openStudio("https://studio.youtube.com/") } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                    Text(L10n.tr("channel.analytics", fallback: "Analytics"))
                }
                .font(.subheadline).foregroundColor(.primary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Color.secondary.opacity(0.16)).cornerRadius(20)
            }
            Button { openStudio("https://studio.youtube.com/channel/" + (account.channelId ?? "") + "/editing") } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text(L10n.tr("channel.edit", fallback: "Edit channel"))
                }
                .font(.subheadline).foregroundColor(.primary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Color.secondary.opacity(0.16)).cornerRadius(20)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var tabBar: some View {
        HStack(spacing: 28) {
            Button {
                tab = 0
            } label: {
                VStack(spacing: 6) {
                    Text(L10n.tr("you.playlists"))
                        .font(.system(size: 15, weight: tab == 0 ? .semibold : .regular))
                        .foregroundColor(tab == 0 ? .primary : .secondary)
                    Rectangle().fill(tab == 0 ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                }
            }
            Button {
                tab = 1
            } label: {
                VStack(spacing: 6) {
                    Text(L10n.tr("channel.posts", fallback: "Posts"))
                        .font(.system(size: 15, weight: tab == 1 ? .semibold : .regular))
                        .foregroundColor(tab == 1 ? .primary : .secondary)
                    Rectangle().fill(tab == 1 ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                }
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 14)
    }

    // MARK: - Playlists

    private var playlistGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(L10n.tr("channel.latest", fallback: "Latest")).font(.subheadline.bold())
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundColor(.primary).padding(.top, 12)

            if playlists.loading && playlists.playlists.isEmpty {
                HStack { Spacer(); ProgressView(L10n.tr("common.loading")); Spacer() }
                    .padding(.vertical, 40)
            } else if playlists.playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 32)).foregroundColor(.secondary)
                    Text(playlists.message ?? L10n.tr("you.playlists.empty"))
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 50)
            } else {
                // Two-column grid matching the channel page reference.
                ForEach(Array(stride(from: 0, to: playlists.playlists.count, by: 2)), id: \.self) { row in
                    HStack(alignment: .top, spacing: 12) {
                        playlistCard(playlists.playlists[row])
                        if row + 1 < playlists.playlists.count {
                            playlistCard(playlists.playlists[row + 1])
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func playlistCard(_ playlist: YTPlaylist) -> some View {
        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = playlist.thumbnail {
                            RemoteThumbnail(url: url)
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                                .overlay(Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 26)).foregroundColor(.secondary))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped().cornerRadius(8)
                    if let count = playlist.count {
                        HStack(spacing: 3) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10, weight: .bold))
                            Text("\(count)").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.8)).cornerRadius(4).padding(6)
                    }
                }
                Text(playlist.title).font(.caption).foregroundColor(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(L10n.tr("you.private.playlist")).font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var postsPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34)).foregroundColor(.secondary)
            Text(L10n.tr("channel.posts.empty", fallback: "No posts yet"))
                .font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var channelSearch: some View {
        NavigationView {
            VStack {
                TextField(L10n.tr("action.search"), text: .constant(""))
                    .textFieldStyle(RoundedBorderTextFieldStyle()).padding()
                Spacer()
            }
            .navigationTitle(L10n.tr("action.search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSearch = false } label: { Image(systemName: "chevron.left") }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func openStudio(_ urlString: String) {
        guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
