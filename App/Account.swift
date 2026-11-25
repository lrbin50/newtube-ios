import Foundation
import Security
import SwiftUI
import UIKit

// MARK: - OAuth device-code sign-in (YouTube TV client, no app registration)
//
// Ported from the device flow used by native YouTube clients on old iOS.
// The public TV client id/secret are widely published constants; we fetch a
// fresh pair from YouTube's TV page first and fall back to the bundled ones so
// sign-in keeps working if the page layout changes.

private struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiryDate: Date
    var clientId: String
    var clientSecret: String

    var isExpired: Bool { Date() >= expiryDate.addingTimeInterval(-120) }
}

struct DeviceCodeFlow {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let interval: Int
    let clientId: String
    let clientSecret: String
}

enum AccountError: LocalizedError {
    case invalidResponse
    case unauthorized
    case denied(String)
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from YouTube"
        case .unauthorized: return "Please sign in first"
        case .denied(let message): return message
        case .expired: return "Sign-in expired. Please try again."
        }
    }
}

@MainActor final class Account: ObservableObject {
    static let shared = Account()

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountName: String?
    /// Real Google account photo, resolved from the InnerTube account menu.
    @Published private(set) var avatarURL: URL?
    /// Pre-rendered circular avatar for the tab bar icon.
    @Published private(set) var avatarImage: UIImage?

    private var tokens: OAuthTokens?
    private let service = "com.newtube.oauth"
    private let account = "youtube"
    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvClientVersion = "7.20260311.12.00"

    init() {
        tokens = load()
        isSignedIn = tokens != nil
        if tokens != nil { Task { await refreshProfile() } }
    }

    // MARK: - Profile (name + avatar)

    /// Pulls the signed-in account's name and photo from the InnerTube
    /// account menu — the same call native TV clients make. Failures are
    /// silent: the header simply keeps the initial-letter placeholder.
    func refreshProfile() async {
        guard let token = try? await validToken() else { return }
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "TVHTML5",
                    "clientVersion": tvClientVersion,
                    "hl": "en", "gl": "US",
                    "platform": "TV",
                    "clientFormFactor": "UNKNOWN_FORM_FACTOR"
                ]
            ]
        ]
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/account/account_menu?key=\(apiKey)&prettyPrint=false")
        else { return }
        do {
            let request = try makeInnertubeRequest(url: url, body: body, token: token)
            let (data, response) = try await LegacyNetwork.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            var name: String?
            var photo: URL?
            walkAccountInfo(json) { dict in
                if name == nil {
                    let candidate = Self.simpleText(dict["accountName"])
                    if !candidate.isEmpty { name = candidate }
                }
                if photo == nil {
                    photo = Self.largestThumbnail(dict["accountPhoto"])
                }
            }
            accountName = name ?? accountName
            avatarURL = photo ?? avatarURL
            if let avatarURL { await loadAvatarImage(from: avatarURL) }
        } catch {
            return
        }
    }

    /// Downloads the avatar and pre-crops it to a circle for tab-bar use.
    private func loadAvatarImage(from url: URL) async {
        guard let (data, _) = try? await LegacyNetwork.data(for: URLRequest(url: url)),
              let raw = UIImage(data: data)
        else { return }
        let size = min(raw.size.width, raw.size.height)
        let cropped = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(x: (raw.size.width - size) / 2, y: (raw.size.height - size) / 2,
                              width: size, height: size)
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: CGSize(width: size, height: size))).addClip()
            raw.draw(in: rect)
        }
        avatarImage = cropped
    }

    /// Deep-walks the account menu JSON for every account item shape
    /// (accountItemRenderer and future variants).
    private func walkAccountInfo(_ value: Any, into handler: @escaping ([String: Any]) -> Void) {
        if let dict = value as? [String: Any] {
            if let item = dict["accountItemRenderer"] as? [String: Any] {
                handler(item)
            } else if dict["accountName"] != nil || dict["accountPhoto"] != nil {
                handler(dict)
            }
            for child in dict.values { walkAccountInfo(child, into: handler) }
        } else if let array = value as? [Any] {
            for child in array { walkAccountInfo(child, into: handler) }
        }
    }

    private static func simpleText(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return "" }
        if let s = dict["simpleText"] as? String { return s }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        if let content = dict["content"] as? String { return content }
        return ""
    }

    private static func largestThumbnail(_ value: Any?) -> URL? {
        guard let dict = value as? [String: Any],
              let thumbs = dict["thumbnails"] as? [[String: Any]]
        else { return nil }
        let best = thumbs.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        guard let urlString = best?["url"] as? String else { return nil }
        return urlString.hasPrefix("http") ? URL(string: urlString)
            : URL(string: "https:\(urlString)")
    }

    private func makeInnertubeRequest(url: URL, body: [String: Any], token: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("7", forHTTPHeaderField: "X-YOUTUBE-CLIENT-NAME")
        request.setValue(tvClientVersion, forHTTPHeaderField: "X-YOUTUBE-CLIENT-VERSION")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private let deviceCodeURL = "https://www.youtube.com/o/oauth2/device/code"
    private let tokenURL = "https://www.youtube.com/o/oauth2/token"
    private let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"

    // A TV user-agent is REQUIRED: with a desktop/default UA, youtube.com/tv
    // serves a short "you are being redirected" stub with no base-js, so the
    // dynamic credential scrape fails and we fall back to a stale secret.
    private let tvUserAgent = "Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) Version/6.0 TV Safari/537.36"

    // Fallback public TV client credentials (used if dynamic fetch fails).
    // These are the live values from youtube.com/tv's base.js; keep in sync.
    private let fallbackId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    private let fallbackSecret = "SboVhoG9s0rNafixCSGGKXAT"

    // MARK: - Sign-in flow

    /// Step 1: obtain a user code the person enters at verificationURL.
    func beginSignIn() async throws -> DeviceCodeFlow {
        let (clientId, secret) = await fetchCredentials()
        let body: [String: Any] = [
            "client_id": clientId,
            "scope": scope,
            "device_id": UUID().uuidString,
            "device_model": "ytlr::"
        ]
        let data = try await post(deviceCodeURL, body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let url = json["verification_url"] as? String,
              let interval = json["interval"] as? Int
        else { throw AccountError.invalidResponse }
        return DeviceCodeFlow(
            deviceCode: deviceCode, userCode: userCode,
            verificationURL: url, interval: interval,
            clientId: clientId, clientSecret: secret
        )
    }

    /// Step 2: poll until the user approves (or rejects/expires). Cancellable.
    func awaitApproval(_ flow: DeviceCodeFlow) async throws {
        var interval = max(flow.interval, 3)
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let body: [String: Any] = [
                "client_id": flow.clientId,
                "client_secret": flow.clientSecret,
                "code": flow.deviceCode,
                "grant_type": "http://oauth.net/grant_type/device/1.0"
            ]
            let data = try await post(tokenURL, body: body)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let access = json["access_token"] as? String,
               let refresh = json["refresh_token"] as? String,
               let expires = json["expires_in"] as? Int {
                let new = OAuthTokens(
                    accessToken: access, refreshToken: refresh,
                    expiryDate: Date().addingTimeInterval(TimeInterval(expires)),
                    clientId: flow.clientId, clientSecret: flow.clientSecret
                )
                tokens = new
                save(new)
                isSignedIn = true
                await refreshProfile()
                return
            }
            switch json["error"] as? String {
            case "slow_down": interval += 5
            case "expired_token": throw AccountError.expired
            case "access_denied": throw AccountError.denied("Access denied")
            case "invalid_client":
                // Stale client secret: surfacing this beats spinning until the
                // 20-minute deadline with no explanation to the user.
                throw AccountError.denied(
                    json["error_description"] as? String
                        ?? "Sign-in credentials rejected. Please update the app."
                )
            default: break  // authorization_pending and transient errors
            }
        }
        throw AccountError.expired
    }

    /// A valid bearer token, refreshing silently when needed.
    func validToken() async throws -> String {
        guard var current = tokens else { throw AccountError.unauthorized }
        if !current.isExpired { return current.accessToken }
        let body: [String: Any] = [
            "client_id": current.clientId,
            "client_secret": current.clientSecret,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token"
        ]
        let data = try await post(tokenURL, body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let expires = json["expires_in"] as? Int
        else {
            signOut()
            throw AccountError.unauthorized
        }
        current.accessToken = access
        current.expiryDate = Date().addingTimeInterval(TimeInterval(expires))
        tokens = current
        save(current)
        return access
    }

    func signOut() {
        tokens = nil
        isSignedIn = false
        accountName = nil
        avatarURL = nil
        avatarImage = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Plumbing

    private func post(_ urlString: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw AccountError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // OAuth endpoints return useful bodies on non-2xx (e.g. pending), so
        // we surface the raw data regardless of status code.
        let (data, _) = try await LegacyNetwork.data(for: request)
        return data
    }

    /// Reads client id/secret from YouTube's TV page JS, with fallback.
    /// A TV UA is mandatory: otherwise the page is a redirect stub with no JS.
    private func fetchCredentials() async -> (String, String) {
        guard let tv = URL(string: "https://www.youtube.com/tv"),
              let htmlData = try? await getWithTVUA(tv),
              let html = String(data: htmlData, encoding: .utf8),
              let src = match(#"<script\s+id="base-js"\s+src="([^"]+)""#, in: html, group: 1),
              let jsURL = URL(string: src.hasPrefix("http") ? src : "https://www.youtube.com\(src)"),
              let jsData = try? await getWithTVUA(jsURL),
              let js = String(data: jsData, encoding: .utf8),
              let id = match(#"clientId:"([^"]+)""#, in: js, group: 1),
              let secret = match(#"clientId:"[^"]+",\s*\w+:"([^"]+)""#, in: js, group: 1)
        else { return (fallbackId, fallbackSecret) }
        return (id, secret)
    }

    private func getWithTVUA(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(tvUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await LegacyNetwork.data(for: request)
        return data
    }

    private nonisolated func match(_ pattern: String, in string: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(result.range(at: group), in: string)
        else { return nil }
        return String(string[range])
    }

    private func save(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private func load() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }
}
