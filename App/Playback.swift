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
    /// True when the player collapsed into the bottom-right mini window;
    /// playback keeps running while the user browses other tabs.
    @Published private(set) var minimized = false
    @Published private(set) var queue: [Video] = []
    private var ranges: [[Double]] = []
    private var lookup: Task<Void, Never>?
    private var extras: Task<Void, Never>?
    private var observer: NSKeyValueObservation?
    private var stateObserver: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    /// First-frame instrumentation: set when a video is opened, cleared once
    /// AVPlayerItem reports .readyToPlay (or the open fails).
    private var openStartedAt: Date?
    /// Restores normal buffering a moment after the first frame is up.
    private var bufferTask: Task<Void, Never>?
    /// Retries already spent healing the current video's stream (403 / stall).
    private var reloads: [String: Int] = [:]
    /// Fires if an item stays stuck in .waitingToPlay long enough to be a stall.
    private var stallTask: Task<Void, Never>?
    private let maxReloads = 2
    private let stallSeconds: Double = 8
    private var tick: Any?
    private var lastCheckpoint = -1
    private let defaults = UserDefaults.standard

    init(library: Library) {
        self.library = library
        player.allowsExternalPlayback = true
        stateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let isPlaying = self.player.timeControlStatus == .playing
                self.playing = isPlaying
                // Playing at a usable rate means the stream is healthy — any
                // pending stall-heal timer is no longer needed.
                if isPlaying {
                    self.stallTask?.cancel()
                    self.stallTask = nil
                }
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
        // A deliberate replay of the same video gets a fresh heal budget.
        reloads[video.id] = 0
        expanded = true
        resolving = true
        openStartedAt = Date()
        lookup = Task {
            do {
                let url: URL
                if let local = library.file(for: video) { url = local }
                else { url = try await Media.source(video) }
                try Task.checkCancellation()
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let item = AVPlayerItem(url: url)
                // First-frame tuning: buffer only what is needed to paint the
                // first frame and cap the peak rate briefly so a DASH fallback
                // does not start at its top variant. The main itag18 path is
                // already 360p progressive, so the cap is a no-op there.
                item.preferredForwardBufferDuration = 0.5
                item.preferredPeakBitRate = 1_000_000
                player.replaceCurrentItem(with: item)
                observe(item, video: video)
                let seconds = library.resumeTime(video)
                if seconds > 0 { seek(seconds) }
                library.played(video)
                refreshNowPlaying()
                resume()
                // Restore normal buffering shortly after the first frame so
                // long-form playback stays smooth past the first few seconds.
                bufferTask?.cancel()
                bufferTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, self.player.currentItem === item else { return }
                    item.preferredForwardBufferDuration = 0
                    item.preferredPeakBitRate = 0
                }
                // `resolving` is deliberately NOT cleared here. observe()
                // clears it only on .readyToPlay, so the loading overlay can
                // never "finish" before a real frame has been buffered.
            } catch {
                guard !Task.isCancelled else { return }
                resolving = false
                logStart(video, failed: true)
                failure = error.localizedDescription
            }
        }
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
        observer = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    let wasResolving = self.resolving
                    self.resolving = false
                    guard wasResolving else { return }
                    self.logStart(video)
                    // Community lookups wait for the first frame instead of
                    // competing with stream resolution for bandwidth.
                    self.refreshCommunity()
                    self.watchStall(item, video: video)
                case .failed:
                    self.resolving = false
                    self.logStart(video, failed: true)
                    // A dead/403 URL is healed by dropping the cached address
                    // and resolving a fresh one, instead of retrying the same
                    // expired link (SmartTube-CN's 403 self-heal strategy).
                    if self.shouldReload(video.id) {
                        self.reload(video)
                    } else {
                        self.failure = item.error?.localizedDescription ?? "Playback failed."
                    }
                default:
                    break
                }
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

    // MARK: - Stream self-healing

    /// Allow at most `maxReloads` heal attempts per video. The counter resets
    /// when the video is opened afresh, so replaying later starts clean.
    private func shouldReload(_ id: String) -> Bool {
        let used = reloads[id] ?? 0
        guard used < maxReloads else { return false }
        reloads[id] = used + 1
        return true
    }

    /// Drop the cached (possibly IP-bound / expired) URL and resolve a fresh
    /// one. AVPlayer is swapped to the new item in place so the user stays on
    /// the player page. Falls back to the normal YouTubeKit resolver if the
    /// fast ANDROID client has no fresh direct URL.
    private func reload(_ video: Video) {
        guard current?.id == video.id else { return }
        FastMedia.invalidate(video.id)
        failure = nil
        resolving = true
        openStartedAt = Date()
        stallTask?.cancel()
        stallTask = nil
        print("[Perf] video \(video.id) reloading stream (attempt \(reloads[video.id] ?? 0))")
        lookup?.cancel()
        lookup = Task {
            do {
                let url = try await Media.source(video)
                try Task.checkCancellation()
                guard self.current?.id == video.id else { return }
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 0.5
                item.preferredPeakBitRate = 1_000_000
                player.replaceCurrentItem(with: item)
                observe(item, video: video)
                resume()
            } catch {
                guard !Task.isCancelled else { return }
                resolving = false
                failure = error.localizedDescription
            }
        }
    }

    /// Detect a long buffer stall (ready but never starts playing) and heal
    /// it once by re-resolving the URL — mirrors SmartTube's 20/60s buffering
    /// detector, shortened for a phone connection. Cancelled as soon as the
    /// player reports it is playing at a usable rate.
    private func watchStall(_ item: AVPlayerItem, video: Video) {
        stallTask?.cancel()
        stallTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(stallSeconds * 1_000_000_000))
            guard !Task.isCancelled,
                  self.player.currentItem === item,
                  // Only heal a genuine stall: the player wants to play but
                  // cannot. A deliberate pause (.paused) must not trigger it.
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  self.current?.id == video.id else { return }
            print("[Perf] video \(video.id) stalled >\(Int(stallSeconds))s, re-resolving")
            if self.shouldReload(video.id) { self.reload(video) }
        }
    }

    /// Lightweight first-frame instrumentation. Only slow starts are printed,
    /// so the console tag `[Perf]` stays quiet on a fast connection and gives
    /// us real numbers before investing in a bigger prewarm queue.
    private func logStart(_ video: Video, failed: Bool = false) {
        guard let started = openStartedAt else { return }
        openStartedAt = nil
        let elapsed = Date().timeIntervalSince(started)
        if failed || elapsed >= 4 {
            print(String(format: "[Perf] video %@ %@ in %.2fs",
                         video.id, failed ? "FAILED" : "first-frame", elapsed))
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

    /// Collapse the player into the bottom-right mini window without
    /// stopping playback.
    func minimize() { minimized = true }

    /// Bring the player page back up from the mini window.
    func restore() { minimized = false }

    func close() {
        lookup?.cancel()
        extras?.cancel()
        bufferTask?.cancel()
        bufferTask = nil
        stallTask?.cancel()
        stallTask = nil
        openStartedAt = nil
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
        minimized = false
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
        // The player page draws its own bright, single control layer. Native
        // controls are grey and overlapped our buttons while the stream loaded.
        view.showsPlaybackControls = false
        view.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            view.canStartPictureInPictureAutomaticallyFromInline = true
        }
        view.updatesNowPlayingInfoCenter = false
        return view
    }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) {}
}
