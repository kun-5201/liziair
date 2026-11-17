import Foundation
import CoreImage
import UIKit

/// 网易云服务：weapi/eapi 直连 music.163.com、登录、会话。
/// 实现依据：specs/netease.md（server.mjs 全文 + npm 包 @neteasecloudmusicapienhanced/api@4.41.1 的
/// dj/recommend、dj/program、album/sublist、recommend/songs 四个模块）。
/// 边车（npm 包）在 iOS 上跑不了，/api/netease/* 的路由在这里用 weapi/eapi 直接实现：
/// 扫码 key/check 走 eapi（包里 APP_CONF.encrypt=true 时默认 eapi，type 硬编码为 3），
/// dj/专辑/每日推荐走 weapi；X-antiCheatToken 按包里的 register_checktoken_v3 从
/// ac.dun.163yun.com 实时取（取不到就按包的做法：不带头继续请求）。

final class NetEaseService {
    private let session = SessionStore.shared

    // 扫码诊断状态（必须放主类里：extension 里不能有存储属性）。
    private var lastQrCheck: [String: Any]?
    private var lastHarvest: [String: Any]?
    private var qrCache: [String: QrCacheEntry] = [:]
    private let qrCookieTTL: TimeInterval = 10 * 60

    // MARK: - 常量

    static let weapiUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let neteaseUA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.17.204416"
    static let baseURL = "https://music.163.com"

    // MARK: - 传输层（fetchUpstream：15 秒超时，最多 2 次，间隔 400ms；前端 60 秒超时内必须回）

    struct UpstreamResult {
        var status: Int
        var json: [String: Any]
        var setCookies: [String]
    }

    private func fetchUpstream(_ url: URL, headers: [String: String], body: Data,
                               timeout: TimeInterval = 15, attempts: Int = 2) async throws -> UpstreamResult {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                var req = URLRequest(url: url, timeoutInterval: timeout)
                req.httpMethod = "POST"
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = body
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw NSError(domain: "NetEase", code: -1, userInfo: [NSLocalizedDescriptionKey: "no http response"])
                }
                // 先收 cookie，再解析 JSON（和 server.mjs 的顺序一致）。
                var setCookies: [String] = []
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, ks.lowercased() == "set-cookie", let vs = v as? String {
                        setCookies.append(vs)
                    }
                }
                if !setCookies.isEmpty { session.saveCookies(setCookies) }
                // 再从 URLSession 的共享 cookie 仓补一份：多条 Set-Cookie 在
                // allHeaderFields 里会拼成一条（甚至可能看不到），但 URLSession.shared
                // 一定把响应 cookie 存进了共享仓（默认配置）。803 的 MUSIC_U 只走
                // Set-Cookie——丢了它，扫码就永远收不到登录态。
                if let stored = HTTPCookieStorage.shared.cookies(for: url) {
                    var extra: [String: String] = [:]
                    for c in stored { extra[c.name] = c.value }
                    if !extra.isEmpty { session.setCookies(extra) }
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return UpstreamResult(status: http.statusCode, json: obj, setCookies: setCookies)
                }
                let raw = String(data: data, encoding: .utf8) ?? ""
                return UpstreamResult(status: http.statusCode,
                                      json: ["code": 500, "raw": String(raw.prefix(500))],
                                      setCookies: setCookies)
            } catch {
                lastError = error
                if attempt < max(1, attempts) - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(400 * (attempt + 1)) * 1_000_000)
                }
            }
        }
        throw lastError ?? NSError(domain: "NetEase", code: -1, userInfo: [NSLocalizedDescriptionKey: "upstream failed"])
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        let s = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// weapi 请求：POST https://music.163.com/weapi + apiPath。
    func weapiRequest(_ apiPath: String, _ payload: [String: Any],
                      timeout: TimeInterval = 15, attempts: Int = 2) async throws -> UpstreamResult {
        var obj = payload
        obj["csrf_token"] = session.csrf
        guard let enc = NetEaseCrypto.weapi(obj) else {
            throw NSError(domain: "NetEase", code: -2, userInfo: [NSLocalizedDescriptionKey: "weapi encrypt failed"])
        }
        let url = URL(string: Self.baseURL + "/weapi" + apiPath)!
        let headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": "https://music.163.com",
            "User-Agent": Self.weapiUA,
            "Cookie": session.cookieHeader,
            "X-Real-IP": "118.88.88.88",
            "X-Forwarded-For": "118.88.88.88",
        ]
        let body = formBody([("params", enc.params), ("encSecKey", enc.encSecKey), ("csrf_token", session.csrf)])
        return try await fetchUpstream(url, headers: headers, body: body, timeout: timeout, attempts: attempts)
    }

    /// eapi 请求：签名路径 /api + apiPath，实际打到 https://music.163.com/eapi + apiPath。
    /// checkToken 为 true 时先取易盾 token 加 X-antiCheatToken 头（取不到就不带，继续请求）。
    func eapiRequest(_ apiPath: String, _ payload: [String: Any], checkToken: Bool = false,
                     timeout: TimeInterval = 15, attempts: Int = 2) async throws -> UpstreamResult {
        let signedPath = apiPath.hasPrefix("/api") ? apiPath : "/api" + apiPath
        guard let params = NetEaseCrypto.eapi(apiPath: signedPath, object: payload, csrf: session.csrf) else {
            throw NSError(domain: "NetEase", code: -2, userInfo: [NSLocalizedDescriptionKey: "eapi encrypt failed"])
        }
        let url = URL(string: Self.baseURL + "/eapi" + apiPath)!
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": "https://music.163.com",
            "Origin": "https://music.163.com",
            "User-Agent": Self.neteaseUA,
            "Cookie": session.cookieHeader,
        ]
        if checkToken, let token = await fetchAntiCheatToken(), !token.isEmpty {
            headers["X-antiCheatToken"] = token
        }
        let body = formBody([("params", params)])
        return try await fetchUpstream(url, headers: headers, body: body, timeout: timeout, attempts: attempts)
    }

    /// 易盾反作弊 token v3（包里 register_checktoken_v3 的做法）：
    /// GET https://ac.dun.163yun.com/v3/b?pn=YD00000558929251，解析 null([200,ts,"TOKEN"])。
    func fetchAntiCheatToken() async -> String? {
        guard let url = URL(string: "https://ac.dun.163yun.com/v3/b?pn=YD00000558929251") else { return nil }
        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "GET"
            let (data, _) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8) ?? ""
            if let range = text.range(of: #"null\(\[200,\d+,"([^"]+)"\]\)"#, options: .regularExpression) {
                let m = String(text[range])
                if let first = m.firstIndex(of: "\""), let last = m.lastIndex(of: "\""), first != last {
                    return String(m[m.index(after: first)..<last])
                }
            }
        } catch { /* 取不到就返回 nil，调用方不带头继续请求 */ }
        return nil
    }

    // MARK: - 路由表（ROUTES，server.mjs 原样）

    struct Route {
        var path: String
        var channel: String // "weapi" 或 "eapi"
    }

    static let routes: [String: Route] = [
        "login/qr/key": Route(path: "/login/qrcode/unikey", channel: "eapi"),
        "login/qr/check": Route(path: "/login/qrcode/client/login", channel: "eapi"),
        "login/cellphone": Route(path: "/login/cellphone", channel: "weapi"),
        "login/status": Route(path: "/w/nuser/account/get", channel: "weapi"),
        "logout": Route(path: "/logout", channel: "weapi"),
        "user/playlist": Route(path: "/user/playlist", channel: "weapi"),
        "user/detail": Route(path: "/v1/user/detail/:uid", channel: "weapi"),
        "playlist/detail": Route(path: "/v6/playlist/detail", channel: "weapi"),
        "playlist/track/all": Route(path: "/v6/playlist/detail", channel: "weapi"),
        "song/url": Route(path: "/song/enhance/player/url/v1", channel: "weapi"),
        "song/detail": Route(path: "/v3/song/detail", channel: "weapi"),
        "song/wiki": Route(path: "/song/play/about/block/page", channel: "weapi"),
        "lyric": Route(path: "/song/lyric/v1", channel: "weapi"),
        "search": Route(path: "/search/get", channel: "weapi"),
        "personalized": Route(path: "/personalized/newsong", channel: "weapi"),
        "recommend/songs": Route(path: "/v1/discovery/recommend/songs", channel: "weapi"),
        "top/playlist": Route(path: "/personalized/playlist", channel: "weapi"),
        "artist/:id": Route(path: "/v1/artist/:id", channel: "weapi"),
        "artist/albums/:id": Route(path: "/artist/albums/:id", channel: "weapi"),
        "artist/songs": Route(path: "/v1/artist/songs", channel: "weapi"),
        "album/:id": Route(path: "/v1/album/:id", channel: "weapi"),
    ]

    /// matchRoute：先精确匹配，再按含 : 的 key 逐段匹配。
    func matchRoute(_ name: String) -> (key: String, route: Route, params: [String: String])? {
        if let r = Self.routes[name] { return (name, r, [:]) }
        let nameSegs = name.split(separator: "/").map(String.init)
        for (key, route) in Self.routes where key.contains(":") {
            let keySegs = key.split(separator: "/").map(String.init)
            guard keySegs.count == nameSegs.count else { continue }
            var params: [String: String] = [:]
            var ok = true
            for (ks, ns) in zip(keySegs, nameSegs) {
                if ks.hasPrefix(":") { params[String(ks.dropFirst())] = ns }
                else if ks != ns { ok = false; break }
            }
            if ok { return (key, route, params) }
        }
        return nil
    }

    // MARK: - 小工具

    func idList(_ v: Any?) -> [Int] {
        guard let v else { return [] }
        let s: String
        if let n = v as? NSNumber { s = n.stringValue }
        else if let str = v as? String { s = str }
        else { return [] }
        return s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != 0 }
    }

    func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
    func int(_ d: [String: Any], _ k: String) -> Int {
        if let n = d[k] as? Int { return n }
        if let n = d[k] as? NSNumber { return n.intValue }
        if let s = d[k] as? String, let n = Int(s) { return n }
        return 0
    }
    func intOr(_ d: [String: Any], _ k: String, _ def: Int) -> Int {
        if d[k] == nil { return def }
        return int(d, k)
    }
    func arr(_ d: [String: Any], _ k: String) -> [[String: Any]] { d[k] as? [[String: Any]] ?? [] }
    func dict(_ d: [String: Any], _ k: String) -> [String: Any] { d[k] as? [String: Any] ?? [:] }

    // MARK: - 曲目归一化（toTrack / fetchTrackDetails）

    func toTrack(_ s: [String: Any]) -> [String: Any]? {
        guard let id = s["id"] as? Int ?? (s["id"] as? NSNumber)?.intValue else { return nil }
        let artists = (s["ar"] as? [[String: Any]]) ?? (s["artists"] as? [[String: Any]]) ?? []
        let album = (s["al"] as? [String: Any]) ?? (s["album"] as? [String: Any]) ?? [:]
        let names = artists.compactMap { $0["name"] as? String }
        let cover = str(album, "picUrl").isEmpty ? (str(album, "blurPicUrl").isEmpty ? (str(s, "picUrl").isEmpty ? str(s, "coverImgUrl") : str(s, "picUrl")) : str(album, "blurPicUrl")) : str(album, "picUrl")
        let dt = int(s, "dt")
        let out: [String: Any] = [
            "id": id,
            "name": str(s, "name"),
            "artists": names.joined(separator: " / ").isEmpty ? "未知歌手" : names.joined(separator: " / "),
            "artistIds": artists.compactMap { ($0["id"] as? NSNumber)?.intValue ?? $0["id"] as? Int },
            "album": str(album, "name"),
            "albumId": album["id"] as? Int ?? NSNull(),
            "cover": cover,
            "duration": dt != 0 ? dt : int(s, "duration"),
            "fee": s["fee"] as? Int ?? 0,
        ]
        return out
    }

    /// 每批最多 500 个 id 调 /v3/song/detail，收集各批 d.songs。
    func fetchTrackDetails(_ ids: [Int]) async -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }
        var out: [[String: Any]] = []
        var i = 0
        while i < ids.count {
            let batch = Array(ids[i..<min(i + 500, ids.count)])
            do {
                let c = try JSONSerialization.data(withJSONObject: batch.map { ["id": $0] })
                let cStr = String(data: c, encoding: .utf8) ?? "[]"
                let r = try await weapiRequest("/v3/song/detail", ["c": cStr])
                out.append(contentsOf: arr(r.json, "songs"))
            } catch { /* 某批失败就跳过，不影响其他批 */ }
            i += 500
        }
        return out
    }

    /// 富文本歌词转 LRC（richLyricToLrc）：只改能解析成 {c:[{tx:String}]} 的行，其余原样保留；
    /// 失败退回原串、绝不抛异常。
    func richLyricToLrc(_ lyric: String) -> String {
        guard !lyric.isEmpty else { return lyric }
        // 整串是 JSON 数组时逐项转。
        if let data = lyric.data(using: .utf8),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return items.compactMap { richLineToLrc($0, prevTime: nil) }.joined(separator: "\n")
        }
        var outLines: [String] = []
        var prevTime: Int? = nil
        for line in lyric.components(separatedBy: "\n") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let c = obj["c"] as? [[String: Any]],
               c.allSatisfy({ $0["tx"] is String }) {
                let t = (obj["t"] as? NSNumber)?.intValue
                let time: Int
                if let t { time = max(0, t) } else if let p = prevTime { time = p + 1000 } else { time = 0 }
                prevTime = time
                let text = c.compactMap { $0["tx"] as? String }.joined()
                outLines.append("[\(formatLyricTime(time))]\(text)")
            } else {
                outLines.append(line)
            }
        }
        return outLines.joined(separator: "\n")
    }

    private func richLineToLrc(_ obj: [String: Any], prevTime: Int?) -> String? {
        guard let c = obj["c"] as? [[String: Any]] else { return nil }
        let text = c.compactMap { $0["tx"] as? String }.joined()
        let t = (obj["t"] as? NSNumber)?.intValue ?? 0
        return "[\(formatLyricTime(max(0, t)))]\(text)"
    }

    /// 时间格式 [mm:ss.xx]：先落到 10ms 再格式化，避免 59.999s 进成 60.00。
    private func formatLyricTime(_ ms: Int) -> String {
        let rounded = (ms / 10) * 10
        let totalSeconds = rounded / 1000
        let mm = totalSeconds / 60
        let ss = totalSeconds % 60
        let xx = (rounded % 1000) / 10
        return String(format: "%02d:%02d.%02d", mm, ss, xx)
    }

    func profileOf(_ p: [String: Any]?) -> [String: Any]? {
        guard let p, int(p, "userId") != 0 else { return nil }
        return [
            "userId": int(p, "userId"),
            "nickname": str(p, "nickname"),
            "avatar": str(p, "avatarUrl").isEmpty ? str(p, "avatar") : str(p, "avatarUrl"),
            "vipType": int(p, "vipType"),
        ]
    }
}

extension NetEaseService {
    // MARK: - 通用转发 /api/*（ROUTES + 参数整形 + normalize）

    func handleApi(_ req: HttpRequest) async -> HttpResponse {
        let name = String(req.path.dropFirst("/api/".count))
        guard let hit = matchRoute(name) else {
            return .json(404, ["error": "unknown api: \(name)"])
        }
        var payload = req.params
        // 路径占位符替换（pathParams 优先，取不到回 400），替换后从 payload 删除。
        var apiPath = hit.route.path
        for (key, value) in hit.params {
            apiPath = apiPath.replacingOccurrences(of: ":\(key)", with: value)
            payload.removeValue(forKey: key)
        }
        for part in apiPath.split(separator: "/") where part.hasPrefix(":") {
            let key = String(part.dropFirst())
            guard let v = payload[key] else {
                return .json(400, ["error": "\(key) required"])
            }
            apiPath = apiPath.replacingOccurrences(of: ":\(key)", with: "\(v)")
            payload.removeValue(forKey: key)
        }

        // song/detail 不走通用 weapiRequest，直接调 fetchTrackDetails。
        if hit.key == "song/detail" {
            let ids = idList(payload["ids"])
            let tracks = await fetchTrackDetails(ids)
            return .json(200, ["code": 200, "tracks": tracks.compactMap { toTrack($0) }])
        }

        // 参数整形。
        payload = shapePayload(routeKey: hit.key, payload: payload)

        let t0 = Date()
        do {
            let result: UpstreamResult
            // 搜索要快：上游慢网时别重试、别拖到前端 60 秒超时才掐掉——
            // 单次 10 秒上限，失败就回 502，前端显示明确原因。
            // 其它接口保持 15 秒 × 2 次。
            let isSearch = hit.key == "search"
            let reqTimeout: TimeInterval = isSearch ? 10 : 15
            let reqAttempts = isSearch ? 1 : 2
            if hit.route.channel == "eapi" {
                result = try await eapiRequest(apiPath, payload, timeout: reqTimeout, attempts: reqAttempts)
            } else {
                result = try await weapiRequest(apiPath, payload, timeout: reqTimeout, attempts: reqAttempts)
            }
            let normalized = await normalize(routeKey: hit.key, data: result.json, payload: payload)
            if isSearch {
                DiagLog.shared.recordSearch([
                    "endpoint": "/search/get",
                    "ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "http": result.status,
                    "code": normalized["code"] as Any,
                    "count": (normalized["tracks"] as? [[String: Any]])?.count ?? 0,
                    "at": Int(Date().timeIntervalSince1970),
                ])
            }
            return .json(200, normalized)
        } catch {
            if hit.key == "search" {
                DiagLog.shared.recordSearch([
                    "endpoint": "/search/get",
                    "ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "error": error.localizedDescription,
                    "at": Int(Date().timeIntervalSince1970),
                ])
            }
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    private func shapePayload(routeKey: String, payload: [String: Any]) -> [String: Any] {
        var p = payload
        switch routeKey {
        case "login/qr/key":
            p = ["type": 1]
        case "login/qr/check":
            var np: [String: Any] = ["type": 1]
            if let k = p["key"] { np["key"] = k }
            p = np
        case "song/url":
            let levels = ["standard", "higher", "exhigh", "lossless", "hires", "jymaster", "jyeffect"]
            let level = levels.contains(str(p, "level")) ? str(p, "level") : "exhigh"
            let encodeType = (level == "standard" || level == "higher") ? "mp3" : "flac"
            let ids = idList(p["ids"])
            p = ["ids": (try? JSONSerialization.data(withJSONObject: ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
                 "level": level, "encodeType": encodeType]
        case "playlist/detail", "playlist/track/all":
            p = ["id": int(p, "id"), "n": 1000, "s": 8]
        case "lyric":
            p = ["id": int(p, "id"), "cp": false, "lv": -1, "tv": -1, "rv": -1,
                 "kv": -1, "yv": -1, "ytv": -1, "yrv": -1]
        case "song/wiki":
            p = ["songId": int(p, "id")]
        case "user/playlist":
            p = ["uid": int(p, "uid"), "limit": 1000, "offset": 0, "includeVideo": true]
        case "user/detail":
            p = ["uid": int(p, "uid") != 0 ? int(p, "uid") : int(p, "userId")]
        case "search":
            p = ["s": str(p, "s").isEmpty ? str(p, "keywords") : str(p, "s"),
                 "type": 1, "limit": intOr(p, "limit", 30), "offset": intOr(p, "offset", 0)]
        case "top/playlist":
            p = ["cat": str(p, "cat").isEmpty ? "全部" : str(p, "cat"),
                 "order": str(p, "order").isEmpty ? "hot" : str(p, "order"),
                 "limit": intOr(p, "limit", 12), "offset": intOr(p, "offset", 0), "total": true]
        case "artist/albums/:id":
            p = ["limit": intOr(p, "limit", 12), "offset": intOr(p, "offset", 0), "total": true]
        case "artist/songs":
            p = ["id": int(p, "id"), "limit": intOr(p, "limit", 100), "offset": intOr(p, "offset", 0),
                 "order": str(p, "order") == "time" ? "time" : "hot"]
        default:
            break
        }
        return p
    }

    private func normalize(routeKey: String, data: [String: Any], payload: [String: Any]) async -> [String: Any] {
        let code = intOr(data, "code", 200)
        switch routeKey {
        case "search":
            let result = dict(data, "result")
            let tracks = arr(result, "songs").compactMap { toTrack($0) }
            // Folia 的做法：一次请求直接返回，不阻塞在补封面那步。
            // /search/get 回的歌没有 al.picUrl（只有 picId，拼不出封面地址），
            // 以前这里每搜一次都要再调 /v3/song/detail 全量补封面（最长 6 秒），
            // 慢网下搜索全程被拖到 10 秒以上。改成先返回曲目，封面由前端
            // 对可见行调 /api/song/detail 懒补（见 app.js renderTracks）。
            let songCount = (result["songCount"] as? Int) ?? tracks.count
            return ["code": code, "tracks": tracks, "songCount": songCount]
        case "song/url":
            let items = arr(data, "data").map { s -> [String: Any] in
                let url = s["url"] as? String
                return [
                    "id": s["id"] as Any,
                    "url": url as Any,
                    "br": s["br"] as Any,
                    "size": s["size"] as Any,
                    "fee": s["fee"] as? Int ?? 0,
                    "reason": url != nil ? NSNull() : ((s["code"] as? Int) == -110 ? "vip" : "unavailable"),
                    "freeTrialInfo": s["freeTrialInfo"] as Any,
                    "level": s["level"] as Any,
                ]
            }
            return ["code": code, "data": items]
        case "lyric":
            let lrcText = str(dict(data, "lrc"), "lyric").isEmpty ? str(data, "lyric") : str(dict(data, "lrc"), "lyric")
            let lyric = richLyricToLrc(lrcText)
            let yrc = str(dict(data, "yrc"), "lyric")
            return [
                "code": code,
                "lyric": lyric,
                "yrc": yrc,
                "tlyric": str(dict(data, "tlyric"), "lyric"),
                "ytlrc": str(dict(data, "ytlrc"), "lyric"),
                "romalrc": str(dict(data, "romalrc"), "lyric"),
                "nolyric": data["nolyric"] as? Bool ?? false,
                "format": !yrc.isEmpty ? "yrc" : (!lyric.isEmpty ? "lrc" : "none"),
            ]
        case "playlist/detail", "playlist/track/all":
            let p = dict(data, "playlist")
            var tracks = arr(p, "tracks")
            let ids = arr(p, "trackIds").compactMap { $0["id"] as? Int }
            if ids.count > tracks.count || routeKey == "playlist/track/all" {
                tracks = await fetchTrackDetails(ids)
            }
            let creator = dict(p, "creator")
            return [
                "code": code,
                "playlist": [
                    "id": p["id"] as Any,
                    "name": str(p, "name"),
                    "cover": str(p, "coverImgUrl"),
                    "trackCount": int(p, "trackCount"),
                    "playCount": int(p, "playCount"),
                    "description": str(p, "description"),
                    "creator": creator.isEmpty ? NSNull() : ["nickname": str(creator, "nickname"), "avatar": str(creator, "avatarUrl")],
                ],
                "tracks": tracks.compactMap { toTrack($0) },
            ]
        case "user/playlist":
            let lists = arr(data, "playlist").map { p -> [String: Any] in
                ["id": p["id"] as Any, "name": str(p, "name"), "cover": str(p, "coverImgUrl"),
                 "trackCount": int(p, "trackCount"), "playCount": int(p, "playCount"),
                 "subscribed": p["subscribed"] as? Bool ?? false,
                 "specialType": (p["specialType"] as? NSNumber)?.intValue ?? 0]
            }
            return ["code": code, "playlists": lists]
        case "user/detail":
            let p = dict(data, "profile")
            return [
                "code": code,
                "level": intOr(data, "level", 0),
                "listenSongs": intOr(data, "listenSongs", 0),
                "createDays": intOr(data, "createDays", 0),
                "canSeePlayRecord": data["peopleCanSeeMyPlayRecord"] as? Bool ?? false,
                "profile": [
                    "userId": int(p, "userId"), "nickname": str(p, "nickname"),
                    "avatar": str(p, "avatarUrl"), "background": str(p, "backgroundUrl"),
                    "signature": str(p, "signature"), "description": str(p, "description"),
                    "follows": int(p, "follows"), "followeds": int(p, "followeds"),
                    "playlistCount": int(p, "playlistCount"), "eventCount": int(p, "eventCount"),
                    "createTime": int(p, "createTime"), "province": int(p, "province"),
                    "city": int(p, "city"), "gender": int(p, "gender"), "vipType": int(p, "vipType"),
                    "auth": (p["allAuthTypes"] as? [[String: Any]] ?? []).compactMap { $0["desc"] as? String },
                ],
            ]
        case "personalized":
            let items = arr(data, "result").map { toTrack(dict($0, "song").isEmpty ? $0 : dict($0, "song")) }
            return ["code": code, "tracks": items.compactMap { $0 }]
        case "top/playlist":
            let list = arr(data, "playlists").isEmpty ? (arr(data, "result").isEmpty ? arr(data, "recommend") : arr(data, "result")) : arr(data, "playlists")
            let lists = list.compactMap { p -> [String: Any]? in
                guard p["id"] != nil else { return nil }
                let cover = str(p, "coverImgUrl").isEmpty ? (str(p, "picUrl").isEmpty ? str(p, "pic") : str(p, "picUrl")) : str(p, "coverImgUrl")
                return ["id": p["id"] as Any, "name": str(p, "name"), "cover": cover,
                        "count": (p["playCount"] as? Int) ?? (p["playcount"] as? Int) ?? 0,
                        "creator": str(dict(p, "creator"), "nickname"),
                        "tracks": int(p, "trackCount")]
            }
            return ["code": code, "more": (data["more"] as? Bool) ?? (data["hasMore"] as? Bool) ?? false, "playlists": lists]
        case "song/wiki":
            let blocks = arr(dict(data, "data"), "blocks").isEmpty ? arr(data, "blocks") : arr(dict(data, "data"), "blocks")
            let basic = blocks.first { str($0, "code") == "SONG_PLAY_ABOUT_SONG_BASIC" } ?? [:]
            let creatives = basic["creatives"] as? [[String: Any]] ?? []
            func pick(_ type: String) -> [String: Any] {
                creatives.first { str($0, "creativeType") == type } ?? [:]
            }
            func textOf(_ c: [String: Any]) -> String? {
                let links = arr(dict(c, "uiElement"), "textLinks")
                return links.first.flatMap { str($0, "text").isEmpty ? nil : str($0, "text") }
            }
            func listOf(_ c: [String: Any]) -> [String] {
                (c["resources"] as? [[String: Any]] ?? []).compactMap {
                    let t = str($0, "text")
                    return t.isEmpty ? str($0, "name") : t
                }.filter { !$0.isEmpty }
            }
            let bpmText = textOf(pick("bpm"))
            let bpm: Any = (bpmText != nil && bpmText!.allSatisfy { $0.isNumber }) ? Int(bpmText!) as Any : NSNull()
            let similar = blocks.first { str($0, "code") == "SONG_PLAY_ABOUT_SIMILAR_SONG" } ?? [:]
            var similarIds: [Int] = []
            for c in similar["creatives"] as? [[String: Any]] ?? [] {
                for r in c["resources"] as? [[String: Any]] ?? [] {
                    if let id = r["resourceId"] as? Int ?? r["id"] as? Int { similarIds.append(id) }
                }
            }
            return [
                "code": code, "bpm": bpm,
                "language": textOf(pick("language")) as Any,
                "tags": listOf(pick("songTag")),
                "bizTags": listOf(pick("songBizTag")),
                "awards": listOf(pick("songAward")),
                "similarIds": similarIds,
            ]
        case "recommend/songs":
            let tracks = arr(data, "recommend").compactMap { toTrack($0) }
            return ["code": code, "tracks": tracks]
        case "artist/:id":
            let a = dict(data, "artist")
            return [
                "code": code,
                "artist": [
                    "id": a["id"] as Any, "name": str(a, "name").isEmpty ? str(a, "nickname") : str(a, "name"),
                    "nickname": str(a, "nickname"),
                    "avatar": str(a, "img1v1Url").isEmpty ? (str(a, "cover").isEmpty ? str(a, "picUrl") : str(a, "cover")) : str(a, "img1v1Url"),
                    "cover": str(a, "cover").isEmpty ? str(a, "img1v1Url") : str(a, "cover"),
                    "briefDesc": str(a, "briefDesc"),
                    "albumSize": int(a, "albumSize"), "musicSize": int(a, "musicSize"),
                    "alias": a["alias"] as Any, "trans": str(a, "trans"),
                ],
                "hotSongs": arr(data, "hotSongs").compactMap { toTrack($0) },
            ]
        case "artist/albums/:id":
            let albums = (arr(data, "hotAlbums").isEmpty ? arr(data, "albums") : arr(data, "hotAlbums")).compactMap { a -> [String: Any]? in
                guard a["id"] != nil else { return nil }
                let cover = str(a, "picUrl").isEmpty ? (str(a, "blurPicUrl").isEmpty ? str(a, "coverImgUrl") : str(a, "blurPicUrl")) : str(a, "picUrl")
                return ["id": a["id"] as Any, "name": str(a, "name"), "cover": cover,
                        "publishTime": int(a, "publishTime"),
                        "size": (a["size"] as? Int) ?? (a["songCount"] as? Int) ?? 0]
            }
            return ["code": code, "more": (data["more"] as? Bool) ?? (data["hasMore"] as? Bool) ?? false, "albums": albums]
        case "artist/songs":
            return ["code": code,
                    "total": (data["total"] as? Int) ?? arr(data, "songs").count,
                    "more": (data["more"] as? Bool) ?? (data["hasMore"] as? Bool) ?? false,
                    "songs": arr(data, "songs").compactMap { toTrack($0) }]
        case "album/:id":
            let al = dict(data, "album")
            return [
                "code": code,
                "album": [
                    "id": al["id"] as Any, "name": str(al, "name"),
                    "cover": str(al, "picUrl").isEmpty ? str(al, "blurPicUrl") : str(al, "picUrl"),
                    "company": str(al, "company"), "description": str(al, "description"),
                    "publishTime": int(al, "publishTime"),
                    "size": (al["size"] as? Int) ?? arr(data, "songs").count,
                    "artists": (al["artists"] as? [[String: Any]] ?? al["ar"] as? [[String: Any]] ?? []).map { ["id": $0["id"] as Any, "name": str($0, "name")] },
                ],
                "songs": arr(data, "songs").compactMap { toTrack($0) },
            ]
        case "login/status":
            if let p = profileOf(dict(data, "profile")) {
                return ["loggedIn": true, "profile": p]
            }
            return ["loggedIn": false]
        case "login/qr/key":
            return ["code": code, "key": data["unikey"] as Any, "message": data["message"] as Any]
        case "login/qr/check":
            recordQrCheck(data, channel: "eapi")
            return [
                "code": data["code"] as Any,
                "message": (data["message"] as? String) ?? (data["msg"] as? String) ?? (data["errmsg"] as? String) ?? "",
                "nickname": data["nickname"] as Any,
                "avatar": data["avatarUrl"] as Any,
                "loggedIn": session.hasMusicU,
            ]
        default:
            return data
        }
    }
}

extension NetEaseService {
    // MARK: - /api/netease/*（边车透传的 Swift 实现）

    func handleNetease(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/netease/".count))
        switch part {
        case "health":
            // iOS 上没有独立边车进程；本地服务本身就是健康的。
            return .json(200, ["code": 200, "ok": true])
        case "login/qr/key":
            return await neteaseQrKey()
        case "login/qr/check":
            return await neteaseQrCheck(req)
        case "recommend/songs":
            var p2: [String: Any] = [:]
            if let a = req.params["afresh"] { p2["afresh"] = a }
            return await passthroughWeapi("/api/v3/discovery/recommend/songs", p2)
        case "dj/recommend":
            return await passthroughWeapi("/api/djradio/recommend/v1", [:])
        case "dj/program":
            var p3: [String: Any] = [
                "radioId": req.int("rid"), "limit": req.int("limit", 30),
                "offset": req.int("offset"),
            ]
            if let a = req.params["asc"] { p3["asc"] = a }
            return await passthroughWeapi("/api/dj/program/byradio", p3)
        case "album/sublist":
            return await passthroughWeapi("/api/album/sublist", [
                "limit": req.int("limit", 100), "offset": req.int("offset"), "total": true,
            ])
        default:
            return .json(404, ["error": "unknown netease api"])
        }
    }

    /// 边车透传：weapi 直连，响应原样返回（无 normalize）。
    private func passthroughWeapi(_ apiPath: String, _ payload: [String: Any]) async -> HttpResponse {
        do {
            let r = try await weapiRequest(apiPath, payload)
            return .json(r.status == 200 ? 200 : r.status, r.json)
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    // MARK: - 扫码登录（边车版：/api/netease/login/qr/*）

    /// key：eapi /login/qrcode/unikey（type 3，包里模块硬编码），再本地生成二维码图。
    private func neteaseQrKey() async -> HttpResponse {
        do {
            let r = try await eapiRequest("/login/qrcode/unikey", ["type": 3], checkToken: true)
            let unikey = r.json["unikey"] as? String
            guard let unikey, !unikey.isEmpty else {
                return .json(r.json["code"] as? Int ?? 502, [
                    "code": r.json["code"] as Any, "key": NSNull(),
                    "channel": "netease-api",
                    "message": (r.json["message"] as? String) ?? "拿不到二维码 key",
                ])
            }
            let qrimg = qrDataURL(for: "https://music.163.com/login?codekey=\(unikey)")
            return .json(200, ["code": 200, "key": unikey, "qrimg": qrimg, "channel": "netease-api"])
        } catch {
            return .json(502, ["code": 502, "key": NSNull(), "channel": "netease-api", "message": error.localizedDescription])
        }
    }

    /// check：eapi /login/qrcode/client/login（type 3）。803 时当场抓 cookie 并 harvest。
    private func neteaseQrCheck(_ req: HttpRequest) async -> HttpResponse {
        let key = req.string("key")
        guard !key.isEmpty else {
            return .json(400, ["code": 400, "message": "key required"])
        }
        do {
            let r = try await eapiRequest("/login/qrcode/client/login", ["key": key, "type": 3], checkToken: true)
            let code = (r.json["code"] as? NSNumber)?.intValue ?? 0
            let message = (r.json["message"] as? String) ?? (r.json["msg"] as? String) ?? ""
            if code == 803 {
                let extracted = extractCookie(body: r.json, setCookies: r.setCookies)
                if extracted.pairs["MUSIC_U"] != nil {
                    qrCacheSet(key: key, pairs: extracted.pairs, field: extracted.field)
                }
                let h = await runHarvest(key: key)
                recordQrCheck(r.json, channel: "netease-api")
                return .json(200, [
                    "code": code, "message": message.isEmpty ? "授权登陆成功" : message,
                    "hasMusicU": true, "cookieKeys": h["keys"] as Any,
                    "channel": "netease-api", "loggedIn": h["ok"] as? Bool ?? false,
                    "profile": h["profile"] as Any,
                    "harvest": ["tried": h["tried"] as Any, "gotCookie": true, "field": h["field"] as Any],
                ])
            }
            let keys = Array(extractCookie(body: r.json, setCookies: r.setCookies).pairs.keys)
            recordQrCheck(r.json, channel: "netease-api")
            return .json(200, [
                "code": code, "message": message,
                "hasMusicU": keys.contains("MUSIC_U"), "cookieKeys": keys,
                "channel": "netease-api",
            ])
        } catch {
            return .json(502, ["code": 502, "message": error.localizedDescription, "channel": "netease-api"])
        }
    }

    /// 二维码图：CoreImage 生成，与包里 login_qr_create 的 data URL 格式一致
    ///（https://music.163.com/login?codekey=<key>，平台默认 pc，不带 chainId）。
    private func qrDataURL(for urlString: String) -> String {
        guard let data = urlString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return "" }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return "" }
        let scale = 512.0 / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return "" }
        let image = UIImage(cgImage: cgImage)
        guard let png = image.pngData() else { return "" }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    // MARK: - 扫码诊断

    func recordQrCheck(_ raw: [String: Any], channel: String) {
        lastQrCheck = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "channel": channel,
            "code": raw["code"] as Any,
            "message": (raw["message"] as? String) ?? (raw["msg"] as? String) ?? "",
            "hasMusicU": session.hasMusicU,
            "loggedIn": session.hasMusicU,
            "cookieKeys": session.cookieKeys,
        ]
    }

    func lastQrCheckPayload() -> [String: Any] {
        var out = lastQrCheck ?? [
            "at": NSNull(), "channel": NSNull(), "code": NSNull(),
            "message": "还没有 check 过",
        ]
        out["hasMusicU"] = session.hasMusicU
        out["loggedIn"] = session.hasMusicU
        out["cookieKeys"] = session.cookieKeys
        out["harvest"] = lastHarvest as Any
        return out
    }

    // MARK: - harvest（扫码收尾，harvest-core.mjs 的逻辑）

    private struct QrCacheEntry {
        var pairs: [String: String]
        var field: String?
        var at: Date
    }

    private func qrCacheSet(key: String, pairs: [String: String], field: String?) {
        qrCache[key] = QrCacheEntry(pairs: pairs, field: field, at: Date())
    }

    private func qrCacheGet(key: String) -> QrCacheEntry? {
        qrCache = qrCache.filter { Date().timeIntervalSince($0.value.at) < qrCookieTTL }
        return qrCache[key]
    }

    /// extractCookie：三种来源按优先顺序，优先返回含 MUSIC_U 的那份。
    func extractCookie(body: [String: Any], setCookies: [String]) -> (field: String?, pairs: [String: String]) {
        if let s = body["cookie"] as? String, !s.isEmpty {
            let pairs = parseCookieInput(s)
            if pairs["MUSIC_U"] != nil { return ("body.cookie", pairs) }
            if !pairs.isEmpty { return ("body.cookie", pairs) }
        }
        if let d = body["data"] as? [String: Any], let s = d["cookie"] as? String, !s.isEmpty {
            let pairs = parseCookieInput(s)
            if pairs["MUSIC_U"] != nil { return ("body.data.cookie", pairs) }
            if !pairs.isEmpty { return ("body.data.cookie", pairs) }
        }
        if !setCookies.isEmpty {
            // Set-Cookie 分支必须用逗号感知的解析：URLSession 会把多条 Set-Cookie
            // 拼成一条（", " 连接），parseCookieInput 只按 ';' 切，会把非首位 cookie
            // 的键解析成 ", MUSIC_U" 这类带前导逗号的键，导致 pairs["MUSIC_U"] 查不到
            // ——803 明明到了，harvest 却报 not-authorized（见 runHarvest 兜底）。
            let pairs = SessionStore.parseSetCookieStrings(setCookies)
            if !pairs.isEmpty { return ("set-cookie", pairs) }
        }
        return (nil, [:])
    }

    /// parseCookieInput：宽容解析（去 Cookie: 前缀、去引号、裸值当 MUSIC_U、跳过属性键）。
    func parseCookieInput(_ raw: String) -> [String: String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") { s = String(s.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        if !s.contains("=") && !s.contains(";") {
            return s.isEmpty ? [:] : ["MUSIC_U": s]
        }
        let attrs: Set<String> = ["path", "domain", "expires", "max-age", "secure", "httponly", "samesite", "version", "priority", "comment", "partitioned"]
        var out: [String: String] = [:]
        for seg in s.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !v.isEmpty, !attrs.contains(k.lowercased()) else { continue }
            out[k] = v
        }
        return out
    }

    private func slim(_ pairs: [String: String]) -> [String: String] {
        pairs.filter { !$0.value.isEmpty }
    }

    /// runHarvest：按 cache → recheck → status 的顺序找 MUSIC_U；拿到后快照→整份替换→校验，失败回滚。
    func runHarvest(key: String) async -> [String: Any] {
        var tried: [String] = []
        var code: Int? = nil
        var field: String? = nil
        var pairs: [String: String] = [:]

        if let cached = qrCacheGet(key: key), cached.pairs["MUSIC_U"] != nil {
            tried.append("cache")
            pairs = cached.pairs
            field = cached.field
        }
        if pairs["MUSIC_U"] == nil {
            tried.append("check")
            do {
                let r = try await eapiRequest("/login/qrcode/client/login", ["key": key, "type": 3], checkToken: true)
                code = (r.json["code"] as? NSNumber)?.intValue
                let ex = extractCookie(body: r.json, setCookies: r.setCookies)
                if ex.pairs["MUSIC_U"] != nil {
                    pairs = ex.pairs
                    field = ex.field
                    qrCacheSet(key: key, pairs: pairs, field: field)
                }
            } catch { /* 重查失败就继续走 status */ }
        }
        if pairs["MUSIC_U"] == nil {
            tried.append("status")
            do {
                let r = try await weapiRequest("/w/nuser/account/get", [:])
                let ex = extractCookie(body: r.json, setCookies: r.setCookies)
                if ex.pairs["MUSIC_U"] != nil {
                    pairs = ex.pairs
                    field = ex.field
                }
            } catch { /* 状态也失败就按无 MUSIC_U 处理 */ }
        }

        // 兜底：fetchUpstream 可能已把 MUSIC_U 存进 SessionStore（803 响应
        // 的 Set-Cookie），只是上面三步都没从响应里解析出来。会话本身已登录
        // 就别再报 not-authorized / no-music-u，直接校验它。
        if pairs["MUSIC_U"] == nil, session.hasMusicU {
            do {
                if let v = try await sessionVerify(), let profile = v["profile"] {
                    let out: [String: Any] = [
                        "ok": true, "code": code as Any, "gotCookie": true, "field": "session",
                        "keys": session.cookieKeys, "tried": tried + ["session"], "profile": profile,
                    ]
                    lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": true,
                                   "tried": tried + ["session"], "gotCookie": true, "field": "session", "cookieKeys": session.cookieKeys]
                    return out
                }
            } catch { /* 校验出错就按原路返回失败 */ }
        }

        let keys = Array(pairs.keys)
        guard pairs["MUSIC_U"] != nil else {
            let reason = (code != nil && code != 803) ? "not-authorized" : "no-music-u"
            let message = (code != nil && code != 803)
                ? "上游这次回的是 \(code!)（不是 803）：二维码 key 已被用过或已过期"
                : "扫码已确认，但上游这次没下发 MUSIC_U"
            let out: [String: Any] = [
                "ok": false, "reason": reason, "code": code as Any,
                "gotCookie": false, "field": field as Any, "keys": keys, "tried": tried, "message": message,
            ]
            lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": false, "reason": reason,
                           "code": code as Any, "tried": tried, "gotCookie": false, "field": field as Any, "cookieKeys": keys]
            return out
        }

        let snap = session.snapshot()
        session.replaceCookies(slim(pairs))
        do {
            if let v = try await sessionVerify(), let profile = v["profile"] {
                let out: [String: Any] = [
                    "ok": true, "code": code as Any, "gotCookie": true, "field": field as Any,
                    "keys": keys, "tried": tried, "profile": profile,
                ]
                lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": true,
                               "tried": tried, "gotCookie": true, "field": field as Any, "cookieKeys": keys]
                return out
            }
            session.restore(snap)
            let out: [String: Any] = [
                "ok": false, "reason": "invalid", "code": code as Any, "gotCookie": true,
                "field": field as Any, "keys": keys, "tried": tried,
                "message": "拿到了 MUSIC_U，但用它校验没通过（可能已过期）",
            ]
            lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": false, "reason": "invalid",
                           "tried": tried, "gotCookie": true, "field": field as Any, "cookieKeys": keys]
            return out
        } catch {
            session.restore(snap)
            let out: [String: Any] = [
                "ok": false, "reason": "error", "code": code as Any, "gotCookie": true,
                "field": field as Any, "keys": keys, "tried": tried,
                "message": "拿到了 MUSIC_U，但校验时出错了：\(error.localizedDescription)",
            ]
            lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": false, "reason": "error",
                           "tried": tried, "gotCookie": true, "field": field as Any, "cookieKeys": keys]
            return out
        }
    }

    func handleLoginHarvest(_ req: HttpRequest) async -> HttpResponse {
        let key = req.string("key")
        guard !key.isEmpty else {
            return .json(400, ["ok": false, "reason": "no-key", "message": "缺少扫码 key"])
        }
        let out = await runHarvest(key: key)
        if out["ok"] as? Bool == true {
            return .json(200, [
                "ok": true, "profile": out["profile"] as Any,
                "harvest": ["tried": out["tried"] as Any, "gotCookie": true, "field": out["field"] as Any],
                "cookieKeys": out["keys"] as Any,
            ])
        }
        return .json(400, [
            "ok": false, "reason": out["reason"] as Any, "code": out["code"] as Any,
            "message": out["message"] as Any,
            "harvest": ["tried": out["tried"] as Any, "gotCookie": false, "field": out["field"] as Any],
            "cookieKeys": out["keys"] as Any,
        ])
    }

    // MARK: - session/import（粘贴 cookie 登录）

    func handleSessionImport(_ req: HttpRequest) async -> HttpResponse {
        let raw = req.string("cookie").isEmpty ? req.string("value") : req.string("cookie")
        let pairs = parseCookieInput(raw)
        let keys = Array(pairs.keys)
        guard pairs["MUSIC_U"] != nil else {
            return .json(400, [
                "ok": false, "reason": "no-music-u", "keys": keys, "cookieKeys": keys,
                "message": "这段内容里没有 MUSIC_U（F12 → Application → Cookies → music.163.com 里那一项）",
            ])
        }
        let snap = session.snapshot()
        session.replaceCookies(pairs)
        do {
            if let v = try await sessionVerify(), let profile = v["profile"] {
                return .json(200, ["ok": true, "profile": profile, "cookieKeys": keys])
            }
            session.restore(snap)
            return .json(400, [
                "ok": false, "reason": "invalid", "keys": keys, "cookieKeys": keys,
                "message": "这段 cookie 无效或已过期（MUSIC_U 不是当前账号的，或已经登出过）",
            ])
        } catch {
            session.restore(snap)
            return .json(400, [
                "ok": false, "reason": "error", "keys": keys, "cookieKeys": keys,
                "message": "校验登录态失败：\(error.localizedDescription)",
            ])
        }
    }

    // MARK: - sessionVerify（只走自家 weapi；iOS 上没有边车进程）

    /// 有 profile 时返回 { loggedIn: true, profile }，否则 nil；传输失败时抛出。
    func sessionVerify() async throws -> [String: Any]? {
        let r = try await weapiRequest("/w/nuser/account/get", [:])
        if let p = profileOf(dict(r.json, "profile")) {
            return ["loggedIn": true, "profile": p]
        }
        return nil
    }
}
