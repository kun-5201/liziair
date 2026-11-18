import Foundation
import Network
import CryptoKit
import Security

/// Spotify：services/spotify-api/start.mjs 的 1:1 Swift 移植（可行性骨架，本期不接音频）。
/// 只做 PKCE 登录（官方 OAuth，回调 127.0.0.1:5588）+ 元数据读取；
/// /audio 永远回 { url: '', reason: 'drm' }，/lyrics 永远空。
/// 没有内置 client_id：需用户自己注册免费 App，把 Client ID 填进
/// SPOTIFY_CLIENT_ID 环境变量或沙盒里的 spotify-client（对标边车目录的 .client.json）。

struct SpotifyToken {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double  // 毫秒时间戳
    var scope: String
}

final class SpotifyService {
    static let callbackPort = 5588
    static let redirectURI = "http://127.0.0.1:5588/callback"
    static let scopes = ["user-read-private", "user-read-email", "playlist-read-private"]
    /// 本期硬限制，前端直接拿来显示，别在前端再写一份。
    static let needAudio = "需要 Premium + node-librespot 原生二进制（59.4MB），且属解密 DRM 的灰区；本期不接音频"

    private let session = SessionStore.shared
    private var token: SpotifyToken?
    private var pendingPkce: (verifier: String, state: String, at: Date)?
    private var callbackListener: NWListener?

    init() {
        if let saved = session.sidecarAuth("spotify"),
           let at = saved["accessToken"] as? String, !at.isEmpty {
            token = SpotifyToken(
                accessToken: at,
                refreshToken: saved["refreshToken"] as? String ?? "",
                expiresAt: (saved["expiresAt"] as? NSNumber)?.doubleValue ?? 0,
                scope: saved["scope"] as? String ?? "")
        }
        ensureCallbackServer()
    }

    // MARK: - 凭证与 token 落盘

    private func readClient() -> (clientId: String, clientSecret: String) {
        var clientId = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] ?? ""
        var clientSecret = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"] ?? ""
        if clientId.isEmpty, let saved = session.sidecarAuth("spotify-client") {
            clientId = saved["clientId"] as? String ?? ""
            clientSecret = saved["clientSecret"] as? String ?? ""
        }
        return (clientId, clientSecret)
    }

    private func saveToken(_ t: SpotifyToken?) {
        token = t
        if let t {
            session.saveSidecarAuth("spotify", [
                "accessToken": t.accessToken, "refreshToken": t.refreshToken,
                "expiresAt": t.expiresAt, "scope": t.scope,
            ])
        } else {
            session.clearSidecarAuth("spotify")
        }
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - HTTP 小工具

    private func postForm(_ urlString: String, body: [String: String],
                          headers: [String: String] = [:]) async throws -> (status: Int, data: [String: Any]) {
        let url = URL(string: urlString)!
        var form = URLComponents()
        form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data(form.query?.utf8 ?? "".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            ?? ["raw": String(text.prefix(300))]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, parsed)
    }

    /// 拿一个可用的 access token：先用存下来的，过期就刷新；都没有时试 client_credentials。
    private func accessToken() async throws -> String {
        let client = readClient()
        guard !client.clientId.isEmpty else {
            throw NSError(domain: "Spotify", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 SPOTIFY_CLIENT_ID：Spotify 不预置第三方凭证，需要自己注册一个免费 App"])
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let t = token, !t.accessToken.isEmpty, t.expiresAt > nowMs + 30000 {
            return t.accessToken
        }
        if let t = token, !t.refreshToken.isEmpty {
            let r = try await postForm("https://accounts.spotify.com/api/token", body: [
                "grant_type": "refresh_token", "refresh_token": t.refreshToken, "client_id": client.clientId,
            ])
            if r.status == 200, let at = r.data["access_token"] as? String, !at.isEmpty {
                let expiresIn = scNum(r.data["expires_in"]) != 0 ? scNum(r.data["expires_in"]) : 3600
                saveToken(SpotifyToken(accessToken: at, refreshToken: t.refreshToken,
                                       expiresAt: nowMs + Double(expiresIn) * 1000, scope: t.scope))
                return at
            }
        }
        if !client.clientSecret.isEmpty {
            let basic = Data("\(client.clientId):\(client.clientSecret)".utf8).base64EncodedString()
            let r = try await postForm("https://accounts.spotify.com/api/token",
                                       body: ["grant_type": "client_credentials"],
                                       headers: ["Authorization": "Basic \(basic)"])
            if r.status == 200, let at = r.data["access_token"] as? String, !at.isEmpty {
                return at  // 不落盘：客户端凭证 token 不代表用户，重启再取即可
            }
            let detail = (r.data["error_description"] as? String) ?? (r.data["error"] as? String) ?? String(r.status)
            throw NSError(domain: "Spotify", code: -1, userInfo: [NSLocalizedDescriptionKey: "client_credentials 取 token 失败（\(detail)）"])
        }
        throw NSError(domain: "Spotify", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录 Spotify：点「登录」走 PKCE 授权（需要 Client ID；有 Client Secret 时可直接匿名搜）"])
    }

    private func sp(_ pathname: String, _ params: [String: String?]) async throws -> (status: Int, data: [String: Any]) {
        let t = try await accessToken()
        var comps = URLComponents(string: "https://api.spotify.com/v1" + pathname)!
        comps.queryItems = params.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        let (data, resp) = try await Upstream.fetch(comps.url!, headers: ["Authorization": "Bearer \(t)"], timeout: 15)
        let text = String(data: data, encoding: .utf8) ?? ""
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            ?? ["raw": String(text.prefix(300))]
        return (resp.statusCode, parsed)
    }

    // MARK: - PKCE

    private func authorizeUrl() throws -> String {
        let client = readClient()
        guard !client.clientId.isEmpty else {
            throw NSError(domain: "Spotify", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 SPOTIFY_CLIENT_ID"])
        }
        var verifierBytes = [UInt8](repeating: 0, count: 48)
        var stateBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let verifier = Self.b64url(Data(verifierBytes))
        let state = Self.b64url(Data(stateBytes))
        pendingPkce = (verifier: verifier, state: state, at: Date())
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]
        return comps.url!.absoluteString
    }

    private static func callbackPage(title: String, detail: String) -> String {
        "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title>\n<body style=\"font:15px/1.6 system-ui;padding:48px;color:#17171a\">\n<h1 style=\"font-size:20px\">\(title)</h1><p style=\"color:#666\">\(detail)</p>\n<p style=\"color:#999;font-size:13px\">这个窗口可以关掉了，回到 LIZI 设置面板看状态。</p></body>"
    }

    /// 回调服务：单独一个 127.0.0.1:5588，只接 code 换 token。起不来只记日志，不退出。
    private func ensureCallbackServer() {
        guard callbackListener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(integerLiteral: UInt16(Self.callbackPort)))
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in self?.handleCallbackConnection(conn) }
        listener.start(queue: .global(qos: .userInitiated))
        callbackListener = listener
    }

    private func receive(_ conn: NWConnection) async -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                cont.resume(returning: data ?? Data())
            }
        }
    }

    private func send(_ conn: NWConnection, status: Int, contentType: String, body: Data) async {
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: out, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private func handleCallbackConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            defer { conn.cancel() }
            guard let self else { return }
            var buf = Data()
            while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
                let chunk = await self.receive(conn)
                if chunk.isEmpty { return }
                buf.append(chunk)
                if buf.count > 65536 { return }
            }
            guard let headerText = String(data: buf, encoding: .utf8) else { return }
            let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let target = String(parts[1])
            guard let comps = URLComponents(string: "http://127.0.0.1" + target), comps.path == "/callback" else {
                await self.send(conn, status: 404, contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
                return
            }
            let q = (comps.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
            if let err = q["error"], !err.isEmpty {
                await self.send(conn, status: 200, contentType: "text/html; charset=utf-8",
                                body: Data(Self.callbackPage(title: "Spotify 授权被拒绝", detail: err).utf8))
                return
            }
            guard let code = q["code"], !code.isEmpty, let pkce = pendingPkce, q["state"] == pkce.state else {
                await self.send(conn, status: 200, contentType: "text/html; charset=utf-8",
                                body: Data(Self.callbackPage(title: "回调不匹配", detail: "state 对不上或没有 code，请重新点登录。").utf8))
                return
            }
            do {
                let client = readClient()
                let r = try await postForm("https://accounts.spotify.com/api/token", body: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": Self.redirectURI, "client_id": client.clientId,
                    "code_verifier": pkce.verifier,
                ])
                guard r.status == 200, let at = r.data["access_token"] as? String, !at.isEmpty else {
                    let msg = (r.data["error_description"] as? String) ?? (r.data["error"] as? String) ?? String(r.status)
                    await self.send(conn, status: 200, contentType: "text/html; charset=utf-8",
                                    body: Data(Self.callbackPage(title: "换 token 失败", detail: msg).utf8))
                    return
                }
                let expiresIn = scNum(r.data["expires_in"]) != 0 ? scNum(r.data["expires_in"]) : 3600
                saveToken(SpotifyToken(accessToken: at, refreshToken: r.data["refresh_token"] as? String ?? "",
                                       expiresAt: Date().timeIntervalSince1970 * 1000 + Double(expiresIn) * 1000,
                                       scope: r.data["scope"] as? String ?? ""))
                pendingPkce = nil
                await self.send(conn, status: 200, contentType: "text/html; charset=utf-8",
                                body: Data(Self.callbackPage(title: "Spotify 已登录", detail: "可以回 LIZI 了（本期不接音频，只有元数据）。").utf8))
            } catch {
                await self.send(conn, status: 200, contentType: "text/html; charset=utf-8",
                                body: Data(Self.callbackPage(title: "换 token 失败", detail: error.localizedDescription).utf8))
            }
        }
    }

    // MARK: - 归一化

    func spotifyTrack(_ it: [String: Any]) -> [String: Any]? {
        let album = scDict(it, "album")
        let artists = scArr(it, "artists")
        let names = artists.compactMap { $0["name"] as? String }
        let images = scArr(album, "images")
        return [
            "id": scStrOrNum(it, "id"), "source": "spotify",
            "name": scStr(it, "name"),
            "artists": names.joined(separator: " / ").isEmpty ? "未知歌手" : names.joined(separator: " / "),
            "artistIds": artists.compactMap { $0["id"] as? String },
            "album": scStr(album, "name"),
            "albumId": scStrOrNum(album, "id"),
            "cover": images.first?["url"] as? String ?? "",
            "duration": scNum(it["duration_ms"]),
            "fee": 1,  // 打「仅元数据」小签用，不是付费标记
            "externalUrl": scStr(scDict(it, "external_urls"), "spotify"),
        ]
    }

    // MARK: - 路由（主服务翻译层，handleSpotify）

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/spotify/".count))
        switch part {
        case "", "health":
            let client = readClient()
            let ok = !client.clientId.isEmpty
            return .json(200, ["code": 200, "ok": ok,
                               "hasClientId": ok, "hasSecret": !client.clientSecret.isEmpty,
                               "loggedIn": token?.accessToken.isEmpty == false,
                               "callback": Self.redirectURI, "audio": false,
                               "audioReason": Self.needAudio,
                               "error": ok ? NSNull() : "缺少 SPOTIFY_CLIENT_ID：Spotify 不预置第三方凭证，需自己注册免费 App"])
        case "login/url":
            do {
                let url = try authorizeUrl()
                return .json(200, ["code": 200, "url": url, "callback": Self.redirectURI])
            } catch {
                return .json(200, ["code": 400, "error": error.localizedDescription])
            }
        case "status", "login/status":
            return await status()
        case "logout":
            saveToken(nil)
            return .json(200, ["code": 200, "loggedIn": false])
        case "search":
            return await search(req)
        case "song/url":
            return .json(200, ["code": 200, "id": req.string("id"), "url": "", "preview": false,
                               "reason": "drm", "error": Self.needAudio])
        case "lyric", "lyrics":
            // 第 11 轮：Spotify 官方恒空（no-lyrics-api），LRCLIB 兜底在这里是
            // 首次出词。元数据来自前端 srcLyric 传参；传参缺歌名时直接回原来的空。
            if let fb = await Lrclib.fetch(artist: req.string("artist"), track: req.string("s"),
                                           album: req.string("album"), duration: req.int("duration")) {
                return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": "", "tlyric": "",
                                   "format": "lrc", "source": "lrclib"])
            }
            return .json(200, ["code": 200, "lyric": "", "format": "none", "reason": "no-lyrics-api"])
        case "audio":
            return .json(200, ["code": 200, "url": "", "reason": "drm",
                               "error": "本期不接 Spotify 音频（需 Premium + node-librespot，且属 DRM 灰区）"])
        default:
            return .json(404, ["code": 404, "error": "unknown spotify api: \(part)"])
        }
    }

    private func status() async -> HttpResponse {
        let client = readClient()
        guard !client.clientId.isEmpty else {
            return .json(200, ["code": 200, "loggedIn": false, "error": "缺少 SPOTIFY_CLIENT_ID"])
        }
        guard let t = token, !t.accessToken.isEmpty else {
            if !client.clientSecret.isEmpty {
                do {
                    _ = try await accessToken()
                    return .json(200, ["code": 200, "loggedIn": false, "mode": "client-credentials",
                                       "nickname": "Spotify（客户端凭证）"])
                } catch {
                    return .json(200, ["code": 200, "loggedIn": false, "error": error.localizedDescription])
                }
            }
            return .json(200, ["code": 200, "loggedIn": false])
        }
        do {
            let me = try await sp("/me", [:])
            if me.status == 200, let id = me.data["id"] as? String, !id.isEmpty {
                let images = scArr(me.data, "images")
                return .json(200, ["code": 200, "loggedIn": true, "mode": "pkce",
                                   "nickname": scStr(me.data, "display_name").isEmpty ? id : scStr(me.data, "display_name"),
                                   "avatar": images.first?["url"] as? String ?? "",
                                   "product": scStr(me.data, "product")])
            }
            if me.status == 401, !client.clientSecret.isEmpty {
                return .json(200, ["code": 200, "loggedIn": false, "mode": "client-credentials",
                                   "nickname": "Spotify（客户端凭证）"])
            }
            return .json(200, ["code": 200, "loggedIn": true, "mode": "pkce", "nickname": "Spotify",
                               "error": "读取 /me 失败"])
        } catch {
            return .json(200, ["code": 200, "loggedIn": true, "error": error.localizedDescription])
        }
    }

    private func search(_ req: HttpRequest) async -> HttpResponse {
        let s = [req.string("s"), req.string("q")].first(where: { !$0.isEmpty }) ?? ""
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .json(200, ["code": 200, "source": "spotify", "tracks": [], "songCount": 0])
        }
        let limit = scClamp(req.int("limit", 20), 1, 50)
        do {
            let r = try await sp("/search", ["q": s, "type": "track", "limit": String(limit)])
            if r.status != 200 {
                let msg = ((r.data["error"] as? [String: Any])?["message"] as? String)
                    ?? "Spotify 搜索失败 \(r.status)"
                return .json(200, ["code": r.status, "source": "spotify", "tracks": [], "songCount": 0,
                                   "error": msg, "note": "仅元数据 · 本期不接音频"])
            }
            let tracksData = scDict(r.data, "tracks")
            let items = (tracksData["items"] as? [[String: Any]] ?? []).filter { !$0.isEmpty }
            let tracks = items.compactMap { spotifyTrack($0) }.filter {
                !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
            }
            let total = scNum(tracksData["total"])
            return .json(200, ["code": 200, "source": "spotify", "tracks": tracks,
                               "songCount": total != 0 ? total : items.count,
                               "error": NSNull(), "note": "仅元数据 · 本期不接音频"])
        } catch {
            return .json(200, ["code": 400, "source": "spotify", "tracks": [], "songCount": 0,
                               "error": error.localizedDescription, "note": "仅元数据 · 本期不接音频"])
        }
    }
}
