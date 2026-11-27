import Foundation
import SwiftUI
import UIKit

// MARK: - iOS 14 compatibility helpers

/// Bridges URLSession completion handlers into async/await for iOS 14, where
/// some of the convenience async overloads are not available.
private final class URLSessionCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func register(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

enum LegacyNetwork {
    /// All InnerTube traffic shares URLSession.shared, so DNS/TLS/HTTP2
    /// connections are pooled across feed, player and account requests —
    /// the iOS equivalent of SmartTube's dedicated long-lived OkHttp client.
    /// Warming that pool at launch removes a handshake from the first tap.
    static func warmup() {
        Task(priority: .utility) {
            var request = URLRequest(url: URL(string: "https://www.youtube.com/generate_204")!)
            request.httpMethod = "HEAD"
            _ = try? await data(for: request)
        }
    }

    static func data(from url: URL) async throws -> (Data, URLResponse) {
        let box = URLSessionCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.dataTask(with: url) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                box.register(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let box = URLSessionCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                box.register(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func download(from url: URL) async throws -> (URL, URLResponse) {
        let box = URLSessionCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let location, let response {
                        continuation.resume(returning: (location, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                box.register(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

// MARK: - SwiftUI backports

struct EmptyStateView<Description: View>: View {
    let title: String
    let systemImage: String
    let description: Description
    var buttonTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            description
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let buttonTitle {
                Button(buttonTitle, action: action)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RemoteThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .onAppear {
            guard image == nil else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let loaded = UIImage(data: data) else { return }
                DispatchQueue.main.async { self.image = loaded }
            }.resume()
        }
    }
}

/// UIImageView that reports no intrinsic size, so SwiftUI's `.frame` +
/// `.aspectRatio` fully control its bounds inside a LazyVGrid cell. Without
/// this, a loaded image's natural size inflates the cell and overlaps rows.
final class GridThumbnailImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

/// iOS 14-safe rounded thumbnail for feed cards.
///
/// SwiftUI's `.cornerRadius` mask is discarded on iOS 14 when RemoteThumbnail
/// swaps its placeholder branch for the decoded image — the first render is
/// rounded, the refreshed one turns square. Keeping the radius on the backing
/// UIImageView's layer (same approach as Opaline's VideoCell) survives any
/// content refresh. A process-wide cache avoids re-downloading on re-render.
struct RoundedThumbnail: UIViewRepresentable {
    let url: URL
    let radius: CGFloat

    private static let imageCache = NSCache<NSURL, UIImage>()

    func makeUIView(context: Context) -> GridThumbnailImageView {
        let view = GridThumbnailImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = UIColor.secondarySystemFill
        view.layer.cornerRadius = radius
        view.layer.masksToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: GridThumbnailImageView, context: Context) {
        uiView.layer.cornerRadius = radius
        uiView.layer.masksToBounds = true
        context.coordinator.load(url, into: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var task: URLSessionTask?
        private var currentURL: URL?

        func load(_ url: URL, into view: UIImageView) {
            guard currentURL != url else { return }
            currentURL = url
            task?.cancel()

            let key = url as NSURL
            if let cached = RoundedThumbnail.imageCache.object(forKey: key) {
                view.image = cached
                return
            }
            view.image = nil
            task = URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let image = UIImage(data: data) else { return }
                RoundedThumbnail.imageCache.setObject(image, forKey: key)
                DispatchQueue.main.async {
                    // Only apply if this view is still showing the same URL.
                    guard self.currentURL == url else { return }
                    view.image = image
                }
            }
            task?.resume()
        }

        deinit { task?.cancel() }
    }
}

struct ShareButton: View {
    let url: URL

    var body: some View {
        Button {
            guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                    ?? scene.windows.first?.rootViewController
            else { return }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = root.view
            controller.popoverPresentationController?.sourceRect = CGRect(
                x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1
            )
            root.present(controller, animated: true)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}
