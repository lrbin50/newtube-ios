import Foundation

// MARK: - Comments
//
// Real YouTube comments fetched through InnerTube's `next` endpoint, using
// the ANDROID client. The thread response carries entity payloads
// (`commentEntityPayload`) plus the composer's `createCommentParams`, so
// posting a new comment goes straight to `/comment/create_comment` with the
// user's OAuth token — no protobuf work needed client-side.

struct CommentItem: Identifiable {
    let id: String
    var author: String
    var avatar: URL?
    var text: String
    var published: String
    var likes: String
    var replyCount: String
    var isCreator: Bool
}

@MainActor
final class CommentsStore: ObservableObject {
    static let shared = CommentsStore()

    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var sending = false
    @Published private(set) var postError: String?
    @Published private(set) var justPosted = false

    /// Whether another page of comments can be requested.
    var nextPageAvailable: Bool { nextPage != nil }

    private var videoId: String?
    private var nextPage: String?
    private var createParams: String?
    private var visitorData: String?
    private var requestSequence = 0

    /// The video whose comments are currently shown. The panel's `onAppear`
    /// uses this to avoid reloading (and flashing a spinner) every time the
    /// keyboard moves the layout or the view re-appears.
    private(set) var loadedVideoId: String?

    private let apiKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private let agent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    func load(videoId: String) async {
        self.videoId = videoId
        loadedVideoId = videoId
        comments = []
        error = nil
        postError = nil
        nextPage = nil
        createParams = nil
        loading = true
        let sequence = requestSequence + 1
        requestSequence = sequence
        defer { if requestSequence == sequence { loading = false } }

        // Step 1: the video's `next` response embeds a reload token for the
        // comment section panel.
        guard let first = try? await post("next", body: [
            "context": clientContext,
            "videoId": videoId
        ]) else {
            if requestSequence == sequence { error = L10n.tr("comments.failed", fallback: "Couldn't load comments") }
            return
        }
        // The comment endpoint validates the poster's session against the
        // visitorData that produced createCommentParams, so keep it with the
        // params instead of generating a fresh (mismatched) one at post time.
        if let context = first["responseContext"] as? [String: Any],
           let visitor = context["visitorData"] as? String {
            visitorData = visitor
        }
        guard let token = Self.sectionToken(in: first) else {
            // Some videos have comments disabled; treat an empty section as done.
            if requestSequence == sequence && comments.isEmpty {
                error = nil
            }
            return
        }
        await fetchPage(token: token, sequence: sequence)
    }

    func loadMore() async {
        guard let token = nextPage, !loadingMore, !loading, videoId != nil else { return }
        loadingMore = true
        let sequence = requestSequence
        defer { loadingMore = false }
        await fetchPage(token: token, sequence: sequence)
    }

    /// Post a top-level comment through the account's OAuth token.
    /// - Returns: true only when the server accepted the comment. The caller
    ///   keeps the draft text on false so nothing looks like it vanished.
    @discardableResult
    func post(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        postError = nil
        guard Account.shared.isSignedIn else {
            postError = L10n.tr("comments.signInHint", fallback: "Sign in to join the conversation")
            return false
        }
        guard let params = createParams, let id = videoId else {
            postError = L10n.tr("comments.postFailed", fallback: "Couldn't post comment")
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let token = try await Account.shared.validToken()
            // A signed-in context plus the visitorData that issued the
            // createCommentParams is required; an anonymous context makes the
            // server reject a perfectly valid token (403 PERMISSION_DENIED).
            var ctx = clientContext
            ctx["user"] = ["isSignedIn": true]
            if let visitor = visitorData,
               var client = ctx["client"] as? [String: Any] {
                client["visitorData"] = visitor
                ctx["client"] = client
            }
            let (data, response) = try await LegacyNetwork.data(for: makeRequest(
                endpoint: "comment/create_comment",
                body: [
                    "context": ctx,
                    "commentText": trimmed,
                    "createCommentParams": params
                ],
                authorization: token
            ))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let detail = Self.apiMessage(in: data)
                postError = detail ?? L10n.tr("comments.postFailed", fallback: "Couldn't post comment")
                return false
            }
            // Insert the accepted comment locally instead of reloading the
            // whole thread. A reload clears the list and shows a spinner,
            // which reads as "it bounced back and nothing was posted".
            let mine = CommentItem(
                id: "local-\(UUID().uuidString)",
                author: Account.shared.accountName ?? L10n.tr("you.title", fallback: "You"),
                avatar: Account.shared.avatarURL,
                text: trimmed,
                published: L10n.tr("comments.justNow", fallback: "Just now"),
                likes: "", replyCount: "", isCreator: false
            )
            if !comments.contains(where: { $0.text == trimmed && $0.id.hasPrefix("local-") }) {
                comments.insert(mine, at: 0)
            }
            justPosted = true
            return true
        } catch {
            postError = L10n.tr("comments.postFailed", fallback: "Couldn't post comment")
            return false
        }
    }

    // MARK: internals

    private var clientContext: [String: Any] {
        ["client": ["clientName": "ANDROID", "clientVersion": "20.10.38",
                    "androidSdkVersion": 30, "hl": "en", "gl": "US"]]
    }

    private func fetchPage(token: String, sequence: Int) async {
        guard let json = try? await post("next", body: [
            "context": clientContext,
            "continuation": token
        ]) else {
            if requestSequence == sequence && comments.isEmpty {
                error = L10n.tr("comments.failed", fallback: "Couldn't load comments")
            }
            return
        }
        let page = Self.parse(json)
        let next = Self.nextToken(in: json)
        let params = Self.createParams(in: json)
        // This response issues createCommentParams, so its visitorData is the
        // one the server expects alongside them when posting.
        if let context = json["responseContext"] as? [String: Any],
           let visitor = context["visitorData"] as? String {
            visitorData = visitor
        }
        guard requestSequence == sequence else { return }
        // Comments arrive as entity payloads in display order; drop duplicates
        // when refreshing after posting.
        var seen = Set(comments.map { $0.id })
        for item in page where !seen.contains(item.id) {
            comments.append(item)
            seen.insert(item.id)
        }
        nextPage = next
        if let params = params { createParams = params }
    }

    private func post(_ endpoint: String, body: [String: Any]) async throws -> [String: Any]? {
        let (data, response) = try await LegacyNetwork.data(for: makeRequest(endpoint: endpoint, body: body, authorization: nil))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func makeRequest(endpoint: String, body: [String: Any], authorization: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?key=\(apiKey)&prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        if let authorization = authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: parsing

    /// Surface YouTube's own error message (e.g. "Comment failed to post." or
    /// an auth-scope hint) instead of a generic failure, so a blocked comment
    /// is diagnosable rather than looking like the button did nothing.
    private static func apiMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty
        else { return nil }
        return message
    }

    /// The reload token for the comment section lives inside the engagement
    /// panel whose identifier is "comment-item-section".
    private static func sectionToken(in json: [String: Any]) -> String? {
        var token: String?
        walk(json) { value in
            guard let panel = value as? [String: Any],
                  panel["panelIdentifier"] as? String == "comment-item-section" else { return }
            walk(panel["content"] ?? [:]) { inner in
                guard token == nil,
                      let cont = inner as? [String: Any],
                      let reloads = cont["continuations"] as? [[String: Any]] else { return }
                for reload in reloads {
                    if let data = reload["reloadContinuationData"] as? [String: Any],
                       let t = data["continuation"] as? String { token = t }
                }
            }
        }
        return token
    }

    /// The composer's protobuf "createCommentParams" — the server hands it to
    /// us prebuilt, so posting only needs `/comment/create_comment`.
    private static func createParams(in json: [String: Any]) -> String? {
        var params: String?
        walk(json) { value in
            guard params == nil,
                  let payload = value as? [String: Any],
                  let p = payload["createCommentParams"] as? String else { return }
            params = p
        }
        return params
    }

    private static func nextToken(in json: [String: Any]) -> String? {
        var token: String?
        walk(json) { value in
            guard let dict = value as? [String: Any], token == nil else { return }
            if let next = dict["nextContinuationData"] as? [String: Any],
               let t = next["continuation"] as? String { token = t }
        }
        if token == nil {
            walk(json) { value in
                guard let dict = value as? [String: Any], token == nil else { return }
                if let reload = dict["reloadContinuationData"] as? [String: Any],
                   let t = reload["continuation"] as? String { token = t }
            }
        }
        return token
    }

    /// Walk order follows display order, which is how the entity payloads are
    /// embedded. Also grabs the composer's createCommentParams for posting.
    private static func parse(_ json: [String: Any]) -> [CommentItem] {
        var items: [CommentItem] = []
        walk(json) { value in
            guard let payload = value as? [String: Any],
                  let properties = payload["properties"] as? [String: Any],
                  let id = properties["commentId"] as? String else { return }
            // Only top-level comments; replies stay behind their counter.
            // replyLevel arrives as a number in some payloads and a string in
            // others; absence also means a top-level comment.
            let level = (properties["replyLevel"] as? Int)
                ?? Int((properties["replyLevel"] as? String) ?? "0")
                ?? 0
            guard level == 0,
                  let content = properties["content"] as? [String: Any],
                  let text = content["content"] as? String else { return }
            let author = payload["author"] as? [String: Any] ?? [:]
            let toolbar = payload["toolbar"] as? [String: Any] ?? [:]
            var avatar: URL?
            if let link = author["avatarThumbnailUrl"] as? String { avatar = URL(string: link) }
            items.append(CommentItem(
                id: id,
                author: author["displayName"] as? String ?? "",
                avatar: avatar,
                text: text,
                published: properties["publishedTime"] as? String ?? "",
                likes: toolbar["likeCountNotliked"] as? String ?? "",
                replyCount: toolbar["replyCount"] as? String ?? "",
                isCreator: (author["isCreator"] as? Bool) ?? false
            ))
        }
        return items
    }

    private static func walk(_ value: Any, _ visit: (Any) -> Void) {
        visit(value)
        if let dict = value as? [String: Any] {
            for inner in dict.values { walk(inner, visit) }
        } else if let array = value as? [Any] {
            for inner in array { walk(inner, visit) }
        }
    }
}
