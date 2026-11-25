import SwiftUI

// MARK: - Player page extras
//
// Shared pieces for the player page: the resolving overlay, the bottom-right
// mini window, and the "save to playlist" chooser.

/// Animated loading overlay shown over the video area while the stream is
/// being resolved — a red spinner plus a label instead of a bare system dot.
struct ResolvingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 12) {
                Spinner(size: 46)
                Text(L10n.tr("player.loading", fallback: "Loading…"))
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
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
            // Live video surface — the same AVPlayer keeps rendering here.
            PlayerSurface(player: playback.player)
            if playback.resolving {
                ResolvingOverlay()
            }
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
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.2), lineWidth: 0.5))
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
