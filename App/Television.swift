import Foundation
import Security
import Combine

@MainActor final class Television: ObservableObject {
    private struct Screen: Codable { var screenId: String; var name: String }
    private struct Pairing: Decodable { let screen: Screen }
    private struct TokenList: Decodable {
        struct Token: Decodable { let loungeToken: String }
        let screens: [Token]
    }
    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.toofpaste.newtube.tv",
         kSecAttrAccount as String: "paired-screen"]
    }
    @Published private(set) var name: String?
    private var screen: Screen?
    init() {
        var query = Self.key
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
           let screen = try? JSONDecoder().decode(Screen.self, from: data) {
            self.screen = screen
            name = screen.name
        }
    }

    private func request(_ path: String, _ query: [String: String] = [:], method: String = "GET",
                         form: [String: String]? = nil, token: String? = nil) async throws -> Data {
        var components = URLComponents(string: "https://www.youtube.com/api/lounge/" + path)!
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let token { request.setValue(token, forHTTPHeaderField: "X-YouTube-LoungeId-Token") }
        if let form {
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalidResponse }
        return data
    }

    func pair(_ value: String) async throws {
        let code = value.filter(\.isNumber)
        guard code.count == 12 else { throw URLError(.badURL) }
        let data = try await request("pairing/get_screen", ["pairing_code": code])
        let result = try JSONDecoder().decode(Pairing.self, from: data).screen
        guard !result.screenId.isEmpty else { throw MediaError.invalidResponse }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(result),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(Self.key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let entry = Self.key.merging(attributes) { _, new in new }
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
        } else if status != errSecSuccess { throw URLError(.cannotWriteToFile) }
        screen = result
        name = result.name
    }

    func forget() {
        SecItemDelete(Self.key as CFDictionary)
        screen = nil
        name = nil
    }

    func cast(_ video: Video, queue: [Video], position: Double) async throws {
        guard let screen else { throw MediaError.invalidResponse }
        let data = try await request("pairing/get_lounge_token_batch", method: "POST", form: ["screen_ids": screen.screenId])
        guard let token = try JSONDecoder().decode(TokenList.self, from: data).screens.first?.loungeToken, !token.isEmpty
        else { throw MediaError.invalidResponse }
        let binding = try await request("bc/bind", ["CVER":"1","RID":"1","VER":"8","app":"youtube-desktop",
            "device":"REMOTE_CONTROL","id":"remote","name":"NewTube iOS"], method: "POST", token: token)
        var frames = binding[...]
        var session: [String: String] = [:]
        while let newline = frames.firstIndex(of: 10),
              let line = String(data: frames[..<newline], encoding: .utf8),
              let size = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), size > 0 {
            frames = frames.suffix(from: frames.index(after: newline))
            guard frames.count >= size else { throw MediaError.invalidResponse }
            let payload = Data(frames.prefix(size))
            frames = frames.dropFirst(size)
            for message in (try JSONSerialization.jsonObject(with: payload) as? [[Any]]) ?? [] {
                if let event = message.last as? [Any], event.count >= 2,
                   let key = event[0] as? String, let value = event[1] as? String { session[key] = value }
            }
        }
        guard let sid = session["c"], let gsid = session["S"] else { throw MediaError.invalidResponse }
        let seconds = position.isFinite && position > 0 ? Int(position) : 0
        _ = try await request("bc/bind", ["CVER":"1","RID":"2","VER":"8","SID":sid,"gsessionid":gsid], method: "POST",
            form: ["count":"1","ofs":"0","req0__sc":"setPlaylist","req0_videoId":video.id,"req0_currentTime":String(seconds),
                   "req0_currentIndex":"0","req0_videoIds":([video] + queue).map(\.id).joined(separator: ",")], token: token)
    }
}
