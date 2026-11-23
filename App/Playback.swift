import AVKit
import MediaPlayer
import SwiftUI

@MainActor final class Playback: ObservableObject {
    let player = AVPlayer()
    let library: Library
    @Published private(set) var current: Video?
    @Published private(set) var resolving = false
    @Published private(set) var playing = false
    @Published private(set) var failure: String?
    @Published private(set) var communityTitle: String?
    @Published private(set) var dislikes: Int?
    @Published private(set) var downloading: String?
    @Published var message: String?
    @Published var expanded = true
    @Published private(set) var queue: [Video] = []
    private var ranges: [[Double]] = []
    private var lookup: Task<Void, Never>?
    private var extras: Task<Void, Never>?
    private var observer: NSKeyValueObservation?
    private var stateObserver: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private var tick: Any?
    private var lastCheckpoint = -1
    private let defaults = UserDefaults.standard

    init(library: Library) {
        self.library = library
        player.allowsExternalPlayback = true
        stateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.player.timeControlStatus == .playing
            }
        }
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.advance(time.seconds) }
        }
        // Playback is an app-lifetime object, so remote handlers are installed once.
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = position.positionTime
            Task { @MainActor in self?.seek(seconds) }
            return .success
        }
    }

    func enqueue(_ video: Video) {
        if current == nil { open(video); return }
        if !queue.contains(where: { $0.id == video.id }) { queue.append(video) }
    }

    func next() {
        guard !queue.isEmpty else { return }
        let nextVideo = queue.removeFirst()
        open(nextVideo)
    }

    func playCollection(_ items: [Video]) {
        guard let first = items.first else { return }
        queue = Array(items.dropFirst())
        open(first)
    }

    func open(_ video: Video) {
        close()
        current = video
        expanded = true
        resolving = true
        lookup = Task {
            do {
                let url: URL
                if let local = library.file(for: video) { url = local }
                else { url = try await Media.source(video) }
                try Task.checkCancellation()
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let item = AVPlayerItem(url: url)
                observe(item, video: video)
                player.replaceCurrentItem(with: item)
                let seconds = library.resumeTime(video)
                if seconds > 0 { seek(seconds) }
                library.played(video)
                refreshNowPlaying()
                resume()
                resolving = false
            } catch {
                guard !Task.isCancelled else { return }
                resolving = false
                failure = error.localizedDescription
            }
        }
        refreshCommunity()
    }

    func refreshCommunity() {
        extras?.cancel()
        communityTitle = nil
        dislikes = nil
        ranges = []
        guard let video = current else { return }
        let skip = defaults.bool(forKey: "sponsorBlock")
        let titles = defaults.bool(forKey: "deArrow")
        let votes = defaults.bool(forKey: "showDislikes")
        extras = Task {
            await withTaskGroup(of: Void.self) { group in
                if skip { group.addTask { [weak self] in
                    let data = await Community.segments(video.id)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.ranges = data }
                } }
                if titles { group.addTask { [weak self] in
                    let title = await Community.title(video.id)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.communityTitle = title }
                } }
                if votes { group.addTask { [weak self] in
                    let value = await Community.dislikes(video.id)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.dislikes = value }
                } }
            }
        }
    }

    private func observe(_ item: AVPlayerItem, video: Video) {
        observer = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed { self.failure = item.error?.localizedDescription ?? "Playback failed." }
            }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if self.queue.isEmpty { self.seek(0) }
                else { self.next() }
                self.library.mark(video, seconds: 0)
            }
        }
    }

    private func advance(_ seconds: Double) {
        guard let current, player.currentItem != nil, seconds.isFinite, seconds >= 0, player.rate != 0 else { return }
        if let range = ranges.first(where: { $0[0] <= seconds && seconds < $0[1] }) {
            seek(range[1])
        }
        let checkpoint = Int(seconds / 5)
        if checkpoint != lastCheckpoint {
            lastCheckpoint = checkpoint
            library.mark(current, seconds: seconds)
            refreshNowPlaying()
        }
    }

    private func refreshNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: communityTitle ?? current.title,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate]
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func resume() {
        let speed = defaults.float(forKey: "speed")
        player.playImmediately(atRate: speed > 0 ? speed : 1)
    }

    func toggle() { if player.rate == 0 { resume() } else { player.pause() } }

    func close() {
        lookup?.cancel()
        extras?.cancel()
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
        observer = nil
        if let current, player.currentItem?.status == .readyToPlay {
            library.mark(current, seconds: player.currentTime().seconds)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        current = nil
        resolving = false
        failure = nil
        lastCheckpoint = -1
    }

    func save(_ video: Video, audioOnly: Bool) {
        guard downloading == nil else { return }
        downloading = video.id
        Task {
            defer { downloading = nil }
            do {
                let file = try await Media.download(video, audioOnly: audioOnly)
                try library.store(file, video: video, audioOnly: audioOnly)
                message = audioOnly ? "Audio saved to Downloads." : "Video saved to Downloads."
            } catch { message = "Download failed. " + error.localizedDescription }
        }
    }
}

struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.player = player
        view.allowsPictureInPicturePlayback = true
        view.canStartPictureInPictureAutomaticallyFromInline = true
        view.updatesNowPlayingInfoCenter = false
        return view
    }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) {}
}
