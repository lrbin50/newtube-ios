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
