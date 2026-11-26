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

/// Builds the protobuf continuation token that asks YouTube's `next`
/// endpoint for a comment section sorted a specific way. Ported from the
/// reference client's `buildCommentsContinuation`; the token format is
/// client-agnostic (the live ANDROID reload token decodes to the same
/// video-id-in-field-2 shape), so sorting server-side avoids the unreliable
/// local "relative time" guess. `sortBy`: 0 = top, 1 = newest.
enum CommentContinuation {
    static func token(videoId: String, sortBy: Int, commentId: String? = nil) -> String {
        let ctx = message([protoString(field: 2, value: videoId)])
        let idField = commentId.flatMap { protoString(field: 16, value: $0) }
        let opts = message([
            protoString(field: 4, value: videoId),
            protoInt32(field: 6, value: sortBy),
            protoInt32(field: 15, value: 2),
            idField
        ].compactMap { $0 })
        let params = message([
            message(field: 4, value: opts),
            protoString(field: 8, value: "comments-section")
        ])
        let root = message([
            message(field: 2, value: ctx),
            protoInt32(field: 3, value: 6),
            message(field: 6, value: params)
        ])
        let url = root.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
    }

    private static func message(_ fields: [Data]) -> Data {
        fields.reduce(into: Data()) { $0.append($1) }
    }

    private static func message(field: Int, value: Data) -> Data {
        var data = Data()
        data.append(key(field: field, wireType: 2))
        data.append(varint(value.count))
        data.append(value)
        return data
    }

    private static func protoString(field: Int, value: String) -> Data {
        message(field: field, value: Data(value.utf8))
    }

    private static func protoInt32(field: Int, value: Int) -> Data {
        var data = Data()
        data.append(key(field: field, wireType: 0))
        data.append(varint(value))
        return data
    }

    private static func key(field: Int, wireType: Int) -> Data {
        varint((field << 3) | wireType)
    }

    private static func varint(_ value: Int) -> Data {
        var data = Data()
        var current = UInt64(bitPattern: Int64(value))
        while current >= 0x80 {
            data.append(UInt8(current & 0x7F | 0x80))
            current >>= 7
        }
        data.append(UInt8(current))
        return data
    }
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

    /// 0 = 最热门, 1 = 最新. Exposed read-only for the sort tabs.
    var currentSort: Int { sortBy }

    private var videoId: String?
    private var nextPage: String?
    private var createParams: String?
    private var visitorData: String?
    private var requestSequence = 0
    /// Server-side sort: 0 = top (热门), 1 = newest (最新). Sorting is done
    /// by YouTube via the continuation token, not by parsing relative times.
    private var sortBy = 0

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

        // Step 1: the `next` response carries the composer params, visitorData
        // and (as a fallback) the section's own reload token.
        let first = try? await post("next", body: [
            "context": clientContext,
            "videoId": videoId
        ])
        if let context = first?["responseContext"] as? [String: Any],
           let visitor = context["visitorData"] as? String {
            visitorData = visitor
        }
        if let params = first.flatMap({ Self.createParams(in: $0) }) { createParams = params }
        let fallbackToken = first.flatMap { Self.sectionToken(in: $0) }

        // Ask YouTube for a server-sorted section via the protobuf token.
        // If the client rejects that token (empty result), fall back to the
        // section's own reload token so "Top" always loads — that path was
        // verified working before sorting was added.
        let sortedToken = CommentContinuation.token(videoId: videoId, sortBy: sortBy)
        if !(await fetchPage(token: sortedToken, sequence: sequence)),
           let fallbackToken, requestSequence == sequence {
            comments = []
            error = nil
            await fetchPage(token: fallbackToken, sequence: sequence)
        }
    }

    /// Switch between Top / Newest. Rebuilds the protobuf continuation with
    /// the requested sort so YouTube returns a freshly ranked first page.
    func setSort(_ newSort: Int) async {
        guard let id = videoId, (newSort == 0 || newSort == 1), newSort != sortBy else { return }
        sortBy = newSort
        await load(videoId: id)
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
        guard let id = videoId else {
            postError = L10n.tr("comments.postFailed", fallback: "Couldn't post comment")
            return false
        }
        sending = true
        defer { sending = false }
        do {
            let token = try await Account.shared.validToken()
            // The composer params from the anonymous read don't match the
            // logged-in session, so the server rejects the post. Fetch a
            // signed-in payload right before posting and use its params +
            // visitorData with the same bearer.
            let composer = await signedComposer(token: token)
            guard let params = composer?.params ?? createParams else {
                postError = L10n.tr("comments.reauthHint", fallback: "评论被拒绝，请在设置里退出并重新登录后重试")
                return false
            }
            if let visitor = composer?.visitor { visitorData = visitor }
            let ctx = signedContext(token: token)
            // YouTube's canonical create_comment body carries commentText as a
            // runs object, not a bare string (a plain string is rejected by
            // several client contexts). Send the structured form first and
            // retry the legacy string form only on a 400, so neither shape
            // silently blocks posting.
            let runsBody: [String: Any] = [
                "context": ctx,
                "commentText": ["runs": [["text": trimmed]]],
                "createCommentParams": params
            ]
            var (data, response) = try await LegacyNetwork.data(for: makeRequest(
                endpoint: "comment/create_comment",
                body: runsBody,
                authorization: token
            ))
            var statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 400 {
                let stringBody: [String: Any] = [
                    "context": ctx,
                    "commentText": trimmed,
                    "createCommentParams": params
                ]
                let retry = try await LegacyNetwork.data(for: makeRequest(
                    endpoint: "comment/create_comment",
                    body: stringBody,
                    authorization: token
                ))
                data = retry.0
                response = retry.1
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            }
            // Both body shapes have been tried; surface YouTube's own message
            // plus the HTTP code so a rejected post is diagnosable in one pass
            // (403 = credential/params, 400 = body shape, 5xx = server).
            guard statusCode == 200 else {
                let detail = Self.apiMessage(in: data)
                let hint = detail ?? (statusCode == 403
                    ? L10n.tr("comments.reauthHint", fallback: "评论被拒绝，请在设置里退出并重新登录后重试")
                    : L10n.tr("comments.postFailed", fallback: "Couldn't post comment"))
                postError = "\(hint) [\(statusCode)]"
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

    /// Reading comments must stay anonymous. Attaching the OAuth bearer or an
    /// `isSignedIn` context to the `next` read requests makes YouTube return a
    /// different (or empty) comment section — the panel then reports
    /// "无法加载评论" even though the video has comments. Sign-in is only
    /// needed when POSTing, and is built separately in `post(_:)`.
    private var clientContext: [String: Any] {
        ["client": ["clientName": "ANDROID", "clientVersion": "20.10.38",
                    "androidSdkVersion": 30, "hl": "en", "gl": "US"]]
    }

    /// Signed variant used only to obtain a composer token that matches the
    /// logged-in session before posting.
    private func signedContext(token: String) -> [String: Any] {
        var ctx = clientContext
        ctx["user"] = ["isSignedIn": true]
        if var client = ctx["client"] as? [String: Any] {
            client["visitorData"] = visitorData
            ctx["client"] = client
        }
        return ctx
    }

    /// - Returns: true when this page actually produced comments. The load
    /// path uses this to fall back to the section reload token if the
    /// protobuf sort token is rejected by the client.
    @discardableResult
    private func fetchPage(token: String, sequence: Int) async -> Bool {
        guard let json = try? await post("next", body: [
            "context": clientContext,
            "continuation": token
        ]) else {
            if requestSequence == sequence && comments.isEmpty {
                error = L10n.tr("comments.failed", fallback: "Couldn't load comments")
            }
            return false
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
        guard requestSequence == sequence else { return false }
        // Comments arrive as entity payloads in display order; drop duplicates
        // when refreshing after posting.
        var seen = Set(comments.map { $0.id })
        for item in page where !seen.contains(item.id) {
            comments.append(item)
            seen.insert(item.id)
        }
        nextPage = next
        if let params = params { createParams = params }
        return !page.isEmpty
    }

    /// Anonymous InnerTube read. Never attach the OAuth token here — the
    /// comment section is public and a bearer on `next` breaks the response.
    private func post(_ endpoint: String, body: [String: Any]) async throws -> [String: Any]? {
        let (data, response) = try await LegacyNetwork.data(for: makeRequest(endpoint: endpoint, body: body, authorization: nil))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Fetch a fresh signed-in composer payload so createCommentParams and
    /// visitorData belong to the same authenticated session as the bearer.
    /// The `next` read must carry the Bearer here (unlike the anonymous
    /// comment listing): without it YouTube issues anonymous composer params,
    /// which the server then rejects against the posting token (403).
    private func signedComposer(token: String) async -> (params: String, visitor: String?)? {
        let result = try? await LegacyNetwork.data(for: makeRequest(
            endpoint: "next",
            body: ["context": signedContext(token: token), "videoId": videoId ?? ""],
            authorization: token
        ))
        guard let data = result?.0,
              (result?.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = Self.createParams(in: json)
        else { return nil }
        let visitor = (json["responseContext"] as? [String: Any])?["visitorData"] as? String
        return (params, visitor)
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
