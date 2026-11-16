import Foundation

/// QQ 音乐：@yakult-green-tea/qq-music-api@3.3.5 的 Swift 移植。
///
/// 关键实测结论（2026-11-17，本机 Node 探针）：
/// - musicu 接受空 QIMEI：GetSession 与 CreateQRCode 在 QIMEI/QIMEI36 为空时均回 code 0，
///   CreateQRCode 直接给了真实 qrcodeID + PNG（expiresIn 900）。所以本移植跳过 QIMEI 启动
///  （QIMEI_SECRET 在工具输出里被遮蔽、拿不到；也不需要它）。
/// - 设备身份仍按包内规则合成（MI 6 / MI 6 指纹 / Luhn IMEI / 16 位 androidId / 32 位 openUdid），
///   持久化在 .auth-qq-device.json；会话 uid/sid/vkey 由 GetSession 下发后存入。
/// - 扫码三通道：qq / qqmusic 走 MQTT（wss://mu.y.qq.com/ws/handshake，MQTT 5）；
///   wechat 走 open.weixin.qq.com 的 HTTP 长轮询。ptlogin 通道不在 server.mjs 的
///   QQ_CHANNELS 里，本期不做。
/// - 匿名搜索搜歌送 search_type=7（送 0 会回 2001）；匿名播放走 UCommon CgiGetVkey。
/// - 其余路由按 specs/sidecars.md §1 的主服务形状返回，绝不编假数据。

// MARK: - 常量

private let qqMusicuURL = "https://u.y.qq.com/cgi-bin/musicu.fcg"
private let qqCgiBase = "https://c.y.qq.com"
private let qqUCommonSign = "zzannc1o6o9b4i971602f3554385022046ab796512b7012"
private let qqUA = "QQMusic 14090008(android 10)"
private let qqLiteUA = "okhttp/3.14.9"
private let qqChannels = ["qq", "wechat", "qqmusic"]
private let qqQrTTL: TimeInterval = 180
private let qqQrCooldown: TimeInterval = 15
private let qqQrRateLimitCooldown: TimeInterval = 30
private let qqQrClaim: TimeInterval = 60
private let qqCredentialRejectionCodes: Set<Int> = [1000, 104401, 104400]
private let qqWechatAppId = "wx48db31d50e334801"

/// 上游抛出的业务码（global code / req_0.code / CGI code）。
struct QQUpstreamError: Error {
    let code: Int
    let message: String
}

struct QQAuthError: Error {
    /// 401：凭证被拒或缺失；409：已有扫码进行中；429：冷却中；502：上游/协议失败。
    let code: Int
    let message: String
    let retryAfterMs: Int?
    init(_ code: Int, _ message: String, retryAfterMs: Int? = nil) {
        self.code = code; self.message = message; self.retryAfterMs = retryAfterMs
    }
}

// MARK: - 小工具

private func qqRandomHex(_ n: Int) -> String {
    (0..<n).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
}

private func qqRandomDigits(_ n: Int) -> String {
    (0..<n).map { _ in String(Int.random(in: 0...9)) }.joined()
}

/// Luhn 校验位（IMEI 标准算法：从右起第二位开始每隔一位 ×2，>9 减 9）。
private func qqIMEI() -> String {
    let d14 = (0..<14).map { _ in Int.random(in: 0...9) }
    var sum = 0
    for (i, d) in d14.enumerated() {
        // 0-based 奇数位 = 从右数第偶数位（不含校验位），需要 ×2。
        var v = d
        if i % 2 == 1 {
            v *= 2
            if v > 9 { v -= 9 }
        }
        sum += v
    }
    return d14.map(String.init).joined() + String((10 - (sum % 10)) % 10)
}

private func qqJSONStringEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    return out
}

private let qqGb18030: String.Encoding = {
    // kCFStringEncodingGB_18030_2000 = 0x0632（SDK 头文件值）。
    // Swift 的 CFStringEncodings 未暴露 gb_18030_2000 成员，直接用数值。
    let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
    return String.Encoding(rawValue: cf)
}()

private func qqDecodeText(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? String(data: data, encoding: qqGb18030) ?? ""
}

/// 去 JSONP 包裹（callback(...) / MusicJsonCallback(...)），失败返回原串。
private func qqStripJSONP(_ text: String) -> String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return t }
    let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
    return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func qqParseJSONText(_ text: String) -> Any? {
    if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { return obj }
    let stripped = qqStripJSONP(text)
    if stripped != text, let obj = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) { return obj }
    return nil
}

private func qqJSONData(_ obj: Any) -> Data? {
    try? JSONSerialization.data(withJSONObject: obj)
}

// MARK: - 设备与凭证（持久化在 Application Support/lizi/ 下的 .auth-qq*.json）

actor QQService {
    private let store = SessionStore.shared
    private var device: [String: String] = [:]
    private var deviceLoaded = false
    private var credential: [String: Any]?
    private var credentialLoaded = false
    private var refreshRetryAt: TimeInterval = 0
    private var qrSessions: [String: QQSession] = [:]
    private var nextQrAllowedAt: Date = .distantPast
    private var creatingSession = false
    private var searchCache: [(key: String, at: Date, data: [String: Any])] = []

    // MARK: 设备

    private func loadDevice() -> [String: String] {
        if deviceLoaded { return device }
        deviceLoaded = true
        if let saved = store.sidecarAuth("qq-device") as? [String: String], !saved.isEmpty {
            device = saved
            return device
        }
        device = [
            "androidId": qqRandomHex(16),
            "openUdid": qqRandomHex(32),
            "imei": qqIMEI(),
            "fingerprint": "xiaomi/iarim/sagit:10/eomam.200122.001/\(qqRandomDigits(7)):user/release-keys",
            "procVersion": "Linux 5.4.0-54-generic-\(qqRandomHex(8)) (android-build@google.com)",
            "display": "QMAPI.\(qqRandomDigits(6)).001",
            "sessionUid": "",
            "sessionSid": "",
            "sessionVkey": "",
        ]
        store.saveSidecarAuth("qq-device", device)
        return device
    }

    private func saveDevice() {
        store.saveSidecarAuth("qq-device", device)
    }

    private func credentialMusicId(_ cred: [String: Any]? = nil) -> String {
        let c = cred ?? credential ?? [:]
        for k in ["str_musicid", "musicid"] {
            let v = scStrOrNum(c, k)
            if !v.isEmpty && v != "0" { return v }
        }
        return ""
    }

    private func loadCredential() -> [String: Any]? {
        if credentialLoaded { return credential }
        credentialLoaded = true
        credential = store.sidecarAuth("qq")
        return credential
    }

    private func saveCredential(_ cred: [String: Any]?) {
        credential = cred
        if let cred { store.saveSidecarAuth("qq", cred) } else { store.clearSidecarAuth("qq") }
    }

    private func credentialCookieHeader(_ cred: [String: Any]) -> String {
        let id = credentialMusicId(cred)
        let key = scStr(cred, "musickey")
        return "uin=\(id); qqmusic_uin=\(id); qm_keyst=\(key); qqmusic_key=\(key)"
    }

    // MARK: comm

    /// Android comm（buildAndroidComm）：登录态与匿名态只差 qq/authst/tmeLoginType 三字段。
    private func androidComm(overrides: [String: Any] = [:]) -> [String: Any] {
        let d = loadDevice()
        var c: [String: Any] = [
            "ct": 11, "cv": 14090008, "v": 14090008, "chid": "10003505", "tmeAppID": "qqmusic",
            "QIMEI": "", "QIMEI36": "",
            "OpenUDID": d["openUdid"] ?? "", "udid": d["openUdid"] ?? "", "OpenUDID2": d["openUdid"] ?? "",
            "aid": d["androidId"] ?? "", "os_ver": "10", "phonetype": "MI 6",
            "devicelevel": "29", "newdevicelevel": "29",
            "rom": d["fingerprint"] ?? "",
        ]
        if let uid = d["sessionUid"], !uid.isEmpty { c["uid"] = uid }
        if let sid = d["sessionSid"], !sid.isEmpty { c["sid"] = sid }
        if let cred = loadCredential() {
            c["qq"] = credentialMusicId(cred)
            c["authst"] = scStr(cred, "musickey")
            c["tmeLoginType"] = scInt(cred, "loginType")
        }
        for (k, v) in overrides { c[k] = v }
        return c
    }

    // MARK: musicu 客户端

    /// 核心 musicu 调用：POST {comm, req_0:{module,method,param}}。
    /// 只读请求最多重试 2 次（退避 200*2^attempt ms + 抖动）；global code / req_0.code /
    /// subcode 任一非 0 即抛 QQUpstreamError。
    private func musicu(comm: [String: Any], module: String, method: String, param: [String: Any],
                        headers: [String: String]? = nil, readOnly: Bool = true,
                        timeout: TimeInterval = 25) async throws -> [String: Any] {
        let body: [String: Any] = ["comm": comm, "req_0": ["module": module, "method": method, "param": param]]
        guard let bodyData = qqJSONData(body), let url = URL(string: qqMusicuURL) else {
            throw QQUpstreamError(code: -1, message: "musicu 请求构造失败")
        }
        var lastError: Error = QQUpstreamError(code: -1, message: "musicu 请求失败")
        let attempts = readOnly ? 3 : 1
        for attempt in 0..<attempts {
            if attempt > 0 {
                let backoff = Double(200 * (1 << (attempt - 1))) + Double.random(in: 0...200)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000))
            }
            do {
                var h: [String: String] = ["Content-Type": "application/json"]
                if let headers { for (k, v) in headers { h[k] = v } }
                let (data, resp) = try await Upstream.fetch(url, headers: h, timeout: timeout, method: "POST", body: bodyData)
                guard resp.statusCode == 200 else {
                    if resp.statusCode >= 500 {
                        throw NSError(domain: "LiziUpstream", code: resp.statusCode, userInfo: nil)
                    }
                    throw QQUpstreamError(code: resp.statusCode, message: "musicu HTTP \(resp.statusCode)")
                }
                guard let obj = Upstream.jsonObject(data) else {
                    throw QQUpstreamError(code: -1, message: "musicu 返回无法解析")
                }
                let global = scInt(obj, "code")
                guard global == 0 else {
                    throw QQUpstreamError(code: global, message: "musicu 上游错误 \(global)")
                }
                guard let req0 = obj["req_0"] as? [String: Any] else {
                    throw QQUpstreamError(code: -1, message: "musicu 返回缺 req_0")
                }
                let rc = scInt(req0, "code")
                guard rc == 0 else {
                    throw QQUpstreamError(code: rc, message: "musicu 上游错误 \(rc)")
                }
                if let sub = req0["subcode"] as? NSNumber, sub.intValue != 0 {
                    throw QQUpstreamError(code: sub.intValue, message: "musicu subcode \(sub.intValue)")
                }
                guard let d = req0["data"] as? [String: Any] else {
                    throw QQUpstreamError(code: -1, message: "musicu 返回缺 data")
                }
                return d
            } catch let e as QQUpstreamError {
                lastError = e
                // 业务码错误不重试（只有传输错误才重试）。
                throw e
            } catch {
                lastError = error
                if attempt == attempts - 1 { throw QQUpstreamError(code: -1, message: "musicu 请求失败：\(error.localizedDescription)") }
            }
        }
        throw lastError
    }

    /// 多 req 批量 musicu（song/batch 用）：{comm, req_0, req_1, ...}。
    private func musicuMulti(comm: [String: Any], calls: [(module: String, method: String, param: [String: Any])],
                             headers: [String: String]? = nil) async throws -> [[String: Any]] {
        var body: [String: Any] = ["comm": comm]
        for (i, c) in calls.enumerated() {
            body["req_\(i)"] = ["module": c.module, "method": c.method, "param": c.param]
        }
        guard let bodyData = qqJSONData(body), let url = URL(string: qqMusicuURL) else {
            throw QQUpstreamError(code: -1, message: "musicu 请求构造失败")
        }
        var h: [String: String] = ["Content-Type": "application/json"]
        if let headers { for (k, v) in headers { h[k] = v } }
        let (data, resp) = try await Upstream.fetch(url, headers: h, timeout: 25, method: "POST", body: bodyData)
        guard resp.statusCode == 200, let obj = Upstream.jsonObject(data) else {
            throw QQUpstreamError(code: resp.statusCode, message: "musicu HTTP \(resp.statusCode)")
        }
        guard scInt(obj, "code") == 0 else {
            throw QQUpstreamError(code: scInt(obj, "code"), message: "musicu 上游错误")
        }
        var out: [[String: Any]] = []
        for i in calls.indices {
            guard let req = obj["req_\(i)"] as? [String: Any], scInt(req, "code") == 0,
                  let d = req["data"] as? [String: Any] else {
                out.append([:])
                continue
            }
            out.append(d)
        }
        return out
    }

    /// 登录态 musicu：Android comm + QQMusic UA + 凭证 Cookie。
    private func musicuAuth(module: String, method: String, param: [String: Any],
                           commOverride: [String: Any] = [:], readOnly: Bool = true,
                           timeout: TimeInterval = 25) async throws -> [String: Any] {
        var h: [String: String] = ["User-Agent": qqUA]
        if let cred = loadCredential() { h["Cookie"] = credentialCookieHeader(cred) }
        return try await musicu(comm: androidComm(overrides: commOverride), module: module, method: method,
                                param: param, headers: h, readOnly: readOnly, timeout: timeout)
    }

    /// 匿名 musicu：comm {ct:24, cv:0}（+uin:0），无 UA、无 Cookie。
    private func musicuAnon(module: String, method: String, param: [String: Any],
                            withUin: Bool = false, readOnly: Bool = true) async throws -> [String: Any] {
        var comm: [String: Any] = ["ct": 24, "cv": 0]
        if withUin { comm["uin"] = 0 }
        return try await musicu(comm: comm, module: module, method: method, param: param,
                                headers: [:], readOnly: readOnly)
    }

    // MARK: 旧 CGI 客户端

    /// GET https://c.y.qq.com/<path>：通用参数 + Referer；JSONP / GB18030 容错；code != 0 抛错。
    private func cgi(path: String, params: [String: String], referer: String = "https://c.y.qq.com/",
                     headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> [String: Any] {
        var all: [String: String] = [
            "format": "json", "outCharset": "utf-8", "g_tk": "1124214810",
            "loginUin": "0", "hostUin": "0", "inCharset": "utf8",
            "notice": "0", "platform": "yqq.json", "needNewCode": "0",
        ]
        for (k, v) in params { all[k] = v }
        var comps = URLComponents(string: qqCgiBase + path) ?? URLComponents()
        comps.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else {
            throw QQUpstreamError(code: -1, message: "CGI 请求构造失败")
        }
        let (data, resp) = try await Upstream.fetch(url, headers: ["Referer": referer].merging(headers) { _, new in new }, timeout: timeout)
        guard resp.statusCode == 200 else {
            throw QQUpstreamError(code: resp.statusCode, message: "CGI HTTP \(resp.statusCode)")
        }
        let text = qqDecodeText(data)
        guard let obj = qqParseJSONText(text) as? [String: Any] else {
            throw QQUpstreamError(code: -1, message: "CGI 返回无法解析")
        }
        let code = scInt(obj, "code")
        guard code == 0 else {
            throw QQUpstreamError(code: code, message: "CGI 上游错误 \(code)")
        }
        return obj
    }

    // MARK: UCommon 客户端（匿名取链）

    /// GET musicu.fcg?format=json&sign=<固定>&data=<JSON>。
    private func ucommon(data: [String: Any], timeout: TimeInterval = 25) async throws -> [String: Any] {
        guard let dataJson = qqJSONData(data),
              let dataStr = String(data: dataJson, encoding: .utf8) else {
            throw QQUpstreamError(code: -1, message: "UCommon 请求构造失败")
        }
        var comps = URLComponents(string: qqMusicuURL) ?? URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "sign", value: qqUCommonSign),
            URLQueryItem(name: "data", value: dataStr),
        ]
        guard let url = comps.url else {
            throw QQUpstreamError(code: -1, message: "UCommon 请求构造失败")
        }
        let (respData, resp) = try await Upstream.fetch(
            url,
            headers: ["Referer": "https://y.qq.com/portal/player.html",
                      "Content-Type": "application/x-www-form-urlencoded"],
            timeout: timeout)
        guard resp.statusCode == 200, let obj = Upstream.jsonObject(respData) else {
            throw QQUpstreamError(code: resp.statusCode, message: "UCommon HTTP \(resp.statusCode)")
        }
        guard scInt(obj, "code") == 0 else {
            throw QQUpstreamError(code: scInt(obj, "code"), message: "UCommon 上游错误")
        }
        guard let req0 = obj["req_0"] as? [String: Any], scInt(req0, "code") == 0 else {
            throw QQUpstreamError(code: -1, message: "UCommon 返回缺 req_0")
        }
        guard let d = req0["data"] as? [String: Any] else {
            throw QQUpstreamError(code: -1, message: "UCommon 返回缺 data")
        }
        return d
    }

    // MARK: 单曲详情预查

    /// get_song_detail_yqq：登录走 musicu，匿名走 UCommon。返回 track_info 或 nil。
    private func songDetail(mid: String) async -> [String: Any]? {
        let param: [String: Any] = ["song_type": 0, "song_mid": mid]
        if loadCredential() != nil {
            if let d = try? await musicuAuth(module: "music.pf_song_detail_svr", method: "get_song_detail_yqq", param: param) {
                return d["track_info"] as? [String: Any]
            }
            return nil
        }
        let data: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req_0": ["module": "music.pf_song_detail_svr", "method": "get_song_detail_yqq", "param": param],
        ]
        if let d = try? await ucommon(data: data) {
            return d["track_info"] as? [String: Any]
        }
        return nil
    }

    // MARK: - MQTT 5（扫码登录，wss://mu.y.qq.com/ws/handshake，子协议 mqtt）

    private struct QQSession {
        var key: String
        var channel: String
        var state: String // created/waiting/scanned/exchanging/confirmed/expired/failed
        var createdAt: Date
        var expiresAt: Date
        var qrcodeId: String?
        var imageUrl: String?
        var wxUuid: String?
        var wxLast: Int?
        var wxPollErrors: Int = 0
        var cookies: [String: String] = [:]
        var failureReason: String?
        var retryAfterMs: Int?
        var listenerReady: Bool = false
        var listenerFailed: String?
        var wsTask: URLSessionWebSocketTask?
        var driverTask: Task<Void, Never>?
    }
}

/// MQTT 固定头 + 变长剩余长度 + 载荷。
private func qqMqttPacket(type: UInt8, flags: UInt8, payload: Data) -> Data {
    var out = Data([type << 4 | flags])
    var n = payload.count
    repeat {
        var b = UInt8(n % 128)
        n /= 128
        if n > 0 { b |= 0x80 }
        out.append(b)
    } while n > 0
    out.append(payload)
    return out
}

private func qqMqttUTF8(_ s: String) -> Data {
    let bytes = Data(s.utf8)
    var out = Data([UInt8((bytes.count >> 8) & 0xff), UInt8(bytes.count & 0xff)])
    out.append(bytes)
    return out
}

private func qqMqttVarint(_ n: Int) -> Data {
    var out = Data()
    var v = n
    repeat {
        var b = UInt8(v % 128)
        v /= 128
        if v > 0 { b |= 0x80 }
        out.append(b)
    } while v > 0
    return out
}

/// MQTT 5 属性块：[(属性 id, 已编码值)] → 变长总长度 + 拼接。
private func qqMqttProperties(_ props: [(UInt8, Data)]) -> Data {
    var body = Data()
    for (id, value) in props {
        body.append(id)
        body.append(value)
    }
    return qqMqttVarint(body.count) + body
}

/// CONNECT 包（MQTT 5，Clean Start，KeepAlive 45，authMethod pass，用户属性 5 组）。
private func qqMqttConnect(clientId: String, qrcodeId: String) -> Data {
    var variable = Data()
    variable.append(qqMqttUTF8("MQTT"))
    variable.append(0x05) // 协议级 5
    variable.append(0x02) // Clean Start
    variable.append(contentsOf: [0x00, 0x2D]) // KeepAlive 45
    let props = qqMqttProperties([
        (0x15, qqMqttUTF8("pass")),
        (0x26, qqMqttUTF8("tmeAppID") + qqMqttUTF8("qqmusic")),
        (0x26, qqMqttUTF8("business") + qqMqttUTF8("management")),
        (0x26, qqMqttUTF8("hashTag") + qqMqttUTF8(qrcodeId)),
        (0x26, qqMqttUTF8("clientTag") + qqMqttUTF8("management.user")),
        (0x26, qqMqttUTF8("userID") + qqMqttUTF8(qrcodeId)),
    ])
    variable.append(props)
    variable.append(qqMqttUTF8(clientId))
    return qqMqttPacket(type: 1, flags: 0, payload: variable)
}

/// SUBSCRIBE 包（PacketId 1，authorization=tmelogin，pubsub=unicast）。
private func qqMqttSubscribe(qrcodeId: String) -> Data {
    var variable = Data([0x00, 0x01]) // PacketId 1
    variable.append(qqMqttProperties([
        (0x26, qqMqttUTF8("authorization") + qqMqttUTF8("tmelogin")),
        (0x26, qqMqttUTF8("pubsub") + qqMqttUTF8("unicast")),
    ]))
    variable.append(qqMqttUTF8("management.qrcode_login/\(qrcodeId)"))
    variable.append(0x00) // QoS 0
    return qqMqttPacket(type: 8, flags: 0x02, payload: variable)
}

private let qqMqttPingreq = Data([0xC0, 0x00])

/// 从缓冲里拆出完整 MQTT 包；返回 [(包类型, 变头+载荷)]，不完整时留待下次。
private func qqMqttSplitPackets(_ buffer: inout Data) -> [(Int, Data)] {
    var out: [(Int, Data)] = []
    var offset = 0
    while offset < buffer.count {
        let first = buffer[offset]
        let type = Int(first >> 4)
        var multiplier = 1
        var length = 0
        var idx = offset + 1
        var done = false
        while idx < buffer.count {
            let b = buffer[idx]
            idx += 1
            length += Int(b & 0x7F) * multiplier
            multiplier *= 128
            if b & 0x80 == 0 { done = true; break }
            if multiplier > 128 * 128 * 128 { break }
        }
        guard done, idx + length <= buffer.count else { break }
        out.append((type, buffer.subdata(in: idx..<(idx + length))))
        offset = idx + length
    }
    if offset > 0 { buffer.removeFirst(offset) }
    return out
}

/// 解析 MQTT 5 属性块：返回用户属性字典与 serverReference（CONNACK 重定向用）。
private func qqMqttParseProperties(_ data: Data, offset: inout Int) -> (user: [String: String], serverReference: String?) {
    var user: [String: String] = [:]
    var serverReference: String?
    guard offset < data.count else { return (user, serverReference) }
    // 变长属性总长度（与 qqMqttSplitPackets 同款上限：MQTT 变长整数最多 4 字节，
    // 超过就截断丢弃；不设上限时 multiplier *= 128 会在 9 个连续 0x80 后溢出 Int64 闪退）。
    var propLen = 0
    var multiplier = 1
    while offset < data.count {
        let b = data[offset]
        offset += 1
        propLen += Int(b & 0x7F) * multiplier
        multiplier *= 128
        if b & 0x80 == 0 { break }
        if multiplier > 128 * 128 * 128 { break }
    }
    let end = min(data.count, offset + propLen)
    func readUTF8() -> String? {
        guard offset + 2 <= end else { return nil }
        let n = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        guard offset + n <= end else { return nil }
        let s = String(data: data.subdata(in: offset..<(offset + n)), encoding: .utf8)
        offset += n
        return s
    }
    func readBytes(_ n: Int) -> Data? {
        guard offset + n <= end else { return nil }
        let d = data.subdata(in: offset..<(offset + n))
        offset += n
        return d
    }
    while offset < end {
        let id = data[offset]
        offset += 1
        switch id {
        case 0x01, 0x24, 0x25, 0x28, 0x29, 0x2A: // 1 字节
            _ = readBytes(1)
        case 0x21, 0x22, 0x23: // 2 字节
            _ = readBytes(2)
        case 0x02, 0x11, 0x27: // 4 字节
            _ = readBytes(4)
        case 0x03, 0x08, 0x15, 0x1C, 0x1F: // UTF-8 字符串
            if let s = readUTF8(), id == 0x1C { serverReference = s }
        case 0x09: // 二进制（2 字节长度）
            if let n = readBytes(2) {
                let len = Int(n[0]) << 8 | Int(n[1])
                _ = readBytes(len)
            }
        case 0x0B: // 变长整数
            while offset < end {
                let b = data[offset]
                offset += 1
                if b & 0x80 == 0 { break }
            }
        case 0x26: // 用户属性：两个 UTF-8 字符串
            if let k = readUTF8(), let v = readUTF8() { user[k] = v }
        default:
            return (user, serverReference)
        }
    }
    offset = end
    return (user, serverReference)
}

/// MQTT 驱动的终结状态（extension 内不能声明带访问修饰符的嵌套类型，故放文件作用域）。
private enum MqttOutcome: Sendable { case closed; case redirect(String); case expired }

extension QQService {
    private func qqMqttRedirectPath(current: String, reference: String) -> String {
        let trimmed = current.hasSuffix("/") ? String(current.dropLast()) : current
        var parts = trimmed.split(separator: "/").map(String.init)
        if let last = parts.last, last.contains(":") {
            parts[parts.count - 1] = reference
        } else {
            parts.append(reference)
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: MQTT 驱动

    /// 等 SUBACK 就绪（轮询标志，最多 20 秒）。
    private func waitListenerReady(key: String) async -> Bool {
        for _ in 0..<200 {
            guard let s = qrSessions[key] else { return false }
            if s.listenerReady { return true }
            if s.listenerFailed != nil { return false }
            if s.state == "expired" || s.state == "failed" { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return qrSessions[key]?.listenerReady ?? false
    }

    private func failSession(key: String, reason: String) async {
        guard var s = qrSessions[key] else { return }
        if s.state == "confirmed" { return }
        s.state = "failed"
        s.failureReason = reason
        s.listenerFailed = reason
        qrSessions[key] = s
        nextQrAllowedAt = Date().addingTimeInterval(qqQrCooldown)
        s.wsTask?.cancel()
        s.driverTask?.cancel()
    }

    private func runMqttDriver(key: String) async {
        var path = "/ws/handshake"
        var redirects = 0
        while redirects <= 3 {
            let (finished, redirect) = await mqttConnectOnce(key: key, path: path)
            if finished { return }
            if let redirect {
                path = redirect
                redirects += 1
                continue
            }
            return
        }
        await failSession(key: key, reason: "MQTT 重定向次数过多")
    }

    private func mqttConnectOnce(key: String, path: String) async -> (finished: Bool, redirect: String?) {
        guard let session = qrSessions[key], let qrcodeId = session.qrcodeId,
              let url = URL(string: "wss://mu.y.qq.com\(path)") else {
            return (true, nil)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("mqtt", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let ws = URLSession.shared.webSocketTask(with: req)
        if var s = qrSessions[key] { s.wsTask = ws; qrSessions[key] = s }
        ws.resume()
        let clientId = "\(Int(Date().timeIntervalSince1970 * 1000))\(qqRandomDigits(4))"
        do {
            try await ws.send(.data(qqMqttConnect(clientId: clientId, qrcodeId: qrcodeId)))
        } catch {
            await failSession(key: key, reason: "MQTT 连接失败")
            return (true, nil)
        }
        let outcome = await withTaskGroup(of: MqttOutcome.self) { group in
            group.addTask { await self.mqttReceiveLoop(key: key, ws: ws) }
            group.addTask { await self.mqttPingLoop(key: key, ws: ws) }
            group.addTask { await self.mqttExpiryWatch(key: key) }
            var first: MqttOutcome = .closed
            if let o = await group.next() { first = o }
            group.cancelAll()
            return first
        }
        ws.cancel()
        if var s = qrSessions[key], s.wsTask === ws { s.wsTask = nil; qrSessions[key] = s }
        if case .redirect(let p) = outcome { return (false, p) }
        return (true, nil)
    }

    private func mqttReceiveLoop(key: String, ws: URLSessionWebSocketTask) async -> MqttOutcome {
        var buffer = Data()
        while true {
            do {
                let msg = try await ws.receive()
                switch msg {
                case .data(let d): buffer.append(d)
                case .string(let s): buffer.append(Data(s.utf8))
                @unknown default: break
                }
            } catch {
                return .closed
            }
            for (type, payload) in qqMqttSplitPackets(&buffer) {
                if let outcome = await handleMqttPacket(key: key, ws: ws, type: type, payload: payload) {
                    return outcome
                }
                if let s = qrSessions[key], ["confirmed", "expired", "failed"].contains(s.state) {
                    return .closed
                }
            }
        }
    }

    private func mqttPingLoop(key: String, ws: URLSessionWebSocketTask) async -> MqttOutcome {
        while true {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return .closed }
            do { try await ws.send(.data(qqMqttPingreq)) } catch { return .closed }
        }
    }

    private func mqttExpiryWatch(key: String) async -> MqttOutcome {
        guard let s = qrSessions[key] else { return .closed }
        let delay = s.expiresAt.timeIntervalSinceNow
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if Task.isCancelled { return .closed }
        if var s2 = qrSessions[key], !["confirmed", "expired", "failed"].contains(s2.state) {
            s2.state = "expired"
            qrSessions[key] = s2
        }
        return .expired
    }

    private func handleMqttPacket(key: String, ws: URLSessionWebSocketTask, type: Int, payload: Data) async -> MqttOutcome? {
        switch type {
        case 2: // CONNACK
            guard payload.count >= 2 else {
                await failSession(key: key, reason: "MQTT CONNACK 异常")
                return .closed
            }
            let reason = payload[1]
            if reason == 0 {
                if let qrcodeId = qrSessions[key]?.qrcodeId {
                    try? await ws.send(.data(qqMqttSubscribe(qrcodeId: qrcodeId)))
                }
                return nil
            }
            if reason == 0x9c || reason == 0x9d {
                var off = 2
                let (_, ref) = qqMqttParseProperties(payload, offset: &off)
                if let ref {
                    return .redirect(qqMqttRedirectPath(current: "/ws/handshake", reference: ref))
                }
            }
            await failSession(key: key, reason: "MQTT CONNACK 拒绝：0x\(String(reason, radix: 16))")
            return .closed
        case 9: // SUBACK
            var off = 2
            _ = qqMqttParseProperties(payload, offset: &off)
            var rejected = false
            while off < payload.count {
                if payload[off] >= 0x80 { rejected = true }
                off += 1
            }
            if rejected {
                await failSession(key: key, reason: "MQTT SUBACK 拒绝")
                return .closed
            }
            if var s = qrSessions[key] { s.listenerReady = true; qrSessions[key] = s }
            return nil
        case 3: // PUBLISH：topic + 属性（用户属性 type）+ JSON 体
            guard payload.count >= 2 else { return nil }
            let topicLen = Int(payload[0]) << 8 | Int(payload[1])
            var off = 2 + topicLen
            guard off <= payload.count else { return nil }
            let (user, _) = qqMqttParseProperties(payload, offset: &off)
            let bodyData = payload.subdata(in: off..<payload.count)
            let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
            let evType = user["type"] ?? scStr(body, "type")
            await mqttEvent(key: key, type: evType, body: body)
            return nil
        case 13: // PINGRESP
            return nil
        default:
            return nil
        }
    }

    private func mqttEvent(key: String, type: String, body: [String: Any]) async {
        guard var s = qrSessions[key] else { return }
        switch type {
        case "waiting":
            s.state = "waiting"
        case "scanned":
            s.state = "scanned"
        case "cookies":
            s.state = "exchanging"
            let cookies = (body["cookies"] as? [String: Any]) ?? [:]
            func cookieVal(_ name: String) -> String {
                if let d = cookies[name] as? [String: Any], let v = d["value"] as? String { return v }
                if let v = cookies[name] as? String { return v }
                return ""
            }
            s.cookies = ["musicid": cookieVal("qqmusic_uin"),
                         "token": cookieVal("qqmusic_key"),
                         "tmeLoginType": cookieVal("tmeLoginType")]
            qrSessions[key] = s
            await exchangeMqttCredential(key: key)
            return
        case "canceled":
            s.state = "failed"
            s.failureReason = "扫码已取消"
        case "timeout":
            s.state = "expired"
        case "loginFailed":
            s.state = "failed"
            s.failureReason = scStr(body, "message")
        default:
            break
        }
        qrSessions[key] = s
    }

    // MARK: 换凭证

    private func musicuRawBody(_ bodyString: String, timeout: TimeInterval = 25) async throws -> [String: Any] {
        guard let bodyData = bodyString.data(using: .utf8), let url = URL(string: qqMusicuURL) else {
            throw QQUpstreamError(code: -1, message: "musicu 请求构造失败")
        }
        let (data, resp) = try await Upstream.fetch(url, headers: ["Content-Type": "application/json", "User-Agent": qqUA],
                                                    timeout: timeout, method: "POST", body: bodyData)
        guard resp.statusCode == 200, let obj = Upstream.jsonObject(data), scInt(obj, "code") == 0,
              let req0 = obj["req_0"] as? [String: Any], scInt(req0, "code") == 0,
              let d = req0["data"] as? [String: Any] else {
            throw QQUpstreamError(code: -1, message: "musicu 上游错误")
        }
        return d
    }

    private func credentialFrom(data: [String: Any], defaultLoginType: Int) throws -> [String: Any] {
        let musicid = scStrOrNum(data, "musicid")
        let strId = scStrOrNum(data, "str_musicid")
        let musickey = scStr(data, "musickey")
        guard !musickey.isEmpty, !(musicid.isEmpty && strId.isEmpty) else {
            throw QQUpstreamError(code: -1, message: "换凭证返回缺 musickey")
        }
        var cred: [String: Any] = [
            "musicid": musicid.isEmpty ? strId : musicid,
            "str_musicid": strId.isEmpty ? musicid : strId,
            "musickey": musickey,
            "loginType": scInt(data, "loginType") == 0 ? defaultLoginType : scInt(data, "loginType"),
            "musickeyCreateTime": Date().timeIntervalSince1970,
            "keyExpiresIn": 259200,
        ]
        for k in ["openid", "refresh_token", "refresh_key", "unionid", "encryptUin", "nick", "nickname", "logo", "avatarUrl"] {
            let v = scStr(data, k)
            if !v.isEmpty { cred[k] = v }
        }
        if let exp = data["keyExpiresIn"] as? NSNumber, exp.intValue > 0 { cred["keyExpiresIn"] = exp.intValue }
        if let ct = data["musickeyCreateTime"] as? NSNumber, ct.doubleValue > 0 { cred["musickeyCreateTime"] = ct.doubleValue }
        return cred
    }

    /// LoginServer/Login 换凭证。musicid 超 JS 安全整数时送不带引号的数字面量（ExactInteger）。
    private func loginExchange(musicid: String, qrcodeId: String, token: String, loginType: Int) async throws -> [String: Any] {
        let needsRaw: Bool = {
            guard musicid.count >= 16, musicid.allSatisfy({ $0.isNumber }) else { return false }
            if musicid.count > 16 { return true }
            return (Int(musicid) ?? 0) > 9007199254740991
        }()
        if needsRaw {
            guard let commData = qqJSONData(androidComm(overrides: ["tmeLoginType": loginType])),
                  let commStr = String(data: commData, encoding: .utf8) else {
                throw QQUpstreamError(code: -1, message: "musicu 请求构造失败")
            }
            let bodyStr = "{\"comm\":\(commStr),\"req_0\":{\"module\":\"music.login.LoginServer\",\"method\":\"Login\",\"param\":{\"musicid\":\(musicid),\"qrCodeID\":\"\(qqJSONStringEscape(qrcodeId))\",\"token\":\"\(qqJSONStringEscape(token))\"}}}"
            let d = try await musicuRawBody(bodyStr)
            return try credentialFrom(data: d, defaultLoginType: loginType)
        }
        let param: [String: Any] = ["musicid": Int(musicid) ?? 0, "qrCodeID": qrcodeId, "token": token]
        let d = try await musicuAuth(module: "music.login.LoginServer", method: "Login", param: param,
                                     commOverride: ["tmeLoginType": loginType], readOnly: false)
        return try credentialFrom(data: d, defaultLoginType: loginType)
    }

    private func finalizeCredential(key: String, cred: [String: Any]) async {
        saveCredential(cred)
        if let profile = await getLoginProfile() {
            var c = cred
            if let nick = profile["nickname"] as? String, !nick.isEmpty { c["nickname"] = nick }
            if let av = profile["avatar"] as? String, !av.isEmpty { c["avatarUrl"] = av }
            saveCredential(c)
        }
        if var s = qrSessions[key] {
            s.state = "confirmed"
            s.expiresAt = max(s.expiresAt, Date().addingTimeInterval(qqQrClaim))
            qrSessions[key] = s
            s.wsTask?.cancel()
            s.driverTask?.cancel()
        }
    }

    private func exchangeMqttCredential(key: String) async {
        guard let s = qrSessions[key] else { return }
        let musicid = s.cookies["musicid"] ?? ""
        let token = s.cookies["token"] ?? ""
        guard let qrcodeId = s.qrcodeId, !musicid.isEmpty, !token.isEmpty else {
            await failSession(key: key, reason: "MQTT 票据缺失")
            return
        }
        let loginType = s.channel == "qqmusic" ? (s.cookies["tmeLoginType"] == "1" ? 1 : 6) : 6
        do {
            let cred = try await loginExchange(musicid: musicid, qrcodeId: qrcodeId, token: token, loginType: loginType)
            await finalizeCredential(key: key, cred: cred)
        } catch {
            // 兜底：MQTT 原始票据直连 GetLoginUserInfo 校验一次；失败恢复原有登录态。
            let direct: [String: Any] = ["musicid": musicid, "str_musicid": musicid,
                                          "musickey": token, "loginType": loginType,
                                          "musickeyCreateTime": Date().timeIntervalSince1970,
                                          "keyExpiresIn": 259200]
            let previous = loadCredential()
            saveCredential(direct)
            if await getLoginProfile() != nil {
                await finalizeCredential(key: key, cred: direct)
            } else {
                saveCredential(previous)
                await failSession(key: key, reason: "换凭证失败")
            }
        }
    }

    private func exchangeWechatCredential(key: String, code: String) async {
        guard !code.isEmpty else {
            await failSession(key: key, reason: "WeChat authorization missing code")
            return
        }
        do {
            let d = try await musicuAuth(module: "music.login.LoginServer", method: "Login",
                                         param: ["code": code, "strAppid": qqWechatAppId],
                                         commOverride: ["tmeLoginType": 1], readOnly: false)
            let cred = try credentialFrom(data: d, defaultLoginType: 1)
            await finalizeCredential(key: key, cred: cred)
        } catch {
            await failSession(key: key, reason: "换凭证失败")
        }
    }

    // MARK: 扫码会话

    private func refreshAndroidSession() async throws {
        var d = loadDevice()
        let param: [String: Any] = ["uid": d["sessionUid"] ?? "", "vkey": 0, "caller": 0]
        let data = try await musicuAuth(module: "music.getSession.session", method: "GetSession", param: param)
        guard let session = data["session"] as? [String: Any] else {
            throw QQUpstreamError(code: -1, message: "GetSession 返回缺 session")
        }
        d["sessionUid"] = scStrOrNum(session, "uid")
        d["sessionSid"] = scStr(session, "sid")
        d["sessionVkey"] = scStr(session, "vkey")
        device = d
        saveDevice()
    }

    private func createSession(channel: String) async throws -> String {
        let ch = qqChannels.contains(channel) ? channel : "qqmusic"
        let now = Date()
        if now < nextQrAllowedAt {
            throw QQAuthError(429, "QR login is temporarily backed off",
                              retryAfterMs: Int(nextQrAllowedAt.timeIntervalSince(now) * 1000))
        }
        if creatingSession { throw QQAuthError(409, "Another QR login is already active") }
        if qrSessions.values.contains(where: { $0.state == "exchanging" }) {
            throw QQAuthError(409, "Another QR login is already active")
        }
        qrSessions = qrSessions.filter { $0.value.expiresAt > now }
        creatingSession = true
        defer { creatingSession = false }
        do {
            try await refreshAndroidSession()
        } catch {
            throw QQAuthError(502, "QQ 设备会话建立失败")
        }
        let key = qqRandomHex(48)
        qrSessions[key] = QQSession(key: key, channel: ch, state: "created", createdAt: now,
                                    expiresAt: now.addingTimeInterval(qqQrTTL))
        return key
    }

    private func createQr(key: String) async throws -> String {
        guard var s = qrSessions[key] else { throw QQAuthError(404, "QR code expired") }
        if let img = s.imageUrl, !img.isEmpty { return img }
        guard s.state == "created" else { throw QQAuthError(409, "QR session is not in created state") }
        if s.channel == "wechat" {
            let (uuid, img) = try await wechatCreateQr()
            s.wxUuid = uuid
            s.imageUrl = img
            s.state = "waiting"
            qrSessions[key] = s
            return img
        }
        let data = try await musicuAuth(module: "music.login.LoginServer", method: "CreateQRCode",
                                        param: ["tmeAppID": "qqmusic", "ct": 11, "cv": 14090008],
                                        commOverride: ["ct": 23, "cv": 0])
        let qrcodeId = scStr(data, "qrcodeID")
        guard !qrcodeId.isEmpty else {
            throw QQAuthError(502, "二维码生成失败（上游没给图片）")
        }
        let qrcodeRaw = scStr(data, "qrcode")
        let b64 = qrcodeRaw.split(separator: ",").last.map(String.init) ?? qrcodeRaw
        guard let png = Data(base64Encoded: b64),
              png.prefix(8).map({ String(format: "%02x", $0) }).joined() == "89504e470d0a1a0a" else {
            throw QQAuthError(502, "二维码生成失败（上游没给图片）")
        }
        let img = "data:image/png;base64,\(b64)"
        s.qrcodeId = qrcodeId
        s.imageUrl = img
        if let exp = data["expiresIn"] as? NSNumber, exp.intValue > 0 {
            s.expiresAt = min(s.expiresAt, Date().addingTimeInterval(TimeInterval(exp.intValue)))
        }
        qrSessions[key] = s
        s.driverTask = Task { await self.runMqttDriver(key: key) }
        qrSessions[key] = s
        guard await waitListenerReady(key: key) else {
            let reason = qrSessions[key]?.listenerFailed ?? "MQTT 监听器启动超时"
            throw QQAuthError(502, reason)
        }
        return img
    }

    private func wechatCreateQr() async throws -> (String, String) {
        var comps = URLComponents(string: "https://open.weixin.qq.com/connect/qrconnect") ?? URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "appid", value: qqWechatAppId),
            URLQueryItem(name: "redirect_uri", value: "https://y.qq.com/portal/wx_redirect.html?login_type=2&surl=https://y.qq.com/"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "snsapi_login"),
            URLQueryItem(name: "state", value: "STATE"),
            URLQueryItem(name: "href", value: "https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect"),
        ]
        guard let url = comps.url else { throw QQAuthError(502, "二维码生成失败（上游没给图片）") }
        let (data, _) = try await Upstream.fetch(url, timeout: 15)
        let html = qqDecodeText(data)
        guard let m = try? NSRegularExpression(pattern: #"uuid=(.+?)""#).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else {
            throw QQAuthError(502, "二维码生成失败（上游没给图片）")
        }
        let uuid = String(html[r])
        guard let imgUrl = URL(string: "https://open.weixin.qq.com/connect/qrcode/\(uuid)") else {
            throw QQAuthError(502, "二维码生成失败（上游没给图片）")
        }
        let (imgData, _) = try await Upstream.fetch(imgUrl, headers: ["Referer": "https://open.weixin.qq.com/connect/qrconnect"], timeout: 15)
        let magic = imgData.prefix(8).map { String(format: "%02x", $0) }.joined()
        let mime: String
        if magic.hasPrefix("89504e470d0a1a0a") { mime = "image/png" }
        else if magic.hasPrefix("ffd8ff") { mime = "image/jpeg" }
        else { throw QQAuthError(502, "二维码生成失败（上游没给图片）") }
        return (uuid, "data:\(mime);base64,\(imgData.base64EncodedString())")
    }

    /// 微信通道轮询一轮（长轮询 15 秒预算）：408 等待 / 404 已扫 / 405 确认 / 402 过期 / 403 拒绝。
    private func advanceWechat(key: String) async {
        guard var s = qrSessions[key], let uuid = s.wxUuid else { return }
        var comps = URLComponents(string: "https://lp.open.weixin.qq.com/connect/l/qrconnect") ?? URLComponents()
        var items = [URLQueryItem(name: "uuid", value: uuid)]
        if s.state == "scanned", let last = s.wxLast {
            items.append(URLQueryItem(name: "last", value: String(last)))
        }
        items.append(URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps.queryItems = items
        guard let url = comps.url else { return }
        do {
            let (data, _) = try await Upstream.fetch(url, headers: ["Referer": "https://open.weixin.qq.com/"], timeout: 15)
            let text = qqDecodeText(data)
            s.wxPollErrors = 0
            guard let m = try? NSRegularExpression(pattern: #"window\.wx_errcode=(\d+);window\.wx_code='([^']*)'"#).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r1 = Range(m.range(at: 1), in: text) else {
                qrSessions[key] = s
                return
            }
            let errcode = Int(text[r1]) ?? 0
            let wxCode = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            switch errcode {
            case 408:
                s.state = "waiting"
            case 404:
                s.state = "scanned"
                s.wxLast = 404
            case 405:
                s.state = "exchanging"
                qrSessions[key] = s
                await exchangeWechatCredential(key: key, code: wxCode)
                return
            case 402:
                s.state = "expired"
            case 403:
                s.state = "failed"
                s.failureReason = "扫码被拒绝"
            default:
                break
            }
            qrSessions[key] = s
        } catch {
            s.wxPollErrors += 1
            if s.wxPollErrors > 3 {
                s.state = "failed"
                s.failureReason = "微信轮询失败"
            }
            qrSessions[key] = s
        }
    }

    private func checkQr(key: String) async -> [String: Any] {
        guard var s = qrSessions[key] else {
            return ["code": 800, "message": "QR code expired"]
        }
        if s.state != "confirmed" && Date() > s.expiresAt {
            s.state = "expired"
            qrSessions[key] = s
        }
        if s.channel == "wechat" && ["created", "waiting", "scanned"].contains(s.state) {
            await advanceWechat(key: key)
            s = qrSessions[key] ?? s
        }
        switch s.state {
        case "confirmed":
            var out: [String: Any] = ["code": 803, "message": "Authorization login successful", "loggedIn": true]
            if let profile = await getLoginProfile() {
                out["nickname"] = profile["nickname"] as? String ?? ""
                out["avatar"] = profile["avatar"] as? String ?? ""
            }
            return out
        case "scanned", "exchanging":
            return ["code": 802, "message": "QR code scanned"]
        case "expired", "failed":
            var out: [String: Any] = ["code": 800,
                                      "message": s.state == "failed" ? "QR login failed" : "QR code expired"]
            if let r = s.retryAfterMs { out["retryAfterMs"] = r }
            if let f = s.failureReason { out["error"] = f }
            return out
        default:
            return ["code": 801, "message": "Waiting for QR scan"]
        }
    }

    private func cancelQrSession(key: String) {
        guard let s = qrSessions[key] else { return }
        if s.state == "confirmed" { return }
        if s.state == "exchanging" {
            // 换凭证已经在路上：记下取消，换完不发会话（本移植直接丢弃该会话）。
            qrSessions.removeValue(forKey: key)
            return
        }
        s.wsTask?.cancel()
        s.driverTask?.cancel()
        qrSessions.removeValue(forKey: key)
    }

    // MARK: 凭证续期与画像

    private func isCredentialRejection(_ error: Error) -> Bool {
        if let e = error as? QQUpstreamError { return qqCredentialRejectionCodes.contains(e.code) }
        return false
    }

    /// 到期前 6h 且有 refresh_key 时静默刷新；失败 5 分钟内不再试；凭证被拒时清凭证返回 nil。
    private func ensureCredential() async -> [String: Any]? {
        guard var cred = loadCredential() else { return nil }
        let now = Date().timeIntervalSince1970
        let created = (cred["musickeyCreateTime"] as? NSNumber)?.doubleValue ?? 0
        let expiresIn = (cred["keyExpiresIn"] as? NSNumber)?.doubleValue ?? 0
        let expiresAt = (created > 0 && expiresIn > 0) ? created + expiresIn : now + 86400
        let refreshKey = scStr(cred, "refresh_key")
        if !refreshKey.isEmpty && now > expiresAt - 6 * 3600 && now >= refreshRetryAt {
            do {
                let d = try await musicuAuth(module: "music.login.LoginServer", method: "Login",
                                             param: ["openid": scStr(cred, "openid"),
                                                     "refresh_token": scStr(cred, "refresh_token"),
                                                     "str_musicid": credentialMusicId(cred),
                                                     "musickey": scStr(cred, "musickey"),
                                                     "unionid": scStr(cred, "unionid"),
                                                     "refresh_key": refreshKey,
                                                     "loginMode": 2],
                                             commOverride: ["tmeLoginType": scInt(cred, "loginType")],
                                             readOnly: false)
                let refreshed = try credentialFrom(data: d, defaultLoginType: scInt(cred, "loginType"))
                var merged = cred
                for (k, v) in refreshed { merged[k] = v }
                cred = merged
                saveCredential(cred)
            } catch {
                if isCredentialRejection(error) {
                    // 凭证被拒：不删登录态文件（status 还要靠它出 stale 头像），只推迟重试。
                    refreshRetryAt = now + 300
                    return cred
                }
                refreshRetryAt = now + 300
            }
        }
        return cred
    }

    /// GetLoginUserInfo（param {}）：返回画像；失败返回 nil。
    private func getLoginProfile() async -> [String: Any]? {
        guard let cred = loadCredential() else { return nil }
        do {
            let d = try await musicuAuth(module: "music.UserInfo.userInfoServer", method: "GetLoginUserInfo", param: [:])
            let info = d["info"] as? [String: Any] ?? [:]
            var nickname = scStr(cred, "nick")
            if nickname.isEmpty { nickname = scStr(cred, "nickname") }
            if nickname.isEmpty { nickname = scStr(info, "nick") }
            if nickname.isEmpty { nickname = "QQ 音乐用户" }
            var avatar = qqProfileAvatar(cred, info: info)
            if avatar.isEmpty { avatar = scStr(cred, "avatarUrl") }
            return ["loggedIn": true, "nickname": nickname, "avatar": avatar, "uin": credentialMusicId(cred)]
        } catch {
            return nil
        }
    }

    /// headpic → avatarUrl → avatar → info.logo，第一个 http(s) 且不含 t_user_default 的。
    private func qqProfileAvatar(_ cred: [String: Any], info: [String: Any]) -> String {
        for c in [scStr(cred, "headpic"), scStr(cred, "avatarUrl"), scStr(cred, "avatar"), scStr(info, "logo")] {
            if c.hasPrefix("http") && !c.contains("t_user_default") { return c }
        }
        return ""
    }

    private func publicAvatarByUin(_ uid: String) async -> String? {
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        guard let url1 = URL(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss?hostuin=\(uid)&sin=0&size=5&format=json&inCharset=utf8&outCharset=utf-8&g_tk=5381&loginUin=0&hostUin=0&platform=yqq.json&needNewCode=0"),
              let (data1, _) = try? await Upstream.fetch(url1, headers: ["User-Agent": ua, "Referer": "https://y.qq.com/"], timeout: 4),
              let obj1 = qqParseJSONText(qqDecodeText(data1)) as? [String: Any],
              let dataObj = obj1["data"] as? [String: Any],
              let disslist = dataObj["disslist"] as? [[String: Any]] else { return nil }
        for diss in disslist.prefix(2) {
            let tid = scStrOrNum(diss, "tid")
            guard !tid.isEmpty,
                  let url2 = URL(string: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=\(tid)&format=json&g_tk=5381&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"),
                  let (data2, _) = try? await Upstream.fetch(url2, headers: ["User-Agent": ua, "Referer": "https://y.qq.com/"], timeout: 4),
                  let obj2 = qqParseJSONText(qqDecodeText(data2)) as? [String: Any],
                  let cdlist = obj2["cdlist"] as? [[String: Any]],
                  let first = cdlist.first else { continue }
            let av = scStr(first, "headurl")
            if !av.isEmpty { return av }
            let av2 = scStr(first, "avatar")
            if !av2.isEmpty { return av2 }
        }
        return nil
    }

    /// 失效会话的只读头像：只返回昵称/头像，绝不把 loggedIn 改成 true。
    private func cachedProfile() async -> [String: Any] {
        guard let cred = loadCredential() else { return ["code": 200, "empty": true] }
        let uid = credentialMusicId(cred)
        var nickname = scStr(cred, "nick")
        if nickname.isEmpty { nickname = scStr(cred, "nickname") }
        var avatar = scStr(cred, "avatarUrl")
        if avatar.isEmpty { avatar = scStr(cred, "logo") }
        if (avatar.isEmpty || avatar.contains("t_user_default")),
           uid.range(of: "^[1-9]\\d{0,19}$", options: .regularExpression) != nil,
           let pub = await publicAvatarByUin(uid), !pub.isEmpty {
            avatar = pub
        }
        if uid.isEmpty && nickname.isEmpty && avatar.isEmpty { return ["code": 200, "empty": true] }
        return ["code": 200, "uid": uid, "nickname": nickname, "avatar": avatar]
    }
}

extension QQService {
    // MARK: - 播放取链

    private func qqVkeyFilename(quality: String, mid: String, mediaMid: String) -> String {
        switch quality {
        case "m4a": return "C400\(mid)\(mediaMid).m4a"
        case "320": return "M800\(mid)\(mediaMid).mp3"
        case "ape": return "A000\(mid)\(mediaMid).ape"
        case "flac": return "F000\(mid)\(mediaMid).flac"
        default: return "M500\(mid)\(mediaMid).mp3"
        }
    }

    /// vkey 取链：登录走 UrlGetVkey，匿名走 UCommon CgiGetVkey。返回 req_0.data。
    private func vkeyRequest(mid: String, filename: String, guid: String) async throws -> [String: Any] {
        if loadCredential() != nil {
            return try await musicuAuth(module: "music.vkey.GetVkey", method: "UrlGetVkey",
                                        param: ["filename": [filename], "guid": guid, "songmid": [mid],
                                                "songtype": [0], "uin": credentialMusicId(), "ctx": 0])
        }
        let data: [String: Any] = [
            "req_0": ["module": "vkey.GetVkeyServer", "method": "CgiGetVkey",
                      "param": ["filename": [filename], "guid": "1429839143", "songmid": [mid],
                                "songtype": [0], "uin": "0", "loginflag": 1, "platform": "20"]],
            "loginUin": "0",
            "comm": ["uin": "0", "format": "json", "ct": 24, "cv": 0],
        ]
        return try await ucommon(data: data)
    }

    /// sip/midurlinfo 拼直链：domain 取第一个不以 http://ws 开头的 sip，否则取 sip[0]。
    private func urlFromVkey(_ data: [String: Any], mid: String) -> (url: String?, purl: String?) {
        guard let midurlinfo = data["midurlinfo"] as? [[String: Any]] else { return (nil, nil) }
        var purl: String?
        for info in midurlinfo where scStr(info, "songmid") == mid {
            purl = scStr(info, "purl")
            break
        }
        if purl == nil || purl!.isEmpty {
            purl = midurlinfo.compactMap { scStr($0, "purl") }.first(where: { !$0.isEmpty })
        }
        guard let p = purl, !p.isEmpty else { return (nil, nil) }
        if let sip = data["sip"] as? [String] {
            let domain = sip.first(where: { !$0.hasPrefix("http://ws") }) ?? sip.first
            if let domain, !domain.isEmpty { return (domain + p, p) }
        }
        return (nil, p)
    }

    /// sip 为空时的 CDN 兜底：首选 sjy6 探测，失败调 GetCdnDispatch 再试其 sip，末尾追加 dl。
    private func cdnFallbackUrl(purl: String, guid: String) async -> String {
        var candidates: [String] = ["http://sjy6.stream.qqmusic.qq.com/"]
        if let d = try? await musicuAnon(module: "music.audioCdnDispatch.cdnDispatch", method: "GetCdnDispatch",
                                         param: ["guid": guid, "uid": "0", "use_new_domain": 1, "use_ipv6": 1]),
           let sip = d["sip"] as? [String] {
            candidates.append(contentsOf: sip.filter { $0 != "http://sjy6.stream.qqmusic.qq.com/" })
        }
        candidates.append("http://dl.stream.qqmusic.qq.com/")
        for domain in candidates {
            if await qqProbeURL(domain + purl) { return domain + purl }
        }
        return "http://dl.stream.qqmusic.qq.com/" + purl
    }

    private func resolvePlayUrl(mid: String, quality: String) async -> (url: String, loginRequired: Bool) {
        var loginRequired = false
        let q = ["m4a", "128", "320", "ape", "flac", "best"].contains(quality) ? quality : "128"
        let detail = await songDetail(mid: mid)
        let file = detail?["file"] as? [String: Any] ?? [:]
        let mediaMid = scStr(file, "media_mid").isEmpty ? mid : scStr(file, "media_mid")
        var order: [String]
        if q == "best" {
            if loadCredential() == nil {
                order = ["128"]
            } else {
                order = []
                if scInt(file, "size_flac") > 0 { order.append("flac") }
                if scInt(file, "size_320mp3") > 0 { order.append("320") }
                order.append("128")
            }
        } else {
            order = [q]
        }
        let guid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        for attemptQuality in order {
            let filename = qqVkeyFilename(quality: attemptQuality, mid: mid, mediaMid: mediaMid)
            do {
                let data = try await vkeyRequest(mid: mid, filename: filename, guid: guid)
                let (url, purl) = urlFromVkey(data, mid: mid)
                if let url { return (url, loginRequired) }
                if let purl { return (await cdnFallbackUrl(purl: purl, guid: guid), loginRequired) }
            } catch {
                if isCredentialRejection(error) { loginRequired = true }
            }
            // m4a/128 登录分支：首次无链接时同一 guid、同一文件名再要一次。
            if loadCredential() != nil && (attemptQuality == "m4a" || attemptQuality == "128") {
                do {
                    let data = try await vkeyRequest(mid: mid, filename: filename, guid: guid)
                    let (url, _) = urlFromVkey(data, mid: mid)
                    if let url { return (url, loginRequired) }
                } catch {
                    if isCredentialRejection(error) { loginRequired = true }
                }
            }
        }
        return ("", loginRequired)
    }

    /// 试听：RS02<14 位 mediaId>.mp3，仅 size_try > 0 时取。
    private func previewUrl(mid: String) async -> String {
        guard let detail = await songDetail(mid: mid),
              let file = detail["file"] as? [String: Any],
              scInt(file, "size_try") > 0 else { return "" }
        let mediaId = scStr(file, "media_mid")
        guard mediaId.range(of: "^[A-Za-z0-9]{14}$", options: .regularExpression) != nil else { return "" }
        let guid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let data = try? await vkeyRequest(mid: mid, filename: "RS02\(mediaId).mp3", guid: guid) else { return "" }
        return urlFromVkey(data, mid: mid).url ?? ""
    }

    // MARK: - 归一化

    private func qqCover(_ albumMid: String) -> String {
        albumMid.isEmpty ? "" : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"
    }

    private func qqFirstStr(_ d: [String: Any], _ keys: [String]) -> String {
        for k in keys {
            let s = scStr(d, k)
            if !s.isEmpty { return s }
        }
        return ""
    }

    private func qqFirstInt(_ d: [String: Any], _ keys: [String]) -> Int {
        for k in keys where d[k] != nil { return scInt(d, k) }
        return 0
    }

    private func qqTrack(_ it: [String: Any]) -> [String: Any]? {
        let mid = scStr(it, "mid")
        guard !mid.isEmpty else { return nil }
        let singers = scArr(it, "singer")
        let artists = singers.map { scStr($0, "name") }.filter { !$0.isEmpty }.joined(separator: " / ")
        let album = scDict(it, "album")
        let pay = scDict(it, "pay")
        return [
            "id": mid, "source": "qq",
            "name": qqFirstStr(it, ["name", "title"]),
            "artists": artists.isEmpty ? "未知歌手" : artists,
            "artistIds": singers.map { scStr($0, "mid") }.filter { !$0.isEmpty },
            "album": qqFirstStr(album, ["name", "title"]),
            "cover": qqCover(scStr(album, "mid")),
            "duration": scInt(it, "interval") * 1000,
            "fee": scInt(pay, "pay_play") > 0 ? 1 : 0,
            "mid": mid,
            "songId": scInt(it, "id") > 0 ? scInt(it, "id") : 0,
        ]
    }

    private func qqPlaylist(_ it: [String: Any]) -> [String: Any]? {
        let id = qqFirstStr(it, ["dirId", "dissid", "tid", "id"])
        guard !id.isEmpty else { return nil }
        let creator = scDict(it, "creator")
        let nickname = qqFirstStr(it, ["nickname", "nick"])
        let creatorNick = nickname.isEmpty ? qqFirstStr(creator, ["nickname", "nick"]) : nickname
        return [
            "id": id,
            "name": qqFirstStr(it, ["dirName", "dissname", "title"]).isEmpty ? "未命名歌单" : qqFirstStr(it, ["dirName", "dissname", "title"]),
            "cover": qqFirstStr(it, ["picUrl", "picurl", "cover", "logo", "pic"]),
            "trackCount": qqFirstInt(it, ["songNum", "songnum", "song_cnt"]),
            "playCount": qqFirstInt(it, ["listenCount", "play_cnt", "playCount"]),
            "creator": ["nickname": creatorNick],
            "source": "qq",
        ]
    }

    private func qqUserAlbum(_ it: [String: Any]) -> [String: Any]? {
        let mid = scStr(it, "albummid")
        let id = !mid.isEmpty ? mid : scStrOrNum(it, "albumid")
        guard !id.isEmpty else { return nil }
        let singerName = scStr(it, "singername")
        let singers = scArr(it, "singer")
        let artistName = !singerName.isEmpty ? singerName
            : singers.map { scStr($0, "name") }.filter { !$0.isEmpty }.joined(separator: " / ")
        let cover = qqFirstStr(it, ["albumcover", "albumCover", "pic", "cover"])
        let pub = it["pubtime"] ?? it["pubTime"] ?? it["publishTime"] ?? it["releaseTime"] ?? 0
        return [
            "id": id, "source": "qq",
            "name": qqFirstStr(it, ["albumname", "albumName", "name", "title"]).isEmpty ? "未知专辑" : qqFirstStr(it, ["albumname", "albumName", "name", "title"]),
            "artists": [["name": artistName.isEmpty ? "未知歌手" : artistName]],
            "cover": cover.isEmpty ? qqCover(mid) : cover,
            "publishTime": pub,
            "trackCount": qqFirstInt(it, ["songnum", "songNum", "total", "count"]),
        ]
    }

    // MARK: - 路由

    private func health() -> HttpResponse {
        .json(200, ["code": 200, "ok": true, "port": 0, "channels": qqChannels, "sessionMode": "stored"])
    }

    private func status() async -> HttpResponse {
        guard await ensureCredential() != nil else {
            return .json(200, ["code": 200, "loggedIn": false])
        }
        do {
            let d = try await musicuAuth(module: "music.UserInfo.userInfoServer", method: "GetLoginUserInfo", param: [:])
            let info = d["info"] as? [String: Any] ?? [:]
            let cred = loadCredential() ?? [:]
            var nickname = scStr(cred, "nick")
            if nickname.isEmpty { nickname = scStr(cred, "nickname") }
            if nickname.isEmpty { nickname = scStr(info, "nick") }
            if nickname.isEmpty { nickname = "QQ 音乐用户" }
            var avatar = qqProfileAvatar(cred, info: info)
            if avatar.isEmpty { avatar = scStr(cred, "avatarUrl") }
            return .json(200, ["code": 200, "loggedIn": true, "nickname": nickname,
                                "avatar": avatar, "uin": credentialMusicId(cred)])
        } catch {
            // 上游 401：未登录，另带失效会话的头像（stale），不删登录态文件。
            var out: [String: Any] = ["code": 200, "loggedIn": false]
            let cached = await cachedProfile()
            if let uid = cached["uid"] as? String, !uid.isEmpty {
                out["stale"] = true
                out["nickname"] = cached["nickname"] as? String ?? ""
                out["avatar"] = cached["avatar"] as? String ?? ""
                out["uin"] = uid
            }
            return .json(200, out)
        }
    }

    private func loginQrKey(req: HttpRequest) async -> HttpResponse {
        let raw = req.string("channel", "qqmusic")
        let channel = qqChannels.contains(raw) ? raw : "qqmusic"
        do {
            let key = try await createSession(channel: channel)
            do {
                let img = try await createQr(key: key)
                return .json(200, ["code": 200, "key": key, "qrimg": img, "channel": channel])
            } catch let e as QQAuthError {
                return .json(200, ["code": e.code, "key": key, "qrimg": "", "channel": channel,
                                    "retryAfterMs": e.retryAfterMs.map { NSNumber(value: $0) } ?? NSNull(), "error": e.message])
            } catch {
                return .json(200, ["code": 502, "key": key, "qrimg": "", "channel": channel,
                                    "retryAfterMs": NSNull(), "error": "二维码生成失败（上游没给图片）"])
            }
        } catch let e as QQAuthError {
            return .json(200, ["code": e.code, "key": NSNull(), "channel": channel,
                                "retryAfterMs": e.retryAfterMs ?? NSNull(), "error": e.message])
        } catch {
            return .json(200, ["code": 502, "key": NSNull(), "channel": channel,
                                "retryAfterMs": NSNull(), "error": "拿不到二维码 key"])
        }
    }

    private func loginQrCreate(req: HttpRequest) async -> HttpResponse {
        let key = req.string("key")
        guard !key.isEmpty else { return .json(400, ["code": 400, "error": "key required"]) }
        do {
            let img = try await createQr(key: key)
            return .json(200, ["code": 200, "key": key, "qrimg": img])
        } catch let e as QQAuthError {
            return .json(200, ["code": e.code, "key": key, "qrimg": "", "error": e.message])
        } catch {
            return .json(200, ["code": 502, "key": key, "qrimg": "", "error": "二维码生成失败（上游没给图片）"])
        }
    }

    private func loginQrCheck(req: HttpRequest) async -> HttpResponse {
        let key = req.string("key")
        guard !key.isEmpty else { return .json(400, ["code": 400, "error": "key required"]) }
        return .json(200, await checkQr(key: key))
    }

    private func search(req: HttpRequest) async -> HttpResponse {
        let s = (req.string("s").isEmpty ? req.string("keyword") : req.string("s"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            return .json(200, ["code": 200, "source": "qq", "tracks": [], "songCount": 0])
        }
        let limit = min(20, max(1, req.int("limit", 20)))
        let page = max(1, req.int("page", 1))
        let authed = await ensureCredential() != nil
        let cacheKey = "\(authed ? "auth" : "anon")|\(s)|\(limit)|\(page)"
        if let hit = searchCache.first(where: { $0.key == cacheKey }),
           Date().timeIntervalSince(hit.at) < 60 {
            var data = hit.data
            data["cached"] = true
            return .json(200, data)
        }
        let typeStr = req.string("type", "song")
        let typeCode = ["song": 0, "singer": 1, "album": 2, "playlist": 3][typeStr] ?? 0
        // 匿名搜歌送 search_type=7（送 0 会回 2001）；登录时送 0。
        let searchType = (!authed && typeCode == 0) ? 7 : typeCode
        let searchId = String(Int.random(in: 1...9)) + qqRandomDigits(17)
        let param: [String: Any] = [
            "search_id": searchId, "remoteplace": "search.android.keyboard", "query": s,
            "search_type": searchType, "num_per_page": limit, "page_num": page,
            "highlight": 0, "nqc_flag": 0, "page_id": 1, "grp": 1,
        ]
        var lastCode = 502
        var lastMessage = "QQ 搜索失败"
        for (attempt, wait) in [(0, 0), (1, 1200), (2, 2500)] {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
            do {
                let data: [String: Any]
                if authed {
                    data = try await musicuAuth(module: "music.search.SearchCgiService",
                                                method: "DoSearchForQQMusicLite", param: param)
                } else {
                    let comm: [String: Any] = ["ct": 11, "cv": "1003006", "v": "1003006",
                                               "tmeAppID": "qqmusiclight", "nettype": "NETWORK_WIFI",
                                               "udid": "0", "uid": "0"]
                    data = try await musicu(comm: comm, module: "music.search.SearchCgiService",
                                            method: "DoSearchForQQMusicLite", param: param,
                                            headers: ["Cookie": "tmeLoginType=-1", "User-Agent": qqLiteUA])
                }
                let body = data["body"] as? [String: Any] ?? [:]
                let meta = data["meta"] as? [String: Any] ?? [:]
                let items = qqSearchItems(body: body, type: typeStr)
                let payload: [String: Any] = [
                    "code": 200, "source": "qq",
                    "tracks": items.compactMap { qqTrack($0) },
                    "songCount": scInt(meta, "sum") == 0 ? items.count : scInt(meta, "sum"),
                    "more": ((meta["nextpage"] as? NSNumber)?.intValue ?? 0) > 0,
                ]
                searchCache.append((key: cacheKey, at: Date(), data: payload))
                if searchCache.count > 24 { searchCache.removeFirst() }
                return .json(200, payload)
            } catch let e as QQUpstreamError {
                lastCode = e.code
                lastMessage = e.message
            } catch {
                lastCode = 502
                lastMessage = error.localizedDescription
            }
        }
        return .json(200, ["code": lastCode, "source": "qq", "tracks": [],
                            "error": lastMessage + (lastCode == 2001 ? "（上游 2001，稍后再试）" : ""),
                            "upstream": ["code": lastCode]])
    }

    private func qqSearchItems(body: [String: Any], type: String) -> [[String: Any]] {
        let key: String
        switch type {
        case "singer": key = "singer"
        case "album": key = "item_album"
        case "playlist": key = "item_songlist"
        default: key = "item_song"
        }
        if let arr = body[key] as? [[String: Any]] { return arr }
        if let d = body[key] as? [String: Any], let arr = d["list"] as? [[String: Any]] { return arr }
        return []
    }

    private func lyric(req: HttpRequest) async throws -> HttpResponse {
        let mid = req.string("mid").isEmpty ? req.string("id") : req.string("mid")
        guard !mid.isEmpty else { return .json(400, ["code": 400, "error": "mid required"]) }
        let data = try await cgi(path: "/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                                 params: ["songmid": mid,
                                          "pcachetime": String(Int(Date().timeIntervalSince1970 * 1000))])
        let lyricText = Data(base64Encoded: scStr(data, "lyric"))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let tlyricText = Data(base64Encoded: scStr(data, "trans"))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return .json(200, ["code": 200, "lyric": lyricText, "tlyric": tlyricText, "yrc": "",
                            "format": lyricText.isEmpty ? "none" : "lrc"])
    }

    private func songUrl(req: HttpRequest) async -> HttpResponse {
        let mid = req.string("mid").isEmpty ? req.string("id") : req.string("mid")
        guard !mid.isEmpty else { return .json(400, ["code": 400, "error": "mid required"]) }
        let quality = req.string("quality", "128")
        _ = await ensureCredential()
        let (url, loginRequired) = await resolvePlayUrl(mid: mid, quality: quality)
        if !url.isEmpty {
            return .json(200, ["code": 200, "mid": mid, "url": url, "preview": false,
                                "quality": quality, "reason": NSNull(), "restriction": NSNull()])
        }
        let preview = await previewUrl(mid: mid)
        if !preview.isEmpty {
            return .json(200, ["code": 200, "mid": mid, "url": preview, "preview": true,
                                "quality": "preview", "reason": NSNull(), "restriction": NSNull()])
        }
        return .json(200, ["code": 200, "mid": mid, "url": "", "preview": false,
                            "quality": quality, "reason": loginRequired ? "login" : "unavailable",
                            "restriction": NSNull()])
    }

    private func recommendPlaylists(req: HttpRequest) async -> HttpResponse {
        let limit = min(20, max(3, req.int("limit", 9)))
        do {
            let authed = await ensureCredential() != nil
            let param: [String: Any] = ["From": 0, "Size": limit]
            let data = try await (authed
                ? musicuAuth(module: "music.playlist.PlaylistSquare", method: "GetRecommendFeed", param: param)
                : musicuAnon(module: "music.playlist.PlaylistSquare", method: "GetRecommendFeed", param: param))
            let list = (data["List"] as? [[String: Any]] ?? []).compactMap {
                ($0["Playlist"] as? [String: Any])?["basic"] as? [String: Any]
            }
            return .json(200, ["code": 200, "source": "qq", "playlists": list.compactMap { qqPlaylist($0) }])
        } catch {
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "playlists": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 推荐歌单失败"])
        }
    }

    private func recommendNewSongs(req: HttpRequest) async -> HttpResponse {
        let limit = min(60, max(1, req.int("limit", 30)))
        let area = req.int("area", 5)
        do {
            let authed = await ensureCredential() != nil
            let param: [String: Any] = ["type": area]
            let data = try await (authed
                ? musicuAuth(module: "newsong.NewSongServer", method: "get_new_song_info", param: param)
                : musicuAnon(module: "newsong.NewSongServer", method: "get_new_song_info", param: param))
            let songs = (data["songlist"] as? [[String: Any]] ?? [])
            return .json(200, ["code": 200, "source": "qq",
                                "tracks": Array(songs.prefix(limit)).compactMap { qqTrack($0) }])
        } catch {
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "tracks": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 新歌速递失败"])
        }
    }

    private func playlistDetail(req: HttpRequest) async -> HttpResponse {
        let id = req.string("id")
        guard !id.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        do {
            let obj = try await cgi(path: "/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg",
                                    params: ["disstid": id, "type": "1", "json": "1", "utf8": "1",
                                             "onlysong": "0", "new_format": "1"])
            let cdlist = obj["cdlist"] as? [[String: Any]] ?? []
            guard let cd = cdlist.first else {
                return .json(200, ["code": 502, "source": "qq", "name": "", "cover": "",
                                    "tracks": [], "trackCount": 0, "error": "歌单不存在"])
            }
            let songs = cd["songlist"] as? [[String: Any]] ?? []
            let tracks = songs.compactMap { qqTrack($0) }
            return .json(200, ["code": 200, "source": "qq",
                                "id": scStrOrNum(cd, "disstid").isEmpty ? id : scStrOrNum(cd, "disstid"),
                                "name": scStr(cd, "dissname").isEmpty ? "QQ 歌单" : scStr(cd, "dissname"),
                                "cover": scStr(cd, "logo"),
                                "creator": ["nickname": qqFirstStr(cd, ["nickname", "nick"])],
                                "tracks": tracks, "trackCount": tracks.count])
        } catch let e as QQUpstreamError where e.code == 10 {
            // 算法歌单：匿名 CGI 只回 code 10，带凭证重读 uniform_get_Dissinfo。
            guard await ensureCredential() != nil else {
                return .json(200, ["code": 80120, "source": "qq", "name": "", "cover": "",
                                    "tracks": [], "trackCount": 0, "error": "歌单取不到（80120）"])
            }
            return await authenticatedPlaylistDetail(id: id)
        } catch {
            return .json(200, ["code": 502, "source": "qq", "name": "", "cover": "",
                                "tracks": [], "trackCount": 0, "error": "歌单取不到"])
        }
    }

    private func authenticatedPlaylistDetail(id: String) async -> HttpResponse {
        do {
            var allSongs: [[String: Any]] = []
            var total = 0
            var hasmore = 1
            var begin = 0
            var pages = 0
            var firstData: [String: Any] = [:]
            while hasmore == 1 && pages < 10 {
                let d = try await musicuAuth(module: "music.srfDissInfo.aiDissInfo", method: "uniform_get_Dissinfo",
                                             param: ["disstid": id, "userinfo": 1, "tag": 1, "orderlist": 1,
                                                     "song_begin": begin, "song_num": 1000,
                                                     "onlysonglist": 0, "enc_host_uin": ""])
                if pages == 0 { firstData = d }
                let songs = d["songlist"] as? [[String: Any]] ?? []
                if songs.isEmpty { break }
                allSongs.append(contentsOf: songs)
                total = scInt(d, "total_song_num")
                hasmore = scInt(d, "hasmore")
                begin += songs.count
                pages += 1
                if total > 0 && allSongs.count >= total { break }
            }
            let tracks = allSongs.compactMap { qqTrack($0) }
            return .json(200, ["code": 200, "source": "qq", "id": id,
                                "name": scStr(firstData, "dissname").isEmpty ? "QQ 歌单" : scStr(firstData, "dissname"),
                                "cover": scStr(firstData, "logo"),
                                "creator": ["nickname": qqFirstStr(firstData, ["nickname", "nick"])],
                                "tracks": tracks, "trackCount": tracks.count])
        } catch {
            return .json(200, ["code": 502, "source": "qq", "name": "", "cover": "",
                                "tracks": [], "trackCount": 0, "error": "歌单取不到"])
        }
    }

    private func userLikedSongs(req: HttpRequest) async -> HttpResponse {
        let limit = min(100, max(1, req.int("limit", 100)))
        guard let cred = await ensureCredential(), !scStr(cred, "encryptUin").isEmpty else {
            return .json(200, ["code": 401, "source": "qq", "tracks": [], "error": "先在卡片上扫码登录 QQ 音乐"])
        }
        do {
            let d = try await musicuAuth(module: "music.srfDissInfo.DissInfo", method: "CgiGetDiss",
                                         param: ["disstid": 0, "dirid": 201, "tag": true, "song_begin": 0,
                                                 "song_num": limit, "userinfo": true, "orderlist": true,
                                                 "enc_host_uin": scStr(cred, "encryptUin")])
            let songs = d["songlist"] as? [[String: Any]] ?? []
            return .json(200, ["code": 200, "source": "qq", "tracks": songs.compactMap { qqTrack($0) },
                                "total": scInt(d, "total_song_num")])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "source": "qq", "tracks": [], "error": "先在卡片上扫码登录 QQ 音乐"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "tracks": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 音乐失败"])
        }
    }

    private func userPlaylists() async -> HttpResponse {
        guard let cred = await ensureCredential() else {
            return .json(200, ["code": 401, "source": "qq", "playlists": [], "error": "先在卡片上扫码登录 QQ 音乐"])
        }
        do {
            var playlists: [[String: Any]] = []
            var seen = Set<String>()
            func add(_ items: [[String: Any]]) {
                for it in items {
                    if let p = qqPlaylist(it), let pid = p["id"] as? String, !seen.contains(pid) {
                        seen.insert(pid)
                        playlists.append(p)
                    }
                }
            }
            let own = try await musicuAuth(module: "music.musicasset.PlaylistBaseRead", method: "GetPlaylistByUin",
                                           param: ["uin": credentialMusicId(cred)])
            add(own["v_playlist"] as? [[String: Any]] ?? [])
            var offset = 0
            var hasmore = true
            var rounds = 0
            let encryptUin = scStr(cred, "encryptUin")
            if !encryptUin.isEmpty {
                while hasmore && rounds < 20 {
                    let fav = try await musicuAuth(module: "music.musicasset.PlaylistFavRead",
                                                   method: "CgiGetPlaylistFavInfo",
                                                   param: ["uin": encryptUin, "offset": offset, "size": 100])
                    let items = fav["v_list"] as? [[String: Any]] ?? []
                    if items.isEmpty { break }
                    add(items)
                    hasmore = (fav["hasmore"] as? NSNumber)?.boolValue ?? false
                    let total = scInt(fav, "total")
                    let next = offset + items.count
                    if next <= offset { break }
                    offset = next
                    rounds += 1
                    if total > 0 && offset >= min(total, 1000) { break }
                }
            }
            return .json(200, ["code": 200, "source": "qq", "playlists": playlists])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "source": "qq", "playlists": [], "error": "先在卡片上扫码登录 QQ 音乐"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "playlists": [], "error": (error as? QQUpstreamError)?.message ?? "取我的歌单失败"])
        }
    }

    private func userAlbums(req: HttpRequest) async -> HttpResponse {
        let limit = min(100, max(1, req.int("limit", 100)))
        let offset = max(0, req.int("offset", 0))
        guard let cred = await ensureCredential() else {
            return .json(200, ["code": 401, "source": "qq", "data": [], "error": "先在卡片上扫码登录 QQ 音乐"])
        }
        do {
            let obj = try await cgi(path: "/fav/fcgi-bin/fcg_get_profile_order_asset.fcg",
                                    params: ["ct": "20", "cid": "205360956", "userid": credentialMusicId(cred),
                                             "reqtype": "2", "sin": String(offset), "ein": String(offset + limit - 1),
                                             "format": "json"],
                                    referer: "https://y.qq.com/",
                                    headers: ["Cookie": credentialCookieHeader(cred)])
            let d = obj["data"] as? [String: Any] ?? [:]
            let albums = d["albumlist"] as? [[String: Any]] ?? []
            let hasMore = (d["hasmore"] as? NSNumber)?.boolValue
                ?? (d["has_more"] as? NSNumber)?.boolValue ?? false
            return .json(200, ["code": 200, "source": "qq", "data": albums.compactMap { qqUserAlbum($0) },
                                "hasMore": hasMore, "total": scInt(d, "totalalbum")])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "source": "qq", "data": [], "error": "先在卡片上扫码登录 QQ 音乐"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "data": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 音乐失败"])
        }
    }

    private func userDailySongs() async -> HttpResponse {
        guard await ensureCredential() != nil else {
            return .json(200, ["code": 401, "source": "qq", "tracks": [], "error": "登录 QQ 音乐后才有每日推荐"])
        }
        do {
            let d = try await musicuAuth(module: "music.srfDissInfo.aiDissInfo", method: "uniform_get_Dissinfo",
                                         param: ["dirid": 202, "optype": 3, "tag": 1, "userinfo": 0, "pic_dpi": 300])
            let songs = d["songlist"] as? [[String: Any]] ?? []
            return .json(200, ["code": 200, "source": "qq", "tracks": songs.compactMap { qqTrack($0) }])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "source": "qq", "tracks": [], "error": "登录 QQ 音乐后才有每日推荐"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "tracks": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 每日推荐失败"])
        }
    }

    private func recommendRadar(req: HttpRequest) async -> HttpResponse {
        let page = min(100, max(1, req.int("page", 1)))
        do {
            let authed = await ensureCredential() != nil
            let param: [String: Any] = ["Page": page, "ReqType": 0, "FavSongs": [], "EntranceSongs": []]
            let d = try await (authed
                ? musicuAuth(module: "music.recommend.TrackRelationServer", method: "GetRadarSong", param: param)
                : musicuAnon(module: "music.recommend.TrackRelationServer", method: "GetRadarSong", param: param))
            let songs = d["VecSongs"] as? [[String: Any]] ?? []
            let tracks = songs.compactMap { ($0["Track"] as? [String: Any]).flatMap(qqTrack) }
            return .json(200, ["code": 200, "source": "qq", "tracks": tracks])
        } catch {
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "tracks": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 雷达推荐失败"])
        }
    }

    private func radioCategories() async -> HttpResponse {
        do {
            let d = try await musicuAnon(module: "pf.radiosvr", method: "GetRadiolist",
                                         param: ["uin": "0"], withUin: true, readOnly: false)
            let groups = (d["radio_list"] as? [[String: Any]]) ?? (d["groups"] as? [[String: Any]]) ?? []
            var stations: [[String: Any]] = []
            for g in groups {
                let list = (g["list"] as? [[String: Any]]) ?? (g["radios"] as? [[String: Any]]) ?? []
                for it in list {
                    let name = qqFirstStr(it, ["title", "name"])
                    stations.append([
                        "id": scStrOrNum(it, "id"), "source": "qq",
                        "name": name.isEmpty ? "未命名电台" : name,
                        "cover": qqFirstStr(it, ["picurl", "picUrl", "pic"]),
                        "trackCount": 0,
                        "playCount": qqFirstInt(it, ["listenNum", "listenCount"]),
                        "creator": ["nickname": scStr(g, "title")],
                    ])
                }
            }
            return .json(200, ["code": 200, "source": "qq", "stations": stations])
        } catch {
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "stations": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 电台分类失败"])
        }
    }

    private func radioTracks(req: HttpRequest) async -> HttpResponse {
        let idStr = req.string("id")
        guard let id = Int(idStr), id > 0 else {
            return .json(400, ["code": 400, "error": "id required"])
        }
        guard await ensureCredential() != nil else {
            return .json(200, ["code": 401, "source": "qq", "tracks": [], "error": "QQ 电台收听需要登录（并可能需要会员）"])
        }
        do {
            if id == 99 {
                let d = try await musicuAuth(module: "music.radioProxy.MbTrackRadioSvr", method: "get_radio_track",
                                             param: ["id": 99, "firstplay": 1, "num": 15])
                let list = (d["tracks"] as? [[String: Any]] ?? [])
                return .json(200, ["code": 200, "source": "qq", "tracks": list.compactMap { qqTrack($0) }])
            }
            let d = try await musicuAuth(module: "pf.radiosvr", method: "GetRadiosonglist",
                                         param: ["id": id, "firstplay": 0, "num": 9])
            let list = (d["track_list"] as? [[String: Any]])
                ?? (d["tracks"] as? [[String: Any]])
                ?? (d["songs"] as? [[String: Any]]) ?? []
            return .json(200, ["code": 200, "source": "qq", "tracks": list.compactMap { qqTrack($0) }])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "source": "qq", "tracks": [], "error": "QQ 电台收听需要登录（并可能需要会员）"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "source": "qq",
                                "tracks": [], "error": (error as? QQUpstreamError)?.message ?? "QQ 电台失败"])
        }
    }

    private func playlistCreate(req: HttpRequest) async -> HttpResponse {
        guard await ensureCredential() != nil else {
            return .json(200, ["code": 401, "error": "先在卡片上扫码登录 QQ 音乐"])
        }
        var name = String(req.string("name").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        if name.count > 20 { name = String(name.prefix(20)) }
        guard !name.isEmpty else { return .json(400, ["code": 400, "error": "name required"]) }
        do {
            let d = try await musicuAuth(module: "music.musicasset.PlaylistBaseWrite", method: "AddPlaylist",
                                         param: ["dirName": name], readOnly: false)
            let result = d["result"] as? [String: Any] ?? [:]
            let retCode = d["retCode"] != nil ? scInt(d, "retCode") : scInt(result, "retCode")
            guard retCode == 0,
                  let tid = (result["tid"] as? NSNumber)?.intValue,
                  let dirId = (result["dirId"] as? NSNumber)?.intValue, dirId < 200 else {
                return .json(200, ["code": 502, "error": "QQ 建歌单失败"])
            }
            _ = try? await musicuAuth(module: "music.musicasset.PlaylistBaseRead", method: "GetPlaylistByUin",
                                      param: ["uin": credentialMusicId()])
            return .json(200, ["code": 200, "tid": String(tid), "dirId": String(dirId),
                                "playlist": ["id": String(tid), "dirId": String(dirId), "name": name]])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "error": "登录态已失效，重新扫码登录 QQ 音乐"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502,
                                "error": (error as? QQUpstreamError)?.message ?? "QQ 建歌单失败"])
        }
    }

    /// 批量查歌（内部用，也供 /song/batch）：每首一个 RPC，匿名 comm {ct:24, cv:0}。
    private func songBatchInternal(songs: [[String: Any]]) async throws -> [[String: Any]] {
        let calls = songs.map { s -> (module: String, method: String, param: [String: Any]) in
            var param: [String: Any] = ["song_type": 0, "song_mid": scStr(s, "mid")]
            if scInt(s, "id") > 0 { param["song_id"] = scInt(s, "id") }
            return (module: "music.pf_song_detail_svr", method: "get_song_detail_yqq", param: param)
        }
        let datas = try await musicuMulti(comm: ["ct": 24, "cv": 0], calls: calls)
        return datas.enumerated().map { (i, d) in
            let track = d["track_info"] as? [String: Any] ?? [:]
            let valid = scStr(track, "mid") == scStr(songs[i], "mid") && scInt(track, "id") > 0
            return ["index": i, "code": 200, "song": valid ? track : [:], "info": d]
        }
    }

    private func playlistTracks(req: HttpRequest) async -> HttpResponse {
        guard await ensureCredential() != nil else {
            return .json(200, ["code": 401, "error": "先在卡片上扫码登录 QQ 音乐"])
        }
        let body = req.jsonBody()
        var tid = 0
        if let n = Int(req.string("tid").isEmpty ? req.string("pid") : req.string("tid")), n > 0 { tid = n }
        if tid == 0, let n = (body["tid"] as? NSNumber)?.intValue, n > 0 { tid = n }
        if tid == 0, let n = (body["pid"] as? NSNumber)?.intValue, n > 0 { tid = n }
        guard tid > 0 else { return .json(400, ["code": 400, "error": "tid required"]) }
        var songs: [[String: Any]] = []
        if let arr = body["songs"] as? [[String: Any]] { songs = arr }
        else if let arr = body["picks"] as? [[String: Any]] { songs = arr }
        guard !songs.isEmpty else { return .json(400, ["code": 400, "error": "songs required"]) }
        var ids: [Int] = []
        var mids: [String] = []
        for s in songs {
            if let n = (s["id"] as? NSNumber)?.intValue, n > 0 { ids.append(n); mids.append("") }
            else if let n = (s["songId"] as? NSNumber)?.intValue, n > 0 { ids.append(n); mids.append("") }
            else if let m = s["mid"] as? String, !m.isEmpty { ids.append(0); mids.append(m) }
            else { ids.append(0); mids.append("") }
        }
        do {
            // 补数字 id：每批 20 首调 song/batch。
            var missing = ids.indices.filter { ids[$0] == 0 && !mids[$0].isEmpty }
            while !missing.isEmpty {
                let batch = Array(missing.prefix(20))
                let results = try await songBatchInternal(songs: batch.map { ["mid": mids[$0]] })
                for (j, idx) in batch.enumerated() where j < results.count {
                    if let song = results[j]["song"] as? [String: Any], scInt(song, "id") > 0 {
                        ids[idx] = scInt(song, "id")
                    }
                }
                let next = ids.indices.filter { ids[$0] == 0 && !mids[$0].isEmpty }
                if next.count == missing.count { break }
                missing = next
            }
            if ids.contains(0) {
                return .json(400, ["code": 400, "error": "有些曲目没有数字 songid，无法写入 QQ 歌单"])
            }
            let own = try await musicuAuth(module: "music.musicasset.PlaylistBaseRead",
                                           method: "GetPlaylistByUin",
                                           param: ["uin": credentialMusicId()])
            guard let vlist = own["v_playlist"] as? [[String: Any]],
                  let entry = vlist.first(where: { scStrOrNum($0, "tid") == String(tid) }),
                  let dirId = (entry["dirId"] as? NSNumber)?.intValue,
                  dirId < 200, scInt(entry, "dirType") == 0 else {
                return .json(200, ["code": 502, "error": "QQ 歌单不存在或不是自建歌单"])
            }
            var added = 0
            var idx = 0
            while idx < ids.count {
                let chunk = Array(ids[idx..<min(idx + 100, ids.count)])
                let vSongInfo = chunk.map { ["songId": $0, "songType": 0] }
                do {
                    let d = try await musicuAuth(module: "music.musicasset.PlaylistDetailWrite",
                                                 method: "AddSonglist",
                                                 param: ["dirId": dirId, "v_songInfo": vSongInfo],
                                                 readOnly: false)
                    let result = d["result"] as? [String: Any] ?? [:]
                    let retCode = d["retCode"] != nil ? scInt(d, "retCode") : scInt(result, "retCode")
                    guard retCode == 0 else {
                        return .json(200, ["code": 502, "added": added, "error": "QQ 写歌单失败"])
                    }
                    added += chunk.count
                } catch {
                    return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502, "added": added,
                                        "error": "QQ 写歌单失败" + (added > 0 ? "（前 \(added) 首已写入）" : "")])
                }
                idx += chunk.count
            }
            return .json(200, ["code": 200, "tid": tid, "added": added])
        } catch {
            if isCredentialRejection(error) {
                return .json(200, ["code": 401, "error": "登录态已失效，重新扫码登录 QQ 音乐"])
            }
            return .json(200, ["code": (error as? QQUpstreamError)?.code ?? 502,
                                "error": (error as? QQUpstreamError)?.message ?? "QQ 写歌单失败"])
        }
    }

    // MARK: - 分发

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/qq/".count))
        do {
            switch part {
            case "", "health":
                return health()
            case "status", "login/status":
                return await status()
            case "cached-profile":
                return .json(200, await cachedProfile())
            case "login/qr/key":
                return await loginQrKey(req: req)
            case "login/qr/create":
                return await loginQrCreate(req: req)
            case "login/qr/check":
                return await loginQrCheck(req: req)
            case "login/qr/cancel":
                cancelQrSession(key: req.string("key"))
                return .json(200, ["code": 200])
            case "logout":
                saveCredential(nil)
                for s in qrSessions.values { s.wsTask?.cancel(); s.driverTask?.cancel() }
                qrSessions.removeAll()
                return .json(200, ["code": 200, "loggedIn": false])
            case "search":
                return await search(req: req)
            case "lyric":
                return try await lyric(req: req)
            case "song/url":
                return await songUrl(req: req)
            case "recommend/playlists":
                return await recommendPlaylists(req: req)
            case "recommend/new-songs":
                return await recommendNewSongs(req: req)
            case "playlist/detail":
                return await playlistDetail(req: req)
            case "user/liked-songs":
                return await userLikedSongs(req: req)
            case "user/playlists":
                return await userPlaylists()
            case "user/albums":
                return await userAlbums(req: req)
            case "user/daily-songs":
                return await userDailySongs()
            case "recommend/radar":
                return await recommendRadar(req: req)
            case "radio/categories":
                return await radioCategories()
            case "radio/tracks":
                return await radioTracks(req: req)
            case "playlist/create":
                return await playlistCreate(req: req)
            case "playlist/tracks", "playlist/tracks/add":
                return await playlistTracks(req: req)
            default:
                return .json(404, ["code": 404, "error": "unknown qq api: \(part)"])
            }
        } catch {
            let msg = (error as? QQUpstreamError)?.message ?? error.localizedDescription
            return .json(502, ["code": 502, "error": msg])
        }
    }
}

/// Range 探测（CDN 兜底用）：GET Range bytes=0-0，200/206 算通。
private func qqProbeURL(_ urlString: String) async -> Bool {
    guard let url = URL(string: urlString) else { return false }
    do {
        let (_, resp) = try await Upstream.fetch(url, headers: ["Range": "bytes=0-0"], timeout: 5)
        return (200...299).contains(resp.statusCode) || resp.statusCode == 206
    } catch {
        return false
    }
}
