import SwiftUI
import AVKit

/// Backing view for the mini window: an AVPlayerLayer that always fills its
/// bounds. Keeping the layer's frame in `layoutSubviews` avoids the zero-size
/// layer you get if you only set it in SwiftUI's `makeUIView`.
final class MiniPlayerVideoView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

/// A lightweight video layer for the mini window. Uses AVPlayerLayer directly
/// (not AVPlayerViewController) so it stays inside the SwiftUI overlay frame on
/// iOS 14 — an embedded player controller used to escape its bounds and paint a
/// blue circle over the tab bar. The parent view clips it to a rounded rect.
struct MiniPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MiniPlayerVideoView {
        let view = MiniPlayerVideoView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: MiniPlayerVideoView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

// MARK: - Player page extras
//
// Shared pieces for the player page: the resolving overlay, the bottom-right
// mini window, and the "save to playlist" chooser.

/// Loading overlay shown over the video area while the stream resolves AND
/// buffers. The feed card has usually already cached the thumbnail, so showing
/// it here removes the "black rectangle + spinner" feeling of a stalled player.
struct ResolvingOverlay: View {
    var thumbnail: URL? = nil

    var body: some View {
        ZStack {
            if let thumbnail {
                RemoteThumbnail(url: thumbnail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                Color.black.opacity(0.32)
            } else {
                Color.black.opacity(0.55)
            }
            VStack(spacing: 12) {
                Spinner(size: 46)
                Text(L10n.tr("player.loading", fallback: "Loading…"))
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            }
        }
    }
}

/// A smooth rotating arc spinner in YouTube red.
struct Spinner: View {
    var size: CGFloat = 40
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.92)
            .stroke(AngularGradient(colors: [Color.red, Color.white], center: .center),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Bottom-right floating mini window. The video keeps playing on top of
/// every tab; tapping the window reopens the player page.
struct MiniPlayerView: View {
    @EnvironmentObject var playback: Playback
    let video: Video

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Live video: render the same shared AVPlayer here so the picture
            // keeps playing after the full-screen page is dismissed. The cover
            // sits behind it so there is no black flash while the layer attaches.
            RemoteThumbnail(url: video.thumbnailURL)
                .frame(width: 220, height: 124)
            MiniPlayerSurface(player: playback.player)
                .frame(width: 220, height: 124)
            Color.black.opacity(0.18)
            Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.92))
            HStack(spacing: 6) {
                Button {
                    playback.restore()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(5).background(Circle().fill(Color.black.opacity(0.6)))
                }
                Button {
                    playback.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(5).background(Circle().fill(Color.black.opacity(0.6)))
                }
            }
            .padding(8)
        }
        .frame(width: 220, height: 124)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { playback.restore() }
        .padding(12)
    }
}

/// Shown when 保存 is tapped: pick which playlist the video goes into.
/// Lists the account's real playlists (from InnerTube) plus Watch later;
/// adding is performed through the InnerTube playlist editor.
struct SaveToPlaylistSheet: View {
    let video: Video
    @ObservedObject private var playlists = PlaylistsStore.shared
    @Environment(\.presentationMode) private var presentation
    @State private var workingId: String?
    @State private var doneId: String?
    @State private var failed = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if playlists.playlists.isEmpty && playlists.loading {
                    VStack { Spinner(size: 36).padding(.top, 40) }
                    Spacer()
                } else if playlists.playlists.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 34)).foregroundColor(.secondary)
                        Text(L10n.tr("you.playlists")).font(.headline)
                        Text(L10n.tr("player.saveTo.empty", fallback: "Sign in to see your playlists."))
                            .font(.caption).foregroundColor(.secondary)
                    }.padding(.top, 50)
                    Spacer()
                } else {
                    List(sheetEntries) { playlist in
                        Button {
                            save(to: playlist)
                        } label: {
                            HStack(spacing: 10) {
                                Group {
                                    if let url = playlist.thumbnail {
                                        RemoteThumbnail(url: url)
                                    } else {
                                        Rectangle().fill(Color.secondary.opacity(0.15))
                                    }
                                }
                                .frame(width: 70, height: 40).clipped().cornerRadius(5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.title)
                                        .font(.subheadline).foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(L10n.tr("you.private.playlist"))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                if workingId == playlist.id {
                                    Spinner(size: 16)
                                } else if doneId == playlist.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
                if failed {
                    Text(L10n.tr("player.saveTo.failed", fallback: "Couldn't add to this playlist."))
                        .font(.caption).foregroundColor(.red)
                        .padding(.vertical, 8)
                }
            }
            .navigationTitle(L10n.tr("player.saveTo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.tr("common.ok")) { presentation.wrappedValue.dismiss() }
                }
            }
            .onAppear { Task { await playlists.load() } }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    /// Watch later first (InnerTube's fixed `WL` id), then account playlists.
    private var sheetEntries: [YTPlaylist] {
        var entries = [YTPlaylist(id: "WL", title: L10n.tr("you.watchLater"),
                                  thumbnail: nil, count: nil)]
        entries.append(contentsOf: playlists.playlists.filter { $0.id != "VLWL" })
        return entries
    }

    private func save(to playlist: YTPlaylist) {
        guard workingId == nil, doneId == nil else { return }
        workingId = playlist.id
        failed = false
        Task {
            let ok = await playlists.addToPlaylist(playlistId: playlist.id, videoId: video.id)
            workingId = nil
            if ok {
                doneId = playlist.id
                // Brief confirmation, then close.
                try? await Task.sleep(nanoseconds: 900_000_000)
                presentation.wrappedValue.dismiss()
            } else {
                failed = true
            }
        }
    }
}

// MARK: - Comments panel
//
// Bottom-half comments overlay for the player page, matching the Android
// layout: drag handle, title row, community-guidelines notice, the comment
// list and an input bar for posting a new comment.

struct CommentsPanel: View {
    let videoId: String
    let onClose: () -> Void

    @ObservedObject private var store = CommentsStore.shared
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule().fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4).padding(.top, 8)

            // Title row
            HStack {
                Text(L10n.tr("comments.title", fallback: "Comments"))
                    .font(.headline).foregroundColor(.primary)
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(6)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            // Guidelines notice
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                (Text(L10n.tr("comments.guidelines", fallback: "Please follow the YouTube Community Guidelines when commenting. "))
                    + Text(L10n.tr("comments.learnMore", fallback: "Learn more"))
                    .bold()
                    .foregroundColor(Color(UIColor.systemBlue)))
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(height: 30)

            if store.loading {
                VStack { Spinner(size: 34).padding(.top, 40) }
                Spacer()
            } else if let message = store.error {
                VStack(spacing: 8) {
                    Text(message).font(.subheadline).foregroundColor(.secondary)
                }.padding(.top, 40)
                Spacer()
            } else if store.comments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(L10n.tr("comments.empty", fallback: "No comments yet"))
                        .font(.subheadline).foregroundColor(.secondary)
                }.padding(.top, 40)
                Spacer()
            } else {
                List {
                    ForEach(store.comments) { comment in
                        CommentRow(comment: comment)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    // Load more page trigger.
                    if store.nextPageAvailable {
                        HStack {
                            Spacer()
                            if store.loadingMore {
                                Spinner(size: 20)
                            } else {
                                Button(L10n.tr("comments.loadMore", fallback: "Load more")) {
                                    Task { await store.loadMore() }
                                }
                                .font(.subheadline)
                            }
                            Spacer()
                        }
                    }
                }
                .listStyle(.plain)
            }

            // Input bar
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    TextField(L10n.tr("comments.placeholder", fallback: "Add a comment..."),
                              text: $draft)
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(20)
                    if !Account.shared.isSignedIn {
                        Text(L10n.tr("comments.signInHint", fallback: "Sign in to join the conversation"))
                            .font(.caption2).foregroundColor(.secondary)
                            .padding(.leading, 16)
                            .allowsHitTesting(false)
                    }
                }
                if store.sending {
                    Spinner(size: 18).padding(.horizontal, 6)
                } else {
                    Button {
                        let text = draft
                        draft = ""
                        Task {
                            await store.post(text)
                            if store.postError != nil { draft = text }
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(draft.isEmpty ? Color.secondary : Color(UIColor.systemBlue))
                    }
                    .disabled(draft.isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let failure = store.postError {
                Text(failure).font(.caption2).foregroundColor(.red)
                    .frame(maxWidth: .infinity).padding(.bottom, 4)
            }
        }
        .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.bottom))
        .cornerRadius(16)
        .onAppear { Task { await store.load(videoId: videoId) } }
    }
}

/// One comment: avatar, author · time, text, like/dislike and reply count.
struct CommentRow: View {
    let comment: CommentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if let url = comment.avatar {
                    RemoteThumbnail(url: url)
                        .frame(width: 32, height: 32).clipShape(Circle())
                } else {
                    Circle().fill(Color.accentColor.opacity(0.2))
                        .frame(width: 32, height: 32)
                        .overlay(Text(String(comment.author.prefix(1)).uppercased())
                            .font(.caption.bold()).foregroundColor(.accentColor))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(comment.author).font(.caption.bold()).foregroundColor(.primary)
                        if comment.isCreator {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Text(comment.published).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(comment.text).font(.subheadline).foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsup").font(.caption).foregroundColor(.secondary)
                            if !comment.likes.isEmpty {
                                Text(comment.likes).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Image(systemName: "hand.thumbsdown").font(.caption).foregroundColor(.secondary)
                        if !comment.replyCount.isEmpty {
                            HStack(spacing: 3) {
                                Text("\(comment.replyCount) \(L10n.tr("comments.replies", fallback: "replies"))")
                                    .font(.caption).foregroundColor(.secondary)
                                Image(systemName: "chevron.down").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }.padding(.top, 2)
                }
            }
        }
    }
}
