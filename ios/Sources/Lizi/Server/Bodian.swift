import Foundation
import Compression

/// 波点边车：bodian-music-api@0.1.2（MIT）的 Swift 移植。
/// 上游细节见 /tmp/qishui-bodian-details.md（逐字摘自包内 src/）。
/// 主服务路由与归一化见 specs/sidecars.md §6。
/// 注意：
/// - 每次调用 query 恒带 uid（会话 uid 或 -1）与 token（无会话为空）。
/// - 除注明外目录/曲库调用均未签名；音频两步（checkRight/audioUrl）与登录换凭证已签名。
/// - search_playlists、recent_played 在包里没找到；歌单创建/删除、收藏歌单/专辑的写操作包里没有。
/// - gzip：URLSession 可能已自动解压；这里只在首两字节为 0x1f 0x8b 时才手动解。

struct BodianError: Error {
    /// 库错误码：auth-required / not-playable / region-restricted / invalid-response / network / unavailable。
    let code: String
    let message: String
    let upstreamCode: String?
}

final class BodianService {
    private let session = SessionStore.shared

    // MARK: - 常量（src/http.cjs、src/api.cjs）

    private static let bdBase = "https://bd-api.kuwo.cn"
    private static let bdLyricBase = "https://mlyric.kuwo.cn"
    private static let maxResponseBytes = 8 * 1024 * 1024

    private var deviceCache: String?
    private var qrSessions: [String: Date] = [:]
    private var revision = 0

    /// deviceId：32 位小写 hex（16 字节随机数转 hex），生成一次并持久复用。
    private func deviceId() -> String {
        if let d = deviceCache { return d }
        if let saved = session.sidecarAuth("bodian-device"), let d = saved["deviceId"] as? String,
           d.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil {
            deviceCache = d
            return d
        }
        let d = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        session.saveSidecarAuth("bodian-device", ["deviceId": d, "createdAt": Int(Date().timeIntervalSince1970 * 1000)])
        deviceCache = d
        return d
    }

    private func loadSession() -> [String: Any]? {
        guard let s = session.sidecarAuth("bodian"),
              !scStr(s, "uid").isEmpty, !scStr(s, "token").isEmpty else { return nil }
        return s
    }
    private func saveSession(_ s: [String: Any]) {
        revision += 1
        session.saveSidecarAuth("bodian", s)
    }
    private func clearSession() {
        revision += 1
        session.clearSidecarAuth("bodian")
    }

    // MARK: - 签名与通用请求（src/http.cjs）

    /// signQuery 精确算法：query = URLSearchParams(params).toString()；
    /// seed = "kuwotest" + query 中全部字母数字字符排序拼接；
    /// 有 body 时 seed += md5(body + "kuwotest")；sign = md5(seed + path)；path 仅路径本身，不含 query。
    private static func signQuery(path: String, query: String, body: String) -> String {
        let alnum = query.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let seed = "kuwotest" + String(String.UnicodeScalarView(alnum.sorted()))
        var fullSeed = seed
        if !body.isEmpty { fullSeed += Crypto.md5Hex(body + "kuwotest") }
        return Crypto.md5Hex(fullSeed + path)
    }

    private func desktopHeaders(loggedIn: Bool) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": "Dart/3.3 (dart:io)", "plat": "win", "channel": "W1", "ver": "1.1.7",
            "svrver": "13", "api-ver": "application/json", "brand": "Windows", "net": "wifi",
            "devid": deviceId(), "qimei36": deviceId(),
            "Content-Type": "application/json", "Accept-Encoding": "gzip",
        ]
        if loggedIn, let s = loadSession() {
            h["uid"] = scStr(s, "uid")
            h["token"] = scStr(s, "token")
        }
        return h
    }

    /// call：path 须以 / 开头且不含 ..；query 注入恒带 uid（会话 uid 或 -1）与 token（无会话为空）；
    /// signed 时先加 timestamp（毫秒）再算 sign；GET 也可带 JSON body；
    /// 响应 code 须为 200，否则 407 地域限制、11012 需登录、20018 不可播、其他 invalid-response；
    /// HTTP 401 → auth-required，其余非 2xx → network。
    private func call(path: String, params: [(String, String)] = [], body: [String: Any]? = nil,
                     signed: Bool = false, base: String = bdBase, method: String = "GET") async throws -> [String: Any] {
        guard path.hasPrefix("/"), !path.contains("..") else {
            throw BodianError(code: "invalid-response", message: "非法波点路径", upstreamCode: nil)
        }
        let sess = loadSession()
        var pairs: [(String, String)] = [
            ("uid", sess == nil ? "-1" : scStr(sess!, "uid")),
            ("token", sess == nil ? "" : scStr(sess!, "token")),
        ]
        pairs.append(contentsOf: params)
        let bodyText: String
        if let body = body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                throw BodianError(code: "invalid-response", message: "波点请求体构造失败", upstreamCode: nil)
            }
            bodyText = String(data: data, encoding: .utf8) ?? ""
        } else { bodyText = "" }
        if signed { pairs.append(("timestamp", String(Int(Date().timeIntervalSince1970 * 1000)))) }
        var query = qsFormEncodePairs(pairs)
        if signed {
            let sign = Self.signQuery(path: path, query: query, body: bodyText)
            query += "&sign=\(sign)"
        }
        guard let url = URL(string: "\(base)\(path)?\(query)") else {
            throw BodianError(code: "network", message: "波点请求构造失败", upstreamCode: nil)
        }
        var headers = desktopHeaders(loggedIn: sess != nil)
        if body != nil { headers["Content-Type"] = "application/json" }
        let (rawData, resp) = try await Upstream.fetch(url, headers: headers, timeout: 15,
                                                       method: method,
                                                       body: body == nil ? nil : Data(bodyText.utf8))
        if resp.statusCode == 401 {
            throw BodianError(code: "auth-required", message: "Bodian HTTP 401", upstreamCode: nil)
        }
        guard (200...299).contains(resp.statusCode) else {
            throw BodianError(code: "network", message: "Bodian HTTP \(resp.statusCode)", upstreamCode: nil)
        }
        guard rawData.count <= Self.maxResponseBytes else {
            throw BodianError(code: "network", message: "波点响应超过 8 MiB", upstreamCode: nil)
        }
        let data = Self.bdMaybeGunzip(rawData)
        guard let obj = Upstream.jsonObject(data) else {
            throw BodianError(code: "invalid-response", message: "波点返回无法解析", upstreamCode: nil)
        }
        let code = scInt(obj, "code")
        guard code == 200 else {
            let msg = scStr(obj, "msg").isEmpty ? scStr(obj, "message") : scStr(obj, "msg")
            switch code {
            case 407:
                throw BodianError(code: "region-restricted",
                                  message: msg.isEmpty ? "由于版权保护，该资源仅限中国大陆地区使用" : msg,
                                  upstreamCode: "407")
            case 11012:
                throw BodianError(code: "auth-required", message: msg.isEmpty ? "需要登录波点" : msg, upstreamCode: "11012")
            case 20018:
                throw BodianError(code: "not-playable", message: msg.isEmpty ? "波点歌曲不可播" : msg, upstreamCode: "20018")
            default:
                throw BodianError(code: "invalid-response",
                                  message: "Bodian rejected the request (code \(code))", upstreamCode: String(code))
            }
        }
        return obj
    }

    /// gzip 仅当 Content-Encoding 含 gzip 且首两字节为 0x1f 0x8b 时才解压；
    /// URLSession 通常已自动解压，此时 data 无魔数，直接返回。
    private static func bdMaybeGunzip(_ data: Data) -> Data {
        guard data.count > 2, data[0] == 0x1f, data[1] == 0x8b else { return data }
        return bdGunzip(data) ?? data
    }

    private static func bdGunzip(_ data: Data) -> Data? {
        // 解析 gzip 头：10 字节固定头 + 可选扩展/文件名/注释/校验。
        var pos = 10
        guard data.count >= 18 else { return nil }
        let flags = data[3]
        if flags & 0x04 != 0 {
            guard pos + 2 <= data.count else { return nil }
            let xlen = Int(data[pos]) | (Int(data[pos + 1]) << 8)
            pos += 2 + xlen
        }
        if flags & 0x08 != 0 { while pos < data.count, data[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x10 != 0 { while pos < data.count, data[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x02 != 0 { pos += 2 }
        guard pos + 8 <= data.count else { return nil }
        let deflate = data.subdata(in: pos..<(data.count - 8))
        return bdZlibInflate(deflate)
    }

    /// zlib 解压（COMPRESSION_ZLIB，缓冲翻倍重试），与 Kuwo 的同款实现思路一致。
    private static func bdZlibInflate(_ data: Data) -> Data? {
        var capacity = max(data.count * 4, 65536)
        for _ in 0..<6 {
            var out = Data(count: capacity)
            let decoded = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                                              src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if decoded > 0 { out.count = decoded; return out }
            capacity *= 2
        }
        return nil
    }

    private func requireSession() throws -> [String: Any] {
        guard let s = loadSession() else {
            throw BodianError(code: "auth-required", message: "先在卡片上扫码登录波点", upstreamCode: nil)
        }
        return s
    }

    // MARK: - 扫码登录（src/auth.cjs）

    /// login_qr_key：GET /api/ucenter/login/qrCode（signed + 匿名，无其他参数）；
    /// data.qrCode 本身就是 key；内存 5 分钟、同时最多 5 个待扫。
    private func loginQrKey() async throws -> [String: Any] {
        let obj = try await call(path: "/api/ucenter/login/qrCode", signed: true)
        guard let data = obj["data"] as? [String: Any], let key = data["qrCode"] as? String, !key.isEmpty else {
            throw BodianError(code: "invalid-response", message: "波点二维码返回缺 qrCode", upstreamCode: nil)
        }
        if qrSessions.count >= 5, let oldest = qrSessions.min(by: { $0.value < $1.value }) {
            qrSessions.removeValue(forKey: oldest.key)
        }
        qrSessions[key] = Date().addingTimeInterval(300)
        return ["key": key]
    }

    /// login_qr_create：二维码内容为波点登录页地址，用 scQRCodeDataURL 生成。
    /// 前端（app.js 两处取码流程）只读 c.qrimg，必须同时给 qrimg 和 imageUrl，只给 imageUrl
    /// 时前端判 `!c.qrimg` 直接抛「二维码生成失败」。
    private func loginQrCreate(key: String) throws -> [String: Any] {
        guard let exp = qrSessions[key], Date() < exp else {
            throw BodianError(code: "auth-required", message: "二维码已过期，请重新获取", upstreamCode: nil)
        }
        let content = "https://bodian-oia.kuwo.cn/bodian/download.html?pageName=login_pc&pt=3&id=\(key)"
        let img = scQRCodeDataURL(content)
        return ["qrimg": img, "imageUrl": img]
    }

    /// login_qr_check：GET /api/ucenter/login/qrCodeStatus（qrCode={key}）；
    /// status 1=waiting、2=expired、3→POST /api/ucenter/users/login {authType:10, qrCode}；
    /// 上游 11027 视为 scanned；成功时校验身份（全部非空 id 候选相等且匹配 /^[1-9]\d{0,19}$/，token 非空），
    /// 保存会话并清空全部 QR 会话。
    private func loginQrCheck(key: String) async throws -> [String: Any] {
        guard let exp = qrSessions[key] else {
            return ["status": "expired", "code": 800, "message": "二维码已过期"]
        }
        guard Date() < exp else {
            qrSessions.removeValue(forKey: key)
            return ["status": "expired", "code": 800, "message": "二维码已过期"]
        }
        let obj = try await call(path: "/api/ucenter/login/qrCodeStatus", params: [("qrCode", key)], signed: true)
        guard let data = obj["data"] as? [String: Any] else {
            throw BodianError(code: "invalid-response", message: "波点扫码状态返回缺 data", upstreamCode: nil)
        }
        let status = scInt(data, "status")
        switch status {
        case 1:
            return ["status": "waiting", "code": 801, "message": "等待扫码"]
        case 2:
            qrSessions.removeValue(forKey: key)
            return ["status": "expired", "code": 800, "message": "二维码已过期"]
        case 3:
            do {
                let loginObj = try await call(path: "/api/ucenter/users/login",
                                              body: ["authType": 10, "qrCode": key], signed: true)
                guard let login = loginObj["data"] as? [String: Any] else {
                    throw BodianError(code: "invalid-response", message: "波点登录返回缺 data", upstreamCode: nil)
                }
                let user = try Self.bdPublicUser(from: login)
                saveSession(["uid": user["id"] ?? "", "token": scStr(login, "token"), "user": user])
                qrSessions.removeAll()
                return ["status": "confirmed", "code": 803, "message": "登录成功"]
            } catch let e as BodianError {
                if e.upstreamCode == "11027" {
                    return ["status": "scanned", "code": 802, "message": "已扫码，等待确认"]
                }
                throw e
            }
        default:
            throw BodianError(code: "invalid-response", message: "Unrecognized Bodian QR status", upstreamCode: nil)
        }
    }

    /// loginIdentity 候选 id 来源：login.id、login.uid、login.userInfo.id、login.userInfo.uid、
    /// login.user.id、login.user.uid；全部非空值必须相等且须匹配 /^[1-9]\d{0,19}$/；token 须非空。
    private static func bdPublicUser(from login: [String: Any]) throws -> [String: Any] {
        let userInfo = (login["userInfo"] as? [String: Any]) ?? [:]
        let user = (login["user"] as? [String: Any]) ?? [:]
        var candidates: [String] = []
        for v in [scStr(login, "id"), scStr(login, "uid"), scStr(userInfo, "id"), scStr(userInfo, "uid"),
                  scStr(user, "id"), scStr(user, "uid")] where !v.isEmpty { candidates.append(v) }
        guard let first = candidates.first, candidates.allSatisfy({ $0 == first }),
              first.range(of: #"^[1-9]\d{0,19}$"#, options: .regularExpression) != nil else {
            throw BodianError(code: "invalid-response", message: "波点登录身份不一致", upstreamCode: nil)
        }
        guard let token = login["token"] as? String, !token.isEmpty else {
            throw BodianError(code: "invalid-response", message: "波点登录返回缺 token", upstreamCode: nil)
        }
        let nickname = scStr(user, "nickname").isEmpty ? scStr(userInfo, "nickname") : scStr(user, "nickname")
        let avatar = scStr(user, "headImg").isEmpty ? (scStr(user, "avatarUrl").isEmpty ? scStr(userInfo, "avatarUrl") : scStr(user, "avatarUrl")) : scStr(user, "headImg")
        return ["id": first, "nickname": nickname, "avatarUrl": avatar]
    }

    /// login_status 为本地：无会话返回 null；有会话校验 session.user?.id === session.uid，
    /// 不一致清会话并抛 auth-required；GET users/login 不是可用的校验端点。
    private func loginStatus() throws -> [String: Any]? {
        guard let s = loadSession() else { return nil }
        let user = (s["user"] as? [String: Any]) ?? [:]
        guard scStr(user, "id") == scStr(s, "uid") else {
            clearSession()
            throw BodianError(code: "auth-required", message: "波点会话不一致", upstreamCode: nil)
        }
        return user
    }

    // MARK: - 分页与目录 op（src/catalog.cjs）

    private static func bdPagination(limit: Int, offset: Int, firstPage: Int) -> (pn: Int, rn: Int) {
        (max(0, offset / limit) + firstPage, limit)
    }

    /// pageData（catalog.cjs）：items = raw.slice(offset % limit)；
    /// pageEnd = (floor(offset/limit)+1)*limit；
    /// hasMore = raw.length > 0 && (total 已知 ? pageEnd < total : raw.length === limit)；
    /// nextOffset = hasMore ? pageEnd : max(offset + items.length, 已知 total ? min(pageEnd, total) : offset + items.length)。
    private static func bdPageData(_ data: [String: Any], limit: Int, offset: Int, field: String) -> [String: Any] {
        guard let raw = data[field] as? [[String: Any]] else { return data }
        let items = Array(raw.dropFirst(offset % limit))
        let pageEnd = (offset / limit + 1) * limit
        var knownTotal = false
        var total = 0
        if let v = data["total"] {
            if let n = v as? NSNumber { total = n.intValue; knownTotal = total >= 0 }
            else if let s = v as? String, let n = Int(s) { total = n; knownTotal = n >= 0 }
        }
        let hasMore = !raw.isEmpty && (knownTotal ? pageEnd < total : raw.count == limit)
        let nextOffset = hasMore ? pageEnd : max(offset + items.count, knownTotal ? min(pageEnd, total) : offset + items.count)
        var out = data
        out[field] = items
        out["bodianPagination"] = ["nextOffset": nextOffset, "hasMore": hasMore]
        return out
    }

    private func dataOf(path: String, params: [(String, String)] = [], body: [String: Any]? = nil,
                        signed: Bool = false, method: String = "GET") async throws -> [String: Any] {
        let obj = try await call(path: path, params: params, body: body, signed: signed, method: method)
        return (obj["data"] as? [String: Any]) ?? [:]
    }

    private func searchOp(query: String, limit: Int, offset: Int) async throws -> [String: Any] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, query.count <= 500 else {
            throw BodianError(code: "invalid-response", message: "Invalid Bodian search query", upstreamCode: nil)
        }
        let (pn, rn) = Self.bdPagination(limit: limit, offset: offset, firstPage: 0)
        let data = try await dataOf(path: "/api/search/music/list",
                                    params: [("keyword", query.trimmingCharacters(in: .whitespaces)),
                                             ("correct", "1"), ("pn", String(pn)), ("rn", String(rn))])
        return Self.bdPageData(data, limit: limit, offset: offset, field: "resultList")
    }

    private func playlistTracksOp(id: String, source: Int?, limit: Int, offset: Int) async throws -> [String: Any] {
        let (pn, rn) = Self.bdPagination(limit: limit, offset: offset, firstPage: 1)
        var params: [(String, String)] = [("pn", String(pn)), ("rn", String(rn))]
        if let s = source { params.insert(("source", String(s)), at: 0) }
        let data = try await dataOf(path: "/api/service/playlist/\(id)/musicList", params: params)
        // 空歌单上游只回分页对象（没有 list 数组），这里统一成 []。
        var page = data
        if page["list"] == nil { page["list"] = [] }
        return Self.bdPageData(page, limit: limit, offset: offset, field: "list")
    }

    private func pageOp(path: String, params: [(String, String)], field: String,
                        limit: Int, offset: Int, firstPage: Int) async throws -> [String: Any] {
        let (pn, rn) = Self.bdPagination(limit: limit, offset: offset, firstPage: firstPage)
        var full = params
        full.append(("pn", String(pn)))
        full.append(("rn", String(rn)))
        let data = try await dataOf(path: path, params: full)
        return Self.bdPageData(data, limit: limit, offset: offset, field: field)
    }

    private func recommendationsOp() async throws -> [String: Any] {
        let data = try await dataOf(path: "/api/service/finds/playlist")
        let lists = (data["lists"] as? [[String: Any]]) ?? []
        var playlists: [[String: Any]] = []
        for group in lists {
            for key in ["playLists", "list"] {
                if let rows = group[key] as? [[String: Any]] { playlists.append(contentsOf: rows) }
            }
        }
        return ["lists": lists, "playlists": playlists]
    }

    private func aiPlaylistOp(index: Int) async throws -> [String: Any] {
        let data = try await dataOf(path: "/api/service/home/aiPlaylistDetail",
                                    params: [("index", String(index))])
        return ["title": scStr(data, "title").isEmpty ? "潮趣日推" : scStr(data, "title"),
                "subTitle": scStr(data, "subTitle"),
                "tracks": (data["musicList"] as? [[String: Any]]) ?? []]
    }

    private func personalFmOp() async throws -> [String: Any] {
        let data = try await dataOf(path: "/api/service/music/recommendList")
        return ["tracks": (data["musicList"] as? [[String: Any]]) ?? []]
    }

    private func artistSongsOp(id: String, limit: Int, offset: Int) async throws -> [String: Any] {
        try await pageOp(path: "/api/service/artist/music/\(id)", params: [],
                         field: "resultList", limit: limit, offset: offset, firstPage: 0)
    }

    // MARK: - 音频（src/playback.cjs）

    private static func bdValidateAudioURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https",
              url.user == nil, url.password == nil else { return false }
        return true
    }

    /// audio：① checkRight（signed GET 带 JSON body，query 与 body 均为 {musicId, freeSign}）；
    /// ② audioUrl（signed GET 带 JSON body，body {devId, musicId, format, br, freeSign}，
    /// query 为 body 展开后再以字符串 musicId 覆盖）。
    /// 档位：standard=mp3/128kmp3、high=mp3/320kmp3、lossless=flac/2000kflac，hires 归一为 lossless，
    /// 未传默认 high，其他值抛 'Unsupported Bodian audio quality'。
    private func audioOp(id: String, quality req: String, freeSign: String) async throws -> [String: Any] {
        let map: [String: (format: String, br: String)] = ["standard": ("mp3", "128kmp3"),
                                                           "high": ("mp3", "320kmp3"),
                                                           "lossless": ("flac", "2000kflac")]
        let q: String
        if req == "hires" { q = "lossless" }
        else if map[req] != nil { q = req }
        else if req.isEmpty { q = "high" }
        else { throw BodianError(code: "invalid-response", message: "Unsupported Bodian audio quality", upstreamCode: nil) }
        let (format, br) = map[q]!
        let numericId = Int(id) ?? 0
        let checkData = try await dataOf(path: "/api/play/music/v2/checkRight",
                                         params: [("musicId", id), ("freeSign", freeSign)],
                                         body: ["musicId": numericId, "freeSign": freeSign], signed: true)
        if checkData["status"] == nil {
            let loggedIn = loadSession() != nil
            throw BodianError(code: loggedIn ? "not-playable" : "auth-required",
                              message: "Bodian playback rights are unavailable", upstreamCode: nil)
        }
        let st = scInt(checkData, "status")
        if st == 3 {
            guard let preview = checkData["preview"] as? [String: Any],
                  let start = preview["start"] as? NSNumber, let end = preview["end"] as? NSNumber,
                  let url = (preview["https"] as? String) ?? (preview["url"] as? String), !url.isEmpty,
                  Self.bdValidateAudioURL(url) else {
                throw BodianError(code: "not-playable", message: "波点试听信息缺失", upstreamCode: nil)
            }
            return ["url": url, "quality": "standard",
                    "fetchedAt": Int(Date().timeIntervalSince1970 * 1000),
                    "preview": ["startTime": start, "endTime": end]]
        }
        if st == 7 {
            let loggedIn = loadSession() != nil
            throw BodianError(code: loggedIn ? "not-playable" : "auth-required",
                              message: "Bodian requires additional playback rights", upstreamCode: nil)
        }
        let audioData = try await dataOf(path: "/api/play/music/v2/audioUrl",
                                         params: [("devId", deviceId()), ("musicId", id), ("format", format),
                                                  ("br", br), ("freeSign", freeSign)],
                                         body: ["devId": deviceId(), "musicId": numericId,
                                                "format": format, "br": br, "freeSign": freeSign], signed: true)
        guard let url = (audioData["audioHttpsUrl"] as? String) ?? (audioData["audioUrl"] as? String),
              !url.isEmpty, Self.bdValidateAudioURL(url) else {
            throw BodianError(code: "not-playable", message: "波点音频地址无效", upstreamCode: nil)
        }
        return ["url": url, "quality": q, "fetchedAt": Int(Date().timeIntervalSince1970 * 1000)]
    }

    /// 边车 /audio 失败回 HTTP 200 的空地址体；成功回 {url, quality, preview, previewRange}。
    private func audioResult(id: String, quality: String, freeSign: String) async -> [String: Any] {
        do {
            let r = try await audioOp(id: id, quality: quality, freeSign: freeSign)
            return ["url": scStr(r, "url"), "quality": scStr(r, "quality"),
                    "preview": r["preview"] != nil,
                    "previewRange": r["preview"] ?? NSNull()]
        } catch let e as BodianError {
            return ["url": "", "reason": e.code, "region": e.code == "region-restricted", "error": e.message]
        } catch {
            return ["url": "", "reason": "network", "region": false, "error": error.localizedDescription]
        }
    }

    // MARK: - 歌词（src/playback.cjs 的 decodeLyrics）

    /// lyrics：GET mlyric /mobi.s?f=bodian&q=base64(...)&uid=&token=（未签名）；
    /// q 明文 `type=lyric&req=2&lrcx=1&rid={id}&songname=&artist=&corp=kuwo&fromchannel=bodian`；
    /// 响应 result.data.content 先 base64 解码再 decodeLyrics。
    private func lyricsOp(id: String) async throws -> (mainText: String, wordByWordText: String?) {
        let plain = "type=lyric&req=2&lrcx=1&rid=\(id)&songname=&artist=&corp=kuwo&fromchannel=bodian"
        let q = Data(plain.utf8).base64EncodedString()
        let sess = loadSession()
        let obj = try await call(path: "/mobi.s",
                                 params: [("f", "bodian"), ("q", q),
                                          ("uid", sess == nil ? "-1" : scStr(sess!, "uid")),
                                          ("token", sess == nil ? "" : scStr(sess!, "token"))],
                                 base: Self.bdLyricBase)
        guard let content = ((obj["result"] as? [String: Any])?["data"] as? [String: Any])?["content"] as? String,
              let decoded = Data(base64Encoded: content),
              let text = String(data: decoded, encoding: .utf8) else {
            throw BodianError(code: "invalid-response", message: "波点歌词返回缺 content", upstreamCode: nil)
        }
        return Self.bdDecodeLyrics(text)
    }

    /// decodeLyrics：mainText 去全部 `<-?\d+,-?\d+>` 与全部 `[kuwo:…]` 标签；
    /// wordByWordText 仅当含逐字时间戳时为 decodeBodianWordTiming，否则 null。
    private static func bdDecodeLyrics(_ content: String) -> (mainText: String, wordByWordText: String?) {
        let tagRegex = try! NSRegularExpression(pattern: #"<-?\d+,-?\d+>|\[kuwo:[^\]]*\]"#)
        let mainText = tagRegex.stringByReplacingMatches(in: content,
                                                         range: NSRange(content.startIndex..., in: content),
                                                         withTemplate: "")
        let hasWordTiming = content.range(of: #"<-?\d+,-?\d+>"#, options: .regularExpression) != nil
        guard hasWordTiming else { return (mainText, nil) }
        return (mainText, bdWordTiming(content))
    }

    /// decodeBodianWordTiming：取 `[kuwo:([0-7]+)]` 第一组八进制解析 factors，无标签时 factors=11；
    /// startFactor = trunc(factors/10)，durationFactor = factors%10，任一为 0 返回 null；
    /// 先删全部 `[kuwo:…]`，再对每个 `<a,b>` 替换为 AWLRC 逐字标签 `<start,duration>`：
    /// start = trunc(|(a+b)/(2*startFactor)|)，duration = trunc(|(a-b)/(2*durationFactor)|)。
    private static func bdWordTiming(_ content: String) -> String? {
        var factors = 11
        if let m = try! NSRegularExpression(pattern: #"\[kuwo:([0-7]+)\]"#)
            .firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let r = Range(m.range(at: 1), in: content) {
            factors = Int(String(content[r]), radix: 8) ?? 11
        }
        let startFactor = factors / 10
        let durationFactor = factors % 10
        guard startFactor != 0, durationFactor != 0 else { return nil }
        let kuwoRegex = try! NSRegularExpression(pattern: #"\[kuwo:[^\]]*\]"#)
        let stripped = kuwoRegex.stringByReplacingMatches(in: content,
                                                          range: NSRange(content.startIndex..., in: content),
                                                          withTemplate: "")
        let abRegex = try! NSRegularExpression(pattern: #"<(-?\d+),(-?\d+)>"#)
        var result = ""
        var lastEnd = stripped.startIndex
        for m in abRegex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
            guard let r = Range(m.range, in: stripped),
                  let aR = Range(m.range(at: 1), in: stripped),
                  let bR = Range(m.range(at: 2), in: stripped),
                  let a = Int(stripped[aR]), let b = Int(stripped[bR]) else { continue }
            let start = abs((a + b) / (2 * startFactor))
            let duration = abs((a - b) / (2 * durationFactor))
            result += stripped[lastEnd..<r.lowerBound]
            result += "<\(start),\(duration)>"
            lastEnd = r.upperBound
        }
        result += stripped[lastEnd...]
        return result
    }

    // MARK: - 账号库与写操作（src/library.cjs、src/mutations.cjs）

    private func paramsForUser() throws -> (uid: String, params: [(String, String)]) {
        let sess = try requireSession()
        let uid = scStr(sess, "uid")
        return (uid, [("userId", uid), ("fromUid", uid)])
    }

    /// collectionPage（library.cjs）：空数组/空对象回 {[field]: [], bodianPagination}；
    /// 无 playLists 数组抛错；先 pageData 再按 (Number(sourceType) === 6) === albums 过滤；
    /// 上游 total 统计两类之和，不能当过滤后总数。
    private static func bdCollectionPage(_ data: [String: Any], limit: Int, offset: Int, albums: Bool) throws -> [String: Any] {
        let field = albums ? "albumList" : "playLists"
        if (data.isEmpty) {
            return [field: [], "bodianPagination": ["nextOffset": offset, "hasMore": false]]
        }
        guard data["playLists"] is [[String: Any]] else {
            throw BodianError(code: "invalid-response", message: "Bodian collected list is missing", upstreamCode: nil)
        }
        let page = bdPageData(data, limit: limit, offset: offset, field: "playLists")
        let rows = ((page["playLists"] as? [[String: Any]]) ?? []).filter {
            (scInt($0, "sourceType") == 6) == albums
        }
        return [field: rows, "bodianPagination": page["bodianPagination"] ?? [:]]
    }

    private func collectPage(offset: Int, limit: Int) async throws -> [String: Any] {
        let (_, userParams) = try paramsForUser()
        let (pn, rn) = Self.bdPagination(limit: limit, offset: offset, firstPage: 1)
        var params = userParams
        params.append(("pn", String(pn)))
        params.append(("rn", String(rn)))
        return try await dataOf(path: "/api/service/collect/4/list", params: params)
    }

    private func userPlaylistsOp(limit: Int, offset: Int) async throws -> [String: Any] {
        let (_, userParams) = try paramsForUser()
        async let ownedData = dataOf(path: "/api/service/playlist/userCreate", params: userParams)
        async let likedData = dataOf(path: "/api/service/playlist/fond", params: userParams)
        let collectedData = try await collectPage(offset: offset, limit: limit)
        let (owned, liked) = try await (ownedData, likedData)
        let collected = try Self.bdCollectionPage(collectedData, limit: limit, offset: offset, albums: false)
        return ["owned": owned, "liked": liked, "collected": collected]
    }

    private func likedSongsOp(limit: Int, offset: Int) async throws -> [String: Any] {
        let (_, userParams) = try paramsForUser()
        let fond = try await dataOf(path: "/api/service/playlist/fond", params: userParams)
        guard let likedId = fond["id"], String(describing: likedId) != "" else {
            return ["list": [], "total": 0]
        }
        return try await pageOp(path: "/api/service/playlist/\(likedId)/musicList",
                                params: [("source", "5")], field: "list",
                                limit: limit, offset: offset, firstPage: 1)
    }

    private static func bdRows(_ v: Any?) -> [[String: Any]] {
        for key in ["playLists", "list", "info", "data", "result", "rows"] {
            if let d = v as? [String: Any] {
                if let rows = d[key] as? [[String: Any]] { return rows }
                if let inner = d["data"] as? [String: Any], let rows = inner[key] as? [[String: Any]] { return rows }
            }
        }
        if let rows = v as? [[String: Any]] { return rows }
        return []
    }

    private func bdUpdatePlaylist(playListId: Int, musicIds: [Int], remove: Bool) async throws -> [String: Any] {
        let sess = try requireSession()
        let startRevision = revision
        let uid = scStr(sess, "uid")
        var isOwned = false
        let owned = try await dataOf(path: "/api/service/playlist/userCreate",
                                     params: [("userId", uid), ("fromUid", uid)])
        if let lists = owned["playLists"] as? [[String: Any]] {
            isOwned = lists.contains { String(describing: $0["id"] ?? "") == String(playListId) }
        }
        if !isOwned {
            let fond = try await dataOf(path: "/api/service/playlist/fond",
                                        params: [("userId", uid), ("fromUid", uid)])
            if let likedId = fond["id"] { isOwned = String(describing: likedId) == String(playListId) }
        }
        guard isOwned else {
            throw BodianError(code: "not-playable", message: "Bodian playlist is not owned by the current account", upstreamCode: nil)
        }
        guard revision == startRevision else {
            throw BodianError(code: "auth-required", message: "波点会话已变化", upstreamCode: nil)
        }
        let path = remove ? "/api/service/playlist/music/delete" : "/api/service/playlist/music"
        let obj = try await call(path: path, body: ["playListId": playListId, "musicIdList": musicIds],
                                 signed: true, method: "POST")
        return (obj["data"] as? [String: Any]) ?? [:]
    }

    private func bdParseTrackIds(_ raw: String) throws -> [Int] {
        guard raw.count <= 2200 else {
            throw BodianError(code: "invalid-response", message: "trackIds 过长", upstreamCode: nil)
        }
        var out: [Int] = []
        for part in raw.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard let n = Int(t), n > 0, n <= 9_007_199_254_740_991, !out.contains(n) else {
                throw BodianError(code: "invalid-response", message: "无效的 trackId：\(t)", upstreamCode: nil)
            }
            out.append(n)
        }
        guard (1...100).contains(out.count) else {
            throw BodianError(code: "invalid-response", message: "trackIds 须为 1–100 条", upstreamCode: nil)
        }
        return out
    }

    // MARK: - 归一化（spec §6）

    private static func bodianTrack(_ it: [String: Any]) -> [String: Any] {
        let artists: [String]
        if let a = it["artist"] as? String, !a.isEmpty { artists = [a] }
        else {
            let names = ((it["artists"] as? [[String: Any]]) ?? []).compactMap { scStr($0, "name") }
            artists = names.isEmpty ? ["未知歌手"] : names
        }
        let artistIds = (it["artistId"] as? NSNumber).map { [String($0.intValue)] } ?? []
        return ["id": scStr(it, "id").isEmpty ? scStr(it, "musicRid") : scStr(it, "id"),
                "source": "bodian",
                "name": scStr(it, "name").isEmpty ? (scStr(it, "songName").isEmpty ? scStr(it, "FSONGNAME") : scStr(it, "songName")) : scStr(it, "name"),
                "artists": artists, "artistIds": artistIds,
                "album": scStr(it, "album"), "albumId": scStr(it, "albumId"),
                "cover": scStr(it, "albumPic").isEmpty ? scStr(it, "albumPic120") : scStr(it, "albumPic"),
                "duration": scInt(it, "duration") * 1000,
                "fee": (scInt((it["payInfo"] as? [String: Any]) ?? [:], "payType") > 0) ? 1 : 0]
    }

    private static func bodianPlaylist(_ it: [String: Any]) -> [String: Any] {
        ["id": scStr(it, "id").isEmpty ? (scStr(it, "playlistId").isEmpty ? scStr(it, "fid") : scStr(it, "playlistId")) : scStr(it, "id"),
         "source": "bodian",
         "name": scStr(it, "name").isEmpty ? (scStr(it, "title").isEmpty ? (scStr(it, "playlistName").isEmpty ? "未命名歌单" : scStr(it, "playlistName")) : scStr(it, "title")) : scStr(it, "name"),
         "cover": scStr(it, "pic").isEmpty ? (scStr(it, "cover").isEmpty ? (scStr(it, "img").isEmpty ? scStr(it, "coverUrl") : scStr(it, "img")) : scStr(it, "cover")) : scStr(it, "pic"),
         "trackCount": scInt(it, "musicCount") != 0 ? scInt(it, "musicCount") : (scInt(it, "songCount") != 0 ? scInt(it, "songCount") : (scInt(it, "total") != 0 ? scInt(it, "total") : (scInt(it, "count") != 0 ? scInt(it, "count") : scInt(it, "songNum")))),
         "playCount": scInt(it, "playNum") != 0 ? scInt(it, "playNum") : (scInt(it, "play_count") != 0 ? scInt(it, "play_count") : scInt(it, "playCount")),
         "creator": ["nickname": scStr(it, "creatorName").isEmpty ? (scStr(it, "nickname").isEmpty ? scStr(it, "userName") : scStr(it, "nickname")) : scStr(it, "creatorName")],
         "sourceType": scInt(it, "sourceType")]
    }

    private static func bodianUserAlbum(_ it: [String: Any]) -> [String: Any] {
        let artistName = scStr(it, "artist").isEmpty
            ? (scStr(it, "artistName").isEmpty
                ? (scStr(it, "singer").isEmpty
                    ? (scStr(it, "singerName").isEmpty
                        ? (scStr(it, "creatorName").isEmpty ? (scStr(it, "nickname").isEmpty ? "未知歌手" : scStr(it, "nickname")) : scStr(it, "creatorName"))
                        : scStr(it, "singerName"))
                    : scStr(it, "singer"))
                : scStr(it, "artistName"))
            : scStr(it, "artist")
        return ["id": scStr(it, "id").isEmpty ? (scStr(it, "albumId").isEmpty ? (scStr(it, "albumIdStr").isEmpty ? (scStr(it, "rid").isEmpty ? scStr(it, "musicRid") : scStr(it, "rid")) : scStr(it, "albumIdStr")) : scStr(it, "albumId")) : scStr(it, "id"),
                "name": scStr(it, "name").isEmpty ? (scStr(it, "title").isEmpty ? (scStr(it, "albumName").isEmpty ? (scStr(it, "album_name").isEmpty ? "未知专辑" : scStr(it, "album_name")) : scStr(it, "albumName")) : scStr(it, "title")) : scStr(it, "name"),
                "artists": [["name": artistName]],
                "cover": scStr(it, "pic").isEmpty ? (scStr(it, "cover").isEmpty ? (scStr(it, "img").isEmpty ? (scStr(it, "coverUrl").isEmpty ? (scStr(it, "albumPic").isEmpty ? scStr(it, "albumPic120") : scStr(it, "albumPic")) : scStr(it, "coverUrl")) : scStr(it, "img")) : scStr(it, "cover")) : scStr(it, "pic"),
                "publishTime": scInt(it, "publishTime") != 0 ? scInt(it, "publishTime") : (scInt(it, "pubTime") != 0 ? scInt(it, "pubTime") : (scInt(it, "pubtime") != 0 ? scInt(it, "pubtime") : scInt(it, "releaseTime"))),
                "trackCount": scInt(it, "musicCount") != 0 ? scInt(it, "musicCount") : (scInt(it, "songCount") != 0 ? scInt(it, "songCount") : (scInt(it, "total") != 0 ? scInt(it, "total") : (scInt(it, "count") != 0 ? scInt(it, "count") : scInt(it, "songNum"))))]
    }

    // MARK: - 路由分发（主服务形状，见 specs/sidecars.md §6 表右列）

    private static func bdHTTPCode(_ e: BodianError) -> Int {
        switch e.code {
        case "auth-required": return 401
        case "region-restricted": return 451
        case "not-playable": return 403
        case "invalid-response": return 400
        default: return 502
        }
    }

    private func bdFail(_ e: BodianError, empty: [String: Any] = [:]) -> HttpResponse {
        let code = Self.bdHTTPCode(e)
        var body: [String: Any] = ["code": code, "source": "bodian", "error": e.message]
        for (k, v) in empty { body[k] = v }
        return .json(code, body)
    }

    private func bdAuthFail(_ e: BodianError) -> HttpResponse {
        if e.code == "auth-required" {
            return .json(401, ["code": 401, "source": "bodian", "error": "先在卡片上扫码登录波点音乐"])
        }
        return bdFail(e)
    }

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/bodian/".count))
        do {
            switch part {
            case "", "health":
                return .json(200, ["code": 200, "ok": true, "loggedIn": loadSession() != nil,
                                   "license": "AGPL-3.0", "audio": false,
                                   "audioReason": "仅直链 + 试听；播放只放行中国大陆网络"])
            case "status", "login/status":
                do {
                    if let user = try loginStatus() {
                        return .json(200, ["code": 200, "loggedIn": true, "user": user, "uid": scStr(user, "id")])
                    }
                    return .json(200, ["code": 200, "loggedIn": false])
                } catch let e as BodianError {
                    return .json(Self.bdHTTPCode(e), ["code": Self.bdHTTPCode(e), "loggedIn": false, "error": e.message])
                }
            case "login/qr/key":
                return .json(200, ["code": 200] + (try await loginQrKey()))
            case "login/qr/create":
                let key = req.string("key")
                guard !key.isEmpty else { return .error(400, "缺少 key") }
                return .json(200, ["code": 200] + (try loginQrCreate(key: key)))
            case "login/qr/check":
                let key = req.string("key")
                guard !key.isEmpty else { return .error(400, "缺少 key") }
                return .json(200, ["code": 200] + (try await loginQrCheck(key: key)))
            case "login/qr/cancel":
                if !req.string("key").isEmpty { qrSessions.removeValue(forKey: req.string("key")) }
                return .json(200, ["code": 200, "ok": true])
            case "logout":
                clearSession()
                qrSessions.removeAll()
                return .json(200, ["code": 200, "loggedIn": false])
            case "search":
                let q = [req.string("s"), req.string("q"), req.string("keyword")].first(where: { !$0.isEmpty }) ?? ""
                if q.trimmingCharacters(in: .whitespaces).isEmpty {
                    return .json(200, ["code": 200, "source": "bodian", "tracks": [], "songCount": 0])
                }
                let limit = scClamp(req.int("limit", 20), 1, 50)
                let offset = max(0, req.int("offset", 0))
                do {
                    let page = try await searchOp(query: q, limit: limit, offset: offset)
                    let rows = ((page["resultList"] as? [[String: Any]]) ?? []).map { Self.bodianTrack($0) }
                        .filter { !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty }
                    let songCount = scInt(page, "total") != 0 ? scInt(page, "total") : rows.count
                    return .json(200, ["code": 200, "source": "bodian", "tracks": rows, "songCount": songCount])
                } catch let e as BodianError {
                    return bdFail(e, empty: ["tracks": []])
                }
            case "song/url":
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let quality = req.string("quality")
                let q = ["standard", "high", "lossless", "hires"].contains(quality) ? quality : "standard"
                // 边车 freeSign 为 q.freeSign === '1' 的布尔值；这里按原始字符串透传（见上 audioOp 注释）。
                let r = await audioResult(id: req.string("id"), quality: q, freeSign: req.string("freeSign"))
                let url = scStr(r, "url")
                let preview = (r["preview"] as? NSNumber)?.boolValue == true
                let reason: Any
                if !url.isEmpty { reason = preview ? "preview" : NSNull() }
                else if (r["region"] as? NSNumber)?.boolValue == true { reason = "region" }
                else { reason = scStr(r, "reason").isEmpty ? "unavailable" : scStr(r, "reason") }
                let err: Any = url.isEmpty ? scStr(r, "error") : NSNull()
                return .json(200, ["code": 200, "id": req.string("id"), "url": url,
                                   "preview": preview,
                                   "previewRange": r["previewRange"] ?? NSNull(),
                                   "quality": scStr(r, "quality").isEmpty ? q : scStr(r, "quality"),
                                   "reason": reason, "error": err])
            case "lyric":
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                do {
                    let (mainText, wbw) = try await lyricsOp(id: req.string("id"))
                    let yrc = awlrcToYrc(wbw ?? "")
                    return .json(200, ["code": 200, "lyric": mainText, "yrc": yrc, "tlyric": "",
                                       "format": !yrc.isEmpty ? "yrc" : (!mainText.isEmpty ? "lrc" : "none")])
                } catch let e as BodianError {
                    return .json(200, ["code": 200, "lyric": "", "yrc": "", "tlyric": "", "format": "none",
                                       "error": e.message])
                }
            case "playlist/tracks":
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let limit = scClamp(req.int("limit", 50), 1, 100)
                let offset = max(0, req.int("offset", 0))
                let sourceRaw = req.int("source", 0)
                let source = (1...6).contains(sourceRaw) ? sourceRaw : nil
                do {
                    let page = try await playlistTracksOp(id: req.string("id"), source: source,
                                                          limit: limit, offset: offset)
                    let tracks = ((page["list"] as? [[String: Any]]) ?? []).map { Self.bodianTrack($0) }
                        .filter { !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty }
                    let more = ((page["bodianPagination"] as? [String: Any])?["hasMore"] as? NSNumber)?.boolValue == true
                    return .json(200, ["code": 200, "source": "bodian", "tracks": tracks, "more": more])
                } catch let e as BodianError {
                    return bdFail(e, empty: ["tracks": []])
                }
            case "recommendations":
                do {
                    let r = try await recommendationsOp()
                    let lists = ((r["playlists"] as? [[String: Any]]) ?? []).map { Self.bodianPlaylist($0) }
                        .filter { !scStr($0, "id").isEmpty }
                    return .json(200, ["code": 200, "source": "bodian", "playlists": lists])
                } catch let e as BodianError {
                    return bdFail(e, empty: ["playlists": []])
                }
            case "ai/playlist":
                let index = max(0, req.int("index", 0))
                do {
                    let r = try await aiPlaylistOp(index: index)
                    let tracks = ((r["tracks"] as? [[String: Any]]) ?? []).map { Self.bodianTrack($0) }
                        .filter { !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty }
                    return .json(200, ["code": 200, "source": "bodian", "title": scStr(r, "title"),
                                       "subTitle": scStr(r, "subTitle"), "tracks": tracks])
                } catch let e as BodianError {
                    return bdFail(e, empty: ["tracks": []])
                }
            case "personal/fm":
                do {
                    let r = try await personalFmOp()
                    let tracks = ((r["tracks"] as? [[String: Any]]) ?? []).map { Self.bodianTrack($0) }
                        .filter { !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty }
                    return .json(200, ["code": 200, "source": "bodian", "tracks": tracks])
                } catch let e as BodianError {
                    return bdFail(e, empty: ["tracks": []])
                }
            case "user/playlists":
                do {
                    let first = try await userPlaylistsOp(limit: 100, offset: 0)
                    var playlists: [[String: Any]] = []
                    playlists.append(contentsOf: Self.bdRows(first["owned"]).map { Self.bodianPlaylist($0) })
                    if let liked = first["liked"] as? [String: Any], !scStr(liked, "id").isEmpty {
                        playlists.append(Self.bodianPlaylist(liked))
                    }
                    // collected 按 bodianPagination.nextOffset 翻到底，最多 20 页。
                    var collected = (first["collected"] as? [String: Any]) ?? [:]
                    playlists.append(contentsOf: Self.bdRows(collected["playLists"]).map { Self.bodianPlaylist($0) })
                    var pages = 1
                    while pages < 20 {
                        let pag = (collected["bodianPagination"] as? [String: Any]) ?? [:]
                        guard (pag["hasMore"] as? NSNumber)?.boolValue == true,
                              let next = pag["nextOffset"] as? NSNumber, next.intValue > 0 else { break }
                        let data = try await collectPage(offset: next.intValue, limit: 100)
                        let nextCollected = try Self.bdCollectionPage(data, limit: 100, offset: next.intValue, albums: false)
                        let rows = Self.bdRows(nextCollected["playLists"]).map { Self.bodianPlaylist($0) }
                        if rows.isEmpty { break }
                        playlists.append(contentsOf: rows)
                        collected = nextCollected
                        pages += 1
                    }
                    playlists = playlists.filter { !scStr($0, "id").isEmpty }
                    return .json(200, ["code": 200, "source": "bodian", "playlists": playlists])
                } catch let e as BodianError {
                    return bdAuthFail(e)
                }
            case "liked_songs", "liked-songs":
                do {
                    let page = try await likedSongsOp(limit: 100, offset: 0)
                    let tracks = ((page["list"] as? [[String: Any]]) ?? []).map { Self.bodianTrack($0) }
                        .filter { !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty }
                    return .json(200, ["code": 200, "source": "bodian", "tracks": tracks])
                } catch let e as BodianError {
                    return bdAuthFail(e)
                }
            case "playlist/detail":
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let detailSource = (1...6).contains(req.int("source", 4)) ? req.int("source", 4) : 4
                do {
                    let data = try await dataOf(path: "/api/service/playlist/info/\(req.string("id"))",
                                                params: [("source", String(detailSource))])
                    return .json(200, ["code": 200, "source": "bodian",
                                       "playlist": Self.bodianPlaylist(data)])
                } catch let e as BodianError {
                    return .json(Self.bdHTTPCode(e), ["code": Self.bdHTTPCode(e), "source": "bodian",
                                                      "playlist": NSNull(), "error": e.message])
                }
            case "user/albums":
                do {
                    let data = try await collectPage(offset: 0, limit: 50)
                    let page = try Self.bdCollectionPage(data, limit: 50, offset: 0, albums: true)
                    let albums = ((page["albumList"] as? [[String: Any]]) ?? []).map { Self.bodianUserAlbum($0) }
                        .filter { !scStr($0, "id").isEmpty }
                    // 边车目前不把 offset/limit 转给库，永远只给第一页，hasMore 固定 false。
                    return .json(200, ["code": 200, "source": "bodian", "data": albums, "hasMore": false])
                } catch let e as BodianError {
                    return bdAuthFail(e)
                }
            case "artist/songs":
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let offset = max(0, req.int("offset", 0))
                do {
                    let page = try await artistSongsOp(id: req.string("id"), limit: 50, offset: offset)
                    let tracks = ((page["resultList"] as? [[String: Any]]) ?? []).map { Self.bodianTrack($0) }
                        .filter { !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty }
                    return .json(200, ["code": 200, "source": "bodian", "tracks": tracks])
                } catch let e as BodianError {
                    return bdFail(e, empty: ["tracks": []])
                }
            case "playlist/tracks/add", "playlist/tracks/delete":
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                guard let playListId = Int(req.string("id")) else { return .error(400, "无效的歌单 id") }
                do {
                    let ids = try bdParseTrackIds(req.string("trackIds"))
                    let r = try await bdUpdatePlaylist(playListId: playListId, musicIds: ids,
                                                       remove: part == "playlist/tracks/delete")
                    return .json(200, ["code": 200, "ok": true, "data": r])
                } catch let e as BodianError {
                    return bdFail(e)
                }
            case "like/song":
                guard !req.string("id").isEmpty, let musicId = Int(req.string("id")) else {
                    return .error(400, "缺少 id")
                }
                guard let liked = req.params["liked"] as? NSNumber else {
                    return .error(400, "缺少 liked")
                }
                do {
                    let (_, userParams) = try paramsForUser()
                    let fond = try await dataOf(path: "/api/service/playlist/fond", params: userParams)
                    guard let likedIdRaw = fond["id"], let likedId = Int(String(describing: likedIdRaw)) else {
                        return .json(200, ["code": 200, "ok": false, "error": "未找到我喜欢歌单"])
                    }
                    let r = try await bdUpdatePlaylist(playListId: likedId, musicIds: [musicId],
                                                       remove: !liked.boolValue)
                    return .json(200, ["code": 200, "ok": true, "data": r])
                } catch let e as BodianError {
                    return bdFail(e)
                }
            default:
                return .json(404, ["code": 404, "error": "unknown bodian api: \(part)"])
            }
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// ["code": 200] + dict 的拼接。
    static func + (lhs: [String: Any], rhs: [String: Any]) -> [String: Any] {
        var out = lhs
        for (k, v) in rhs { out[k] = v }
        return out
    }
}
