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
    /// Signed-in user's own channel id, used by the channel page.
    @Published private(set) var channelId: String?

    private var tokens: OAuthTokens?
    private let service = "com.newtube.oauth"
    private let account = "youtube"
    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let tvClientVersion = "7.20261123.19.00"

    init() {
        tokens = load()
        isSignedIn = tokens != nil
        // Don't trust the local flag: verify the grant on launch. A stale
        // token that YouTube has revoked still looks "signed in" locally,
        // which leaves the avatar/playlists blank and the feed showing cache.
        if tokens != nil { Task { await validateSession() } }
    }

    // MARK: - Profile (name + avatar)

    /// Verifies the stored token and loads the real account profile.
    ///
    /// `account/account_menu` is retired: YouTube answers HTTP 400 to OAuth
    /// bearer tokens on that endpoint. The signed-in channel id and avatar
    /// are available from the playlist aggregation page instead, which uses
    /// the same TV client context the token was issued for.
    func validateSession() async {
        guard let token = try? await validToken() else { return }
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false")
        else { return }
        do {
            let request = try makeInnertubeRequest(url: url,
                                                   body: tvBody(browseId: "FEplaylist_aggregation"),
                                                   token: token)
            let (data, response) = try await LegacyNetwork.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                signOut()
                return
            }
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            // Cheap fallback: every one of our own playlist tiles carries the
            // account handle in its menu subtitle ("Private • @handle").
            if accountName == nil, let handle = Self.accountHandle(in: json) {
                accountName = handle
            }
            if let channelId = Self.signedInChannelId(in: json) {
                await loadChannelProfile(channelId, token: token)
            }
        } catch {
            // Transient network failure: keep the session and try again later.
            return
        }
    }

    /// Pulls the signed-in account's real name and photo from its channel
    /// header. Called after sign-in and whenever the You tab appears, so a
    /// previously empty profile recovers without reinstalling.
    func refreshProfile() async {
        await validateSession()
    }

    private func tvBody(browseId: String) -> [String: Any] {
        [
            "context": [
                "client": [
                    "clientName": "TVHTML5",
                    "clientVersion": tvClientVersion,
                    "hl": "en", "gl": "US",
                    "platform": "TV",
                    "clientFormFactor": "UNKNOWN_FORM_FACTOR"
                ],
                "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
                "request": ["useSsl": true, "internalExperimentFlags": []]
            ],
            "browseId": browseId
        ]
    }

    /// The "Go to channel" item in our own playlists points at the signed-in
    /// user's channel. Prefer that explicit item; otherwise take the most
    /// frequently repeated UC id in the response.
    private static func signedInChannelId(in value: Any) -> String? {
        var counts: [String: Int] = [:]
        var preferred: String?
        walk(value) { dict in
            if let item = dict["menuNavigationItemRenderer"] as? [String: Any],
               !Self.simpleText(item["text"]).isEmpty,
               Self.simpleText(item["text"]).lowercased().contains("channel"),
               let endpoint = item["navigationEndpoint"] as? [String: Any],
               let browse = endpoint["browseEndpoint"] as? [String: Any],
               let id = browse["browseId"] as? String,
               id.hasPrefix("UC"), id.count == 24 {
                preferred = id
            }
            for child in dict.values {
                guard let string = child as? String,
                      string.hasPrefix("UC"), string.count == 24 else { continue }
                counts[string, default: 0] += 1
            }
        }
        return preferred ?? counts.max { $0.value < $1.value }?.key
    }

    private static func accountHandle(in value: Any) -> String? {
        var result: String?
        walk(value) { dict in
            guard result == nil else { return }
            for child in dict.values {
                guard let string = child as? String, string.hasPrefix("@"),
                      string.count > 1, string.count < 40 else { continue }
                result = String(string.dropFirst())
                return
            }
        }
        return result
    }

    private func loadChannelProfile(_ channelId: String, token: String) async {
        self.channelId = channelId
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false")
        else { return }
        do {
            let request = try makeInnertubeRequest(url: url,
                                                   body: tvBody(browseId: channelId),
                                                   token: token)
            let (data, response) = try await LegacyNetwork.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401 { signOut(); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            var name: String?
            var photo: URL?
            Self.walk(json) { dict in
                guard let header = dict["channelHeaderRenderer"] as? [String: Any] else { return }
                if name == nil {
                    let candidate = Self.simpleText(header["title"])
                    if !candidate.isEmpty { name = candidate }
                }
                if photo == nil { photo = Self.largestThumbnail(header["avatar"]) }
            }
            if let name, !name.isEmpty { accountName = name }
            if let photo {
                // The TV client serves a 72px avatar; ask for a larger crop.
                let upgraded = URL(string: photo.absoluteString.replacingOccurrences(of: "=s72-", with: "=s200-"))
                let chosen = upgraded ?? photo
                avatarURL = chosen
                await loadAvatarImage(from: chosen)
            }
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

    /// Structure-agnostic walk: YouTube moves account/channel data between
    /// renderer shapes on every rollout, so every dictionary is offered to
    /// the caller instead of matching one fixed path.
    private static func walk(_ value: Any, into handler: @escaping ([String: Any]) -> Void) {
        if let dict = value as? [String: Any] {
            handler(dict)
            for child in dict.values { walk(child, into: handler) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, into: handler) }
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
    // youtube.force-ssl is required to POST comments / replies and to like
    // videos. Without it a valid token still gets 403 from
    // /comment/create_comment, which looks to the user like "cannot comment".
    private let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content https://www.googleapis.com/auth/youtube.force-ssl"

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
        channelId = nil
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
