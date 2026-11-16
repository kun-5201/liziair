import Foundation
import CryptoKit

/// 汽水边车：qishui-music-api@0.2.2（MIT）的 Swift 移植。
/// 上游细节见 /tmp/qishui-bodian-details.md（逐字摘自包内 src/）。
/// 主服务路由与归一化见 specs/sidecars.md §4。
/// 注意：
/// - 读接口只需 client_token、无需 guard；账号读写需 ticket-guard（P-256 ECDSA + 手工 DER CSR）。
/// - 未登录只有 30 秒试听；只发未加密资源，最高只到 high。
/// - URLSession 默认跟随跳转，Node 侧 redirect: 'error'——此处不拦跳转（这些端点正常不跳转）。

struct QishuiError: Error {
    /// 库错误码：auth-required / not-playable / unavailable / network / invalid-response / unsupported。
    let code: String
    let message: String
    let upstreamCode: String?
}

/// URLSearchParams 式表单编码：字母数字与 *-._ 不编码，空格变 +，其余 %XX（大写 hex）。
func qsFormEncode(_ s: String) -> String {
    var out = ""
    for byte in s.utf8 {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F:
            out.append(Character(UnicodeScalar(byte)))
        case 0x20:
            out.append("+")
        default:
            out.append(String(format: "%%%02X", byte))
        }
    }
    return out
}

func qsFormEncodePairs(_ pairs: [(String, String)]) -> String {
    pairs.map { "\(qsFormEncode($0.0))=\(qsFormEncode($0.1))" }.joined(separator: "&")
}

final class QishuiService {
    private let session = SessionStore.shared

    // MARK: - 常量（src/protocol.cjs、src/client.cjs）

    private static let qsUA = "LunaOpenSDK/1.0.10"
    private static let qsPrefix = "/api/luna/v1/platform"
    private static let qsClientKey = "aw4bbxfujo741d09"
    private static let qsPlatformBase = "https://open.douyin.com/api/luna/v1/platform"
    private static let qsPublicBase = "https://open.qishui.com/api/luna/v1/platform"
    private static let authCodes: Set<Int> = [28001003, 28001007, 28001008, 10007]
    private static let retryableReads: Set<String> = ["/search/", "/playlist/detail/", "/media/mget/",
                                                      "/media/mcheck/", "/artist/detail/", "/artist/tracks/",
                                                      "/feed/mode/", "/feed/song-tab/"]
    private static let mediaHosts: Set<String> = ["365yg.com", "douyinvod.com", "douyinscdn.com", "bytefcdn.com",
                                                  "bytecdn.cn", "byteicdn.com", "ibytedtos.com", "pstatp.com",
                                                  "snssdk.com", "bytedance.com", "bytetos.com", "volcvideo.com",
                                                  "volccdn.com", "volces.com", "volcengineapi.com", "douyin.com",
                                                  "qishui.com", "zijieapi.com", "zjcdn.com"]

    private static let qsCommon: [(String, String)] = [
        ("aid", "765213"), ("app_id", "765213"), ("app_name", "byte_autoservice_lite"),
        ("version_code", "100010"), ("version_name", "1.0.10"), ("channel", "bydSong"),
        ("sdk_aid", "753999"), ("caller_name", "luna_open_sdk"), ("sdk_version_code", "100000100"),
        ("sdk_version_name", "0.0.1"), ("sdk_channel", "Test"), ("vehicle_type", "BYD"),
        ("device_brand", "BYD"), ("device_type", "BYD"), ("device_platform", "android"),
        ("resolution", "1920x1080"), ("os_version", "13"), ("ac", "wifi"),
    ]

    // MARK: - 设备与会话

    private var deviceCache: String?
    private var tokenEntry: String?
    private var pending: [String: QSPending] = [:]
    private var feedQueues: [String: QSFeedState] = [:]
    private var feedTotal = 0
    private var playlistCursors: [String: QSPlaylistCursor] = [:]

    private struct QSPending { var token: String; var qr: String; var expires: Date }
    private struct QSFeedState { var count: Int; var selectedAt: Int }
    private struct QSPlaylistCursor {
        var at: Date
        var positions: [Int: String]  // 已消费行数 → 游标
        var collection: [String: Any]?
    }

    /// deviceId：19 位纯数字，(randomBytes(8) BigUInt64BE % 9e18 + 1e18)。
    private func deviceId() -> String {
        if let d = deviceCache { return d }
        if let saved = session.sidecarAuth("qishui-device"), let d = saved["deviceId"] as? String,
           d.range(of: #"^\d{19}$"#, options: .regularExpression) != nil {
            deviceCache = d
            return d
        }
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { bytes[i] = UInt8.random(in: 0...255) }
        var value: UInt64 = 0
        for b in bytes { value = (value << 8) | UInt64(b) }
        let d = String(value % 9_000_000_000_000_000_000 + 1_000_000_000_000_000_000)
        session.saveSidecarAuth("qishui-device", ["deviceId": d, "createdAt": Int(Date().timeIntervalSince1970 * 1000)])
        deviceCache = d
        return d
    }

    /// 有效会话须同时有 ticket、guardKey、guardCert、guardTsSign、accessCode。
    private func loadSession() -> [String: Any]? {
        guard let s = session.sidecarAuth("qishui"),
              !scStr(s, "ticket").isEmpty, !scStr(s, "guardKey").isEmpty,
              !scStr(s, "guardCert").isEmpty, !scStr(s, "guardTsSign").isEmpty,
              !scStr(s, "accessCode").isEmpty else { return nil }
        return s
    }
    private func saveSession(_ s: [String: Any]) { session.saveSidecarAuth("qishui", s) }
    private func clearSession() { session.clearSidecarAuth("qishui") }

    // MARK: - 公共查询与通用请求（src/protocol.cjs、src/client.cjs）

    private func qishuiParams(deviceId: String) -> String {
        var pairs = Self.qsCommon
        pairs.append(contentsOf: [
            ("device_id", deviceId), ("did", deviceId), ("iid", deviceId),
            ("vehicle_id", "qishui-\(deviceId)"),
            ("_timestamp", String(Int(Date().timeIntervalSince1970))),
            ("_nonce", String(Int.random(in: 0...65535))),
        ])
        return qsFormEncodePairs(pairs)
    }

    /// checked(data)：code = err_no ?? data.error_code ?? 0；非零抛错，
    /// AUTH_CODES 为 auth-required，其余 unavailable，upstreamCode 为码的字符串。
    private static func checkQishuiResponse(_ obj: [String: Any]) throws -> [String: Any] {
        var code = 0
        if let n = obj["err_no"] as? NSNumber { code = n.intValue }
        else if let d = obj["data"] as? [String: Any], let n = d["error_code"] as? NSNumber { code = n.intValue }
        guard code == 0 else {
            let msg = scStr(obj, "err_msg").isEmpty ? (scStr((obj["data"] as? [String: Any]) ?? [:], "err_msg")) : scStr(obj, "err_msg")
            throw QishuiError(code: authCodes.contains(code) ? "auth-required" : "unavailable",
                              message: msg.isEmpty ? "汽水接口失败（\(code)）" : msg,
                              upstreamCode: String(code))
        }
        return obj
    }

    private func qsFetch(url: URL, headers: [String: String], method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await Upstream.fetch(url, headers: headers, timeout: 25, method: method, body: body)
        if resp.statusCode == 429 {
            throw QishuiError(code: "unavailable", message: "Qishui HTTP 429", upstreamCode: nil)
        }
        if resp.statusCode == 401 || resp.statusCode == 403 {
            throw QishuiError(code: "auth-required", message: "Qishui HTTP \(resp.statusCode)", upstreamCode: nil)
        }
        guard (200...299).contains(resp.statusCode) else {
            throw QishuiError(code: "network", message: "Qishui HTTP \(resp.statusCode)", upstreamCode: nil)
        }
        return (data, resp)
    }

    /// client_token：GET open.qishui.com …/client/token/get/?…&trigger_type=cold_start，单例缓存。
    private func clientToken() async throws -> String {
        if let t = tokenEntry, !t.isEmpty { return t }
        let urlStr = "\(Self.qsPublicBase)/client/token/get/?\(qishuiParams(deviceId: deviceId()))&trigger_type=cold_start"
        guard let url = URL(string: urlStr) else {
            throw QishuiError(code: "network", message: "client_token 请求构造失败", upstreamCode: nil)
        }
        let (data, _) = try await qsFetch(url: url, headers: ["user-agent": Self.qsUA])
        guard let obj = Upstream.jsonObject(data) else {
            throw QishuiError(code: "network", message: "client_token 返回无法解析", upstreamCode: nil)
        }
        let checked = try Self.checkQishuiResponse(obj)
        let d = (checked["data"] as? [String: Any]) ?? [:]
        guard let token = d["client_token"] as? String, !token.isEmpty else {
            throw QishuiError(code: "invalid-response", message: "client_token 缺失", upstreamCode: nil)
        }
        tokenEntry = token
        return token
    }

    private enum QSAuth {
        case `public`
        case session
        case credential([String: Any])
    }

    /// platform(path)：POST open.douyin.com/api/luna/v1/platform{path}?{公共查询}。
    /// body 平铺业务参数 + common_params（登录时含 user_id）；28001008 仅可重试路径重试一次。
    private func platform(path: String, body: [String: Any] = [:], auth: QSAuth = .public, attempt: Int = 0) async throws -> [String: Any] {
        let cred: [String: Any]?
        let devId: String
        switch auth {
        case .public:
            cred = nil
            devId = deviceId()
        case .session:
            guard let s = loadSession() else {
                throw QishuiError(code: "auth-required", message: "先在卡片上扫码登录汽水音乐", upstreamCode: nil)
            }
            cred = s
            devId = scStr(s, "deviceId").isEmpty ? deviceId() : scStr(s, "deviceId")
        case .credential(let c):
            cred = c
            devId = scStr(c, "deviceId").isEmpty ? deviceId() : scStr(c, "deviceId")
        }
        var fullBody = body
        if let c = cred, let uid = c["userId"] as? String, !uid.isEmpty {
            fullBody["common_params"] = ["user_id": uid]
        } else {
            fullBody["common_params"] = [:] as [String: Any]
        }
        guard let url = URL(string: "\(Self.qsPlatformBase)\(path)?\(qishuiParams(deviceId: devId))"),
              let bodyData = try? JSONSerialization.data(withJSONObject: fullBody) else {
            throw QishuiError(code: "network", message: "汽水请求构造失败", upstreamCode: nil)
        }
        var headers: [String: String] = ["user-agent": Self.qsUA, "content-type": "application/json"]
        if let c = cred {
            for (k, v) in try Self.guardHeaders(credential: c, path: path) { headers[k] = v }
        } else {
            headers["access-token"] = try await clientToken()
        }
        do {
            let (data, _) = try await qsFetch(url: url, headers: headers, method: "POST", body: bodyData)
            guard let obj = Upstream.jsonObject(data) else {
                throw QishuiError(code: "network", message: "汽水返回无法解析", upstreamCode: nil)
            }
            let checked = try Self.checkQishuiResponse(obj)
            guard let d = checked["data"] as? [String: Any] else {
                throw QishuiError(code: "invalid-response", message: "汽水返回缺 data", upstreamCode: nil)
            }
            return d
        } catch let e as QishuiError {
            if e.upstreamCode == "28001008", attempt == 0, Self.retryableReads.contains(path) {
                tokenEntry = nil
                return try await platform(path: path, body: body, auth: auth, attempt: 1)
            }
            throw e
        }
    }

    // MARK: - ticket-guard（src/protocol.cjs）

    /// der(tag, values...)：长度 <128 短形式；<256 为 0x81；否则 0x82 + 2 字节大端。
    private static func qsDer(_ tag: UInt8, _ values: Data...) -> Data {
        let value = values.reduce(Data(), +)
        var out = Data([tag])
        if value.count < 128 { out.append(UInt8(value.count)) }
        else if value.count < 256 { out.append(contentsOf: [0x81, UInt8(value.count)]) }
        else { out.append(contentsOf: [0x82, UInt8(value.count >> 8), UInt8(value.count & 0xff)]) }
        out.append(value)
        return out
    }

    /// createQishuiGuard：P-256 密钥对 + 手工 DER PKCS#10。
    /// subject RDN 顺序 CN=bd-ticket-guard（2.5.4.3）、OU=""（2.5.4.11）、O=""（2.5.4.10）；
    /// 版本 INTEGER 0；[0] 空；算法 OID 1.2.840.10045.4.3.2（无 parameters）；
    /// 签名 BIT STRING 首字节 0x00；csr = base64(PEM 全文)；guardKey = PKCS#8 PEM。
    private static func createQishuiGuard() throws -> (guardKey: String, csr: String) {
        let key = P256.Signing.PrivateKey()
        func rdn(id: UInt8, value: String) -> Data {
            let oid = qsDer(0x06, Data([0x55, 0x04, id]))
            let str = qsDer(0x0c, value.data(using: .utf8) ?? Data())
            return qsDer(0x31, qsDer(0x30, oid, str))
        }
        let subject = qsDer(0x30, rdn(id: 3, value: "bd-ticket-guard"), rdn(id: 11, value: ""), rdn(id: 10, value: ""))
        let info = qsDer(0x30, qsDer(0x02, Data([0])), subject, key.publicKey.derRepresentation, qsDer(0xa0))
        let alg = qsDer(0x30, qsDer(0x06, Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])))
        let sig = try key.signature(for: info).derRepresentation
        let request = qsDer(0x30, info, alg, qsDer(0x03, Data([0]), sig))
        let b64 = request.base64EncodedString()
        var pem = "-----BEGIN CERTIFICATE REQUEST-----\n"
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            pem += b64[i..<j] + "\n"
            i = j
        }
        pem += "-----END CERTIFICATE REQUEST-----\n"
        let keyB64 = key.derRepresentation.base64EncodedString()
        var keyPem = "-----BEGIN PRIVATE KEY-----\n"
        var k = keyB64.startIndex
        while k < keyB64.endIndex {
            let j = keyB64.index(k, offsetBy: 64, limitedBy: keyB64.endIndex) ?? keyB64.endIndex
            keyPem += keyB64[k..<j] + "\n"
            k = j
        }
        keyPem += "-----END PRIVATE KEY-----\n"
        return (keyPem, Data(pem.utf8).base64EncodedString())
    }

    /// qishuiGuardHeaders：content = ticket=&path=/api/luna/v1/platform{path}&timestamp=（秒）；
    /// req_sign 为 ECDSA P-256 + SHA-256（DER 编码 (r,s)，base64）；
    /// body JSON {ts_sign, req_content:"ticket,path,timestamp", req_sign, timestamp} 整体 base64。
    private static func guardHeaders(credential: [String: Any], path: String) throws -> [String: String] {
        guard let ticket = credential["ticket"] as? String, !ticket.isEmpty, ticket.count <= 16384,
              let guardKey = credential["guardKey"] as? String, !guardKey.isEmpty, guardKey.count <= 16384,
              let guardCert = credential["guardCert"] as? String, !guardCert.isEmpty, guardCert.count <= 16384,
              let guardTsSign = credential["guardTsSign"] as? String, !guardTsSign.isEmpty, guardTsSign.count <= 16384 else {
            throw QishuiError(code: "invalid-response", message: "invalid guard credential", upstreamCode: nil)
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: guardKey)
        } catch {
            throw QishuiError(code: "invalid-response", message: "invalid guard key", upstreamCode: nil)
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let content = "ticket=\(ticket)&path=\(qsPrefix)\(path)&timestamp=\(timestamp)"
        let sig = try key.signature(for: Data(content.utf8))
        let body: [String: Any] = ["ts_sign": guardTsSign, "req_content": "ticket,path,timestamp",
                                   "req_sign": sig.derRepresentation.base64EncodedString(), "timestamp": timestamp]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw QishuiError(code: "invalid-response", message: "guard 请求构造失败", upstreamCode: nil)
        }
        return ["access-token": ticket, "bd-ticket-guard-version": "1",
                "bd-ticket-guard-client-cert": guardCert,
                "bd-ticket-guard-client-data": bodyData.base64EncodedString()]
    }

    /// readQishuiGuard：base64 JSON {ticket, ts_sign, client_cert}；
    /// client_cert 含 -----BEGIN 时存 base64(PEM 文本)，否则原样。
    private static func readQishuiGuard(_ raw: String) throws -> (ticket: String, guardTsSign: String, guardCert: String) {
        guard !raw.isEmpty, raw.count <= 65536,
              let data = Data(base64Encoded: raw),
              let obj = Upstream.jsonObject(data),
              let ticket = obj["ticket"] as? String, !ticket.isEmpty, ticket.count <= 16384,
              let tsSign = obj["ts_sign"] as? String, !tsSign.isEmpty, tsSign.count <= 16384,
              let cert = obj["client_cert"] as? String, !cert.isEmpty, cert.count <= 16384 else {
            throw QishuiError(code: "invalid-response", message: "invalid guard data", upstreamCode: nil)
        }
        let guardCert = cert.contains("-----BEGIN") ? Data(cert.utf8).base64EncodedString() : cert
        return (ticket, tsSign, guardCert)
    }

    /// qishuiCredentialExpiry：>1e12 已是毫秒；>1e9 秒转毫秒；>0 相对秒数；否则默认 6 小时。
    private static func credentialExpiry(_ raw: Any?) throws -> Int {
        let value = scNum(raw)
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let expires: Int
        if value > 1_000_000_000_000 { expires = value }
        else if value > 1_000_000_000 { expires = value * 1000 }
        else if value > 0 { expires = nowMs + value * 1000 }
        else { expires = nowMs + 6 * 3600 * 1000 }
        guard expires > nowMs else {
            throw QishuiError(code: "invalid-response", message: "invalid credential expiry", upstreamCode: nil)
        }
        return expires
    }

    /// 头像归一化（spec §4.3）：只有 need_complete_url === true 的 urls 才是带签名完整地址；
    /// 字符串只接受路径非 / 且不以 /img/ 结尾的 http(s) 地址。
    private static func qsAvatarURL(_ raw: Any?) -> String {
        if let s = raw as? String {
            guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return "" }
            guard let url = URL(string: s), url.path != "/", !url.path.hasSuffix("/img/") else { return "" }
            return s
        }
        if let d = raw as? [String: Any],
           (d["need_complete_url"] as? NSNumber)?.boolValue == true,
           let urls = d["urls"] as? [String], let first = urls.first, !first.isEmpty {
            return first
        }
        return ""
    }

    /// 媒体 URL 校验（client.cjs §3.5）：https、无 userinfo、端口为空或 443、host 在 19 域名白名单内。
    private static func qsMediaURL(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return nil }
        for allowed in mediaHosts {
            if host == allowed || host.hasSuffix("." + allowed) { return raw }
        }
        return nil
    }

    // MARK: - 登录（src/auth.cjs）

    private static let qsQRParams: [(String, String)] = [
        ("aid", "1128"), ("client_key", "aw4bbxfujo741d09"),
        ("scope", "user_info,luna.openapi.platform.interaction,luna.openapi.platform.me_tab,luna.commerce.openapi_platform.vip_info"),
        ("state", ""), ("next", ""), ("jump_type", "native"),
        ("optional_scope_check", ""), ("optional_scope_uncheck", ""),
        ("customize_params", "{\"source\":\"pc_auth\",\"not_skip_confirm\":\"true\"}"),
        ("source_from", "native"), ("device_platform", "android"),
        ("app_identity", "82a0737a3f8d93d9958c8a7938bbc365"), // md5("com.luna.music.car")，实算值
        ("signature", "cf9024ea72d9c71813238b13ea107a3d"),
    ]

    /// login_qr_key：GET open.douyin.com/oauth/get_qrcode/；本地 key 为随机 16 字节 hex，内存 5 分钟。
    private func loginQrKey() async throws -> [String: Any] {
        let urlStr = "https://open.douyin.com/oauth/get_qrcode/?" + qsFormEncodePairs(Self.qsQRParams)
        guard let url = URL(string: urlStr) else {
            throw QishuiError(code: "network", message: "二维码请求构造失败", upstreamCode: nil)
        }
        let (data, _) = try await qsFetch(url: url, headers: ["user-agent": Self.qsUA])
        guard let obj = Upstream.jsonObject(data),
              let d = obj["data"] as? [String: Any],
              let token = d["token"] as? String, !token.isEmpty,
              let qrcode = d["qrcode"] as? String, !qrcode.isEmpty else {
            throw QishuiError(code: "invalid-response", message: "二维码返回缺字段", upstreamCode: nil)
        }
        let key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        pending[key] = QSPending(token: token, qr: qrcode, expires: Date().addingTimeInterval(300))
        return ["key": key, "qrimg": qrcode, "imageUrl": qrcode, "url": "https://open.douyin.com/oauth/get_qrcode/"]
    }

    private func loginQrCreate(key: String) throws -> [String: Any] {
        guard let p = pending[key], Date() < p.expires else {
            throw QishuiError(code: "auth-required", message: "二维码已过期，请重新获取", upstreamCode: nil)
        }
        return ["qrimg": p.qr, "imageUrl": p.qr]
    }

    /// 换 ticket：POST open-client.douyin.com/passport/open/get_access_ticket/
    /// （form body {access_code, open_id}，头 bd-ticket-guard-version: 1 + 首次 csr / 续期 cert；
    /// 响应头 bd-ticket-guard-server-data 经 readQishuiGuard 解析）。
    private func exchangeTicket(credential: [String: Any]) async throws -> [String: Any] {
        let (guardKey, csr) = try Self.createQishuiGuard()
        var headers: [String: String] = ["user-agent": Self.qsUA, "bd-ticket-guard-version": "1",
                                         "content-type": "application/x-www-form-urlencoded"]
        if let oldCert = credential["guardCert"] as? String, !oldCert.isEmpty {
            headers["bd-ticket-guard-client-cert"] = oldCert
        } else {
            headers["bd-ticket-guard-client-csr"] = csr
        }
        let body = qsFormEncodePairs([
            ("access_code", scStr(credential, "accessCode")),
            ("open_id", scStr(credential, "openId")),
        ])
        guard let url = URL(string: "https://open-client.douyin.com/passport/open/get_access_ticket/?aid=1128&client_key=aw4bbxfujo741d09&device_platform=android") else {
            throw QishuiError(code: "network", message: "换 ticket 请求构造失败", upstreamCode: nil)
        }
        let (data, resp) = try await qsFetch(url: url, headers: headers, method: "POST", body: Data(body.utf8))
        guard let obj = Upstream.jsonObject(data),
              let d = obj["data"] as? [String: Any],
              let access = d["access"] as? [String: Any] else {
            throw QishuiError(code: "invalid-response", message: "换 ticket 返回缺字段", upstreamCode: nil)
        }
        var serverData = ""
        for (k, v) in resp.allHeaderFields {
            if let ks = k as? String, ks.lowercased() == "bd-ticket-guard-server-data", let vs = v as? String {
                serverData = vs
                break
            }
        }
        let guardInfo = try Self.readQishuiGuard(serverData)
        var out = credential
        out["ticket"] = guardInfo.ticket
        out["guardTsSign"] = guardInfo.guardTsSign
        out["guardCert"] = guardInfo.guardCert
        out["guardKey"] = guardKey
        out["expiresAt"] = try Self.credentialExpiry(access["expires_time"])
        return out
    }

    /// login_qr_check：GET open.douyin.com/oauth/check_qrcode/；confirmed 后取 access_code 再换 ticket。
    private func loginQrCheck(key: String) async throws -> [String: Any] {
        guard let p = pending[key] else {
            return ["status": "expired", "code": 800, "message": "二维码已过期"]
        }
        guard Date() < p.expires else {
            pending.removeValue(forKey: key)
            return ["status": "expired", "code": 800, "message": "二维码已过期"]
        }
        let urlStr = "https://open.douyin.com/oauth/check_qrcode/?" + qsFormEncodePairs(Self.qsQRParams + [
            ("token", p.token), ("timestamp", String(Int(Date().timeIntervalSince1970 * 1000))),
        ])
        guard let url = URL(string: urlStr) else {
            throw QishuiError(code: "network", message: "扫码状态请求构造失败", upstreamCode: nil)
        }
        let (data, _) = try await qsFetch(url: url, headers: ["user-agent": Self.qsUA])
        guard let obj = Upstream.jsonObject(data), let d = obj["data"] as? [String: Any] else {
            throw QishuiError(code: "invalid-response", message: "扫码状态返回无法解析", upstreamCode: nil)
        }
        let status = scStr(d, "status")
        switch status {
        case "new": return ["status": "waiting", "code": 801, "message": "等待扫码"]
        case "scanned": return ["status": "scanned", "code": 802, "message": "已扫码，等待确认"]
        case "expired":
            pending.removeValue(forKey: key)
            return ["status": "expired", "code": 800, "message": "二维码已过期"]
        case "refused":
            throw QishuiError(code: "auth-required", message: "用户拒绝了登录", upstreamCode: nil)
        case "confirmed":
            let code = scStr(d, "code").isEmpty ? scStr(d, "auth_code") : scStr(d, "code")
            let qStr = "\(Self.qsPublicBase)/access/code/get/?\(qishuiParams(deviceId: deviceId()))&auth_code=\(qsFormEncode(code))"
            guard let qURL = URL(string: qStr) else {
                throw QishuiError(code: "network", message: "取 access_code 请求构造失败", upstreamCode: nil)
            }
            let (codeData, _) = try await qsFetch(url: qURL, headers: ["user-agent": Self.qsUA])
            guard let codeObj = Upstream.jsonObject(codeData),
                  let cd = codeObj["data"] as? [String: Any],
                  let accessCode = cd["access_code"] as? String, !accessCode.isEmpty,
                  let openId = cd["open_id"] as? String else {
                throw QishuiError(code: "invalid-response", message: "取 access_code 返回缺字段", upstreamCode: nil)
            }
            var cred: [String: Any] = ["deviceId": deviceId(), "accessCode": accessCode, "openId": openId]
            cred = try await exchangeTicket(credential: cred)
            // Node 是取落盘 current.user；check 时 user 可能为空，这里多调一次 getUser 补画像。
            saveSession(cred)
            if let user = try? await getUser(credential: cred) {
                cred["userId"] = user["id"]
                cred["user"] = user
                saveSession(cred)
            }
            pending.removeValue(forKey: key)
            return ["status": "confirmed", "code": 803, "message": "登录成功"]
        default:
            throw QishuiError(code: "invalid-response", message: "未知扫码状态：\(status)", upstreamCode: nil)
        }
    }

    /// getUser：/me/info/ guard 头；id 校验；昵称/头像/会员按 spec §4.3 取。
    private func getUser(credential: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await platform(path: "/me/info/", auth: credential.map { .credential($0) } ?? .session)
        guard let info = data["my_info"] as? [String: Any], !scStr(info, "id").isEmpty else {
            throw QishuiError(code: "invalid-response", message: "汽水用户信息缺 id", upstreamCode: nil)
        }
        let mediumAvatar = Self.qsAvatarURL(info["medium_avatar_url"])
        let avatar = mediumAvatar.isEmpty ? Self.qsAvatarURL(info["avatar_url"]) : mediumAvatar
        return ["id": scStr(info, "id"),
                "nickname": scStr(info, "nickname"),
                "avatar": avatar,
                "isVip": (info["is_vip"] as? NSNumber)?.boolValue == true]
    }

    private func status() async -> [String: Any] {
        guard var cred = loadSession() else { return ["loggedIn": false] }
        if let exp = cred["expiresAt"] as? Int, exp < Int(Date().timeIntervalSince1970 * 1000) + 3600000 {
            do {
                let qStr = "\(Self.qsPublicBase)/access/code/refresh/?\(qishuiParams(deviceId: scStr(cred, "deviceId")))&access_code=\(qsFormEncode(scStr(cred, "accessCode")))"
                guard let qURL = URL(string: qStr) else { throw QishuiError(code: "network", message: "续期请求构造失败", upstreamCode: nil) }
                let (data, _) = try await qsFetch(url: qURL, headers: ["user-agent": Self.qsUA])
                guard let obj = Upstream.jsonObject(data),
                      let cd = obj["data"] as? [String: Any],
                      let accessCode = cd["access_code"] as? String else {
                    throw QishuiError(code: "invalid-response", message: "续期返回缺 access_code", upstreamCode: nil)
                }
                cred["accessCode"] = accessCode
                cred = try await exchangeTicket(credential: cred)
                saveSession(cred)
            } catch let e as QishuiError {
                if e.code == "auth-required", e.upstreamCode != nil {
                    clearSession()
                    return ["loggedIn": false]
                }
                return ["loggedIn": true, "stale": true, "user": cred["user"] ?? [:], "uid": cred["userId"] ?? ""]
            } catch {
                return ["loggedIn": true, "stale": true, "user": cred["user"] ?? [:], "uid": cred["userId"] ?? ""]
            }
        }
        do {
            let user = try await getUser(credential: cred)
            if scStr(user, "id") != scStr(cred, "userId") {
                clearSession()
                throw QishuiError(code: "auth-required", message: "汽水账号已变化", upstreamCode: nil)
            }
            cred["userId"] = user["id"]
            cred["user"] = user
            saveSession(cred)
            return ["loggedIn": true, "user": user, "uid": user["id"] ?? ""]
        } catch let e as QishuiError {
            if e.code == "auth-required", e.upstreamCode != nil {
                clearSession()
                return ["loggedIn": false]
            }
            return ["loggedIn": true, "stale": true, "user": cred["user"] ?? [:], "uid": cred["userId"] ?? ""]
        } catch {
            return ["loggedIn": true, "stale": true, "user": cred["user"] ?? [:], "uid": cred["userId"] ?? ""]
        }
    }

    // MARK: - 业务 op（src/catalog.cjs、src/feed.cjs、src/playback.cjs、src/library.cjs）

    private func search(query: String, type: String, limit: Int, offset: Int) async throws -> [String: Any] {
        if query.isEmpty { return ["items": [], "total": 0, "hasMore": false, "nextOffset": offset] }
        var cursor = offset
        var items: [[String: Any]] = []
        var lastMore = false
        let searchId = UUID().uuidString
        while items.count < limit {
            let data = try await platform(path: "/search/", body: [
                "q": query, "cursor": String(cursor), "search_id": searchId, "from_search_id": searchId,
                "search_method": "input", "search_type": type, "search_scene": "normal",
                "scene_name": "search", "ab_param": "", "last_viewed_media": [:] as [String: Any],
            ])
            guard let groups = data["result_groups"] as? [[String: Any]] else {
                throw QishuiError(code: "invalid-response", message: "汽水搜索返回缺 result_groups", upstreamCode: nil)
            }
            let group = groups.first { scStr($0, "id") == "\(type)s" } ?? groups.first ?? [:]
            let rows = (group["data"] as? [[String: Any]]) ?? []
            let batch = rows.compactMap { ($0["entity"] as? [String: Any])?[type] as? [String: Any] }
            let remaining = limit - items.count
            let more = batch.count > remaining || (group["has_more"] as? NSNumber)?.boolValue == true
            lastMore = more
            items.append(contentsOf: batch.prefix(remaining))
            if batch.isEmpty || !more || items.count >= limit { break }
            guard let next = group["next_cursor"] as? NSNumber, next.intValue > cursor else {
                throw QishuiError(code: "invalid-response", message: "Search cursor did not advance", upstreamCode: nil)
            }
            cursor = next.intValue
        }
        return ["items": type == "track" ? items.map { Self.qishuiTrack($0) } : items,
                "total": items.count, "hasMore": lastMore && !items.isEmpty, "nextOffset": offset + items.count]
    }

    private func songDetail(id: String) async throws -> [String: Any] {
        let data = try await platform(path: "/media/mget/", body: [
            "media_list": [["id": id, "type": "track"]], "card_context": [:] as [String: Any],
        ])
        guard let list = data["media_list"] as? [[String: Any]] else {
            throw QishuiError(code: "invalid-response", message: "汽水歌曲详情缺 media_list", upstreamCode: nil)
        }
        for item in list {
            let mid = String(item["media_id"] as? Int ?? 0)
            let tid = scStr(((item["track_entity"] as? [String: Any])?["base_info"] as? [String: Any]) ?? [:], "id")
            guard mid == id || tid == id else { continue }
            guard let track = item["track_entity"] as? [String: Any] else {
                throw QishuiError(code: "not-playable", message: "汽水歌曲不可播", upstreamCode: nil)
            }
            return track
        }
        throw QishuiError(code: "not-playable", message: "汽水未找到该歌曲", upstreamCode: nil)
    }

    /// audio：无独立端点，先 song_detail 拿 track，再 resolveAudio（full 再 preview）。
    private func audio(id: String, quality req: String) async throws -> [String: Any] {
        let track = try await songDetail(id: id)
        return try await resolveAudio(track: track, requested: req)
    }

    private func resolveAudio(track: [String: Any], requested req: String) async throws -> [String: Any] {
        guard let player = track["player_info"] as? [String: Any] else {
            throw QishuiError(code: "not-playable", message: "Qishui returned no player information", upstreamCode: nil)
        }
        let levels: [String: String] = ["medium": "standard", "higher": "high", "highest": "high",
                                         "lossless": "lossless", "hi_res": "hires"]
        func rank(_ q: String) -> Int { ["standard", "high", "lossless", "hires"].firstIndex(of: q) ?? -1 }
        func encrypted(_ item: [String: Any]) -> Bool {
            let ei = (item["encrypt_info"] as? [String: Any]) ?? [:]
            return (ei["encrypt"] as? NSNumber)?.boolValue == true
                || (ei["spade_a"] as? NSNumber)?.boolValue == true
                || item["PlayAuth"] != nil || scInt(item, "Encrypt") != 0
        }
        for variant in ["full", "preview"] {
            guard let info = (player[variant] as? [String: Any])?["video_model_info"] as? [String: Any] else { continue }
            var candidates: [(url: String, quality: String, bitrate: Int)] = []
            var skipped = false
            func add(_ raw: String?, quality: String, bitrate: Int) {
                guard let raw = raw, let url = Self.qsMediaURL(raw) else { skipped = true; return }
                candidates.append((url, levels[quality] ?? "standard", bitrate))
            }
            if let modelRaw = info["video_model"] {
                let model: [String: Any]?
                if let s = modelRaw as? String { model = Upstream.jsonObject(Data(s.utf8)) }
                else { model = modelRaw as? [String: Any] }
                guard let m = model else {
                    throw QishuiError(code: "invalid-response", message: "Invalid Qishui player model", upstreamCode: nil)
                }
                for item in (m["video_list"] as? [[String: Any]]) ?? [] {
                    if encrypted(item) || scStr(item, "main_url").isEmpty { continue }
                    let meta = (item["video_meta"] as? [String: Any]) ?? [:]
                    add(scStr(item, "main_url"), quality: scStr(meta, "quality"), bitrate: scInt(meta, "bitrate"))
                }
            }
            if candidates.isEmpty, let playInfo = info["url_player_info"] as? String, let url = Self.qsMediaURL(playInfo) {
                let (data, _) = try await qsFetch(url: URL(string: url)!, headers: ["user-agent": Self.qsUA])
                guard let obj = Upstream.jsonObject(data) else {
                    throw QishuiError(code: "invalid-response", message: "Qishui PlayInfoList is missing", upstreamCode: nil)
                }
                let list = (((obj["Result"] as? [String: Any])?["Data"] as? [String: Any])?["PlayInfoList"] as? [[String: Any]])
                    ?? ((obj["data"] as? [String: Any])?["PlayInfoList"] as? [[String: Any]])
                    ?? (obj["PlayInfoList"] as? [[String: Any]])
                guard let list = list else {
                    throw QishuiError(code: "invalid-response", message: "Qishui PlayInfoList is missing", upstreamCode: nil)
                }
                for item in list {
                    if encrypted(item) || scStr(item, "MainPlayUrl").isEmpty { continue }
                    add(scStr(item, "MainPlayUrl"), quality: scStr(item, "Quality"), bitrate: scInt(item, "Bitrate"))
                }
            } else if candidates.isEmpty, info["url_player_info"] != nil { skipped = true }
            if candidates.isEmpty {
                if skipped {
                    throw QishuiError(code: "invalid-response", message: "Untrusted Qishui media host", upstreamCode: nil)
                }
                continue
            }
            let allowed = candidates.filter { rank($0.quality) <= rank(req) }
            let chosen = (allowed.isEmpty ? candidates : allowed).sorted {
                rank($0.quality) != rank($1.quality) ? rank($0.quality) > rank($1.quality) : $0.bitrate > $1.bitrate
            }[0]
            var out: [String: Any] = ["url": chosen.url, "quality": chosen.quality,
                                      "fetchedAt": Int(Date().timeIntervalSince1970 * 1000),
                                      "preview": variant == "preview"]
            if let exp = info["expire_at"] as? NSNumber, exp.doubleValue > Date().timeIntervalSince1970 {
                out["expiresAt"] = exp.intValue * 1000
            }
            if variant == "preview" {
                let start = scInt(((player["preview"] as? [String: Any])?["duration"] as? [String: Any]) ?? [:], "start_ms")
                if start > 0 { out["clipStartMs"] = start }
            }
            return out
        }
        throw QishuiError(code: "unsupported", message: "Qishui returned protected audio only; decryption is disabled", upstreamCode: nil)
    }

    /// lyrics：复用 song_detail 取 display_info.lyric_info；lyric_entity.content 的路径包内没找到——
    /// 按 sidecars.md §4.5 的归一化层记录，取 lyrics.lyric_entity.content。
    private func lyrics(id: String) async throws -> [String: Any] {
        let track = try await songDetail(id: id)
        let display = (track["display_info"] as? [String: Any]) ?? [:]
        guard let lyricInfo = display["lyric_info"] as? [String: Any] else { return [:] }
        return lyricInfo
    }

    private func feedModes() async throws -> [[String: Any]] {
        let data = try await platform(path: "/feed/mode/")
        guard let blocks = data["feed_mode_block"] as? [[String: Any]] else {
            throw QishuiError(code: "invalid-response", message: "Qishui feed modes are missing", upstreamCode: nil)
        }
        var out: [[String: Any]] = []
        for block in blocks {
            for item in (block["feed_mode"] as? [[String: Any]]) ?? [] {
                guard let mode = (item["entity"] as? [String: Any])?["feed_mode"] as? [String: Any],
                      let sid = (mode["scene_mode"] as? [String: Any])?["scene_mode_id"] else { continue }
                out.append(["id": String(describing: sid), "name": scStr(mode, "text"),
                            "group": scStr(block, "title"), "coverUrl": scStr(mode, "url_info")])
            }
        }
        return out
    }

    private func feed(scene: String?, preference: String?, queue: String, first: Bool, count: Int) async throws -> [String: Any] {
        if let pref = preference {
            guard pref.range(of: #"^[a-z][a-z_]{0,31}$"#, options: .regularExpression) != nil else {
                throw QishuiError(code: "invalid-response", message: "Invalid preference", upstreamCode: nil)
            }
            if scene != nil { throw QishuiError(code: "invalid-response", message: "Scene and preference are mutually exclusive", upstreamCode: nil) }
        }
        if let scene = scene {
            guard scene.range(of: #"^\d+$"#, options: .regularExpression) != nil, Int(scene) != nil else {
                throw QishuiError(code: "invalid-response", message: "Invalid scene", upstreamCode: nil)
            }
        }
        let key = "\(queue):\(scene ?? preference ?? "default")"
        let state: QSFeedState
        if first || feedQueues[key] == nil { state = QSFeedState(count: 0, selectedAt: Int(Date().timeIntervalSince1970 * 1000)) }
        else { state = feedQueues[key]! }
        feedTotal += 1
        let feedPref: [String: Any] = ["scene_mode_id": scene == nil ? NSNull() : (Int(scene!) ?? 0),
                                       "scene_mode_select_time": scene == nil ? NSNull() : state.selectedAt,
                                       "preference_mode": preference ?? NSNull(),
                                       "total_request_count": feedTotal,
                                       "preference_mode_request_count": state.count + 1,
                                       "current_mode_request_count": state.count + 1]
        let data = try await platform(path: "/feed/song-tab/", body: [
            "played_media": [], "is_first_request": state.count == 0,
            "with_client_cache": state.count != 0, "is_did_first_request": false, "count": count,
            "feed_preference": feedPref,
        ])
        guard let items = data["items"] as? [[String: Any]] else {
            throw QishuiError(code: "invalid-response", message: "Qishui feed items are missing", upstreamCode: nil)
        }
        var newState = state
        newState.count += 1
        feedQueues[key] = newState
        return ["items": items.filter { scStr($0, "type").isEmpty || scStr($0, "type") == "track" }.map { Self.qishuiTrack($0) },
                "hasMore": (data["has_more"] as? NSNumber)?.boolValue == true]
    }

    private func userPlaylists(limit: Int, offset: Int) async throws -> [String: Any] {
        var items: [[String: Any]] = []
        for (path, owned) in [("/me/playlist/", true), ("/me/collection/mixed/", false)] {
            var cursor = ""
            var page = 0
            while true {
                let data = try await platform(path: path, body: [
                    "count": 100, "cursor": cursor, "item_types": ["playlist"],
                ], auth: .session)
                let rows = ((data["playlists"] as? [[String: Any]])
                    ?? (data["playlist_list"] as? [[String: Any]])
                    ?? (data["mixed_collections"] as? [[String: Any]]) ?? [])
                for row in rows {
                    let playlist = (row["playlist"] as? [String: Any]) ?? row
                    if let base = playlist["base_info"] as? [String: Any], !scStr(base, "id").isEmpty {
                        var p = playlist
                        p["isOwned"] = owned
                        items.append(p)
                    }
                }
                if (data["has_more"] as? NSNumber)?.boolValue != true { break }
                let next = scStr(data, "next_cursor")
                if next.isEmpty || rows.isEmpty || page >= 499 {
                    throw QishuiError(code: "invalid-response", message: "Account playlist cursor did not advance", upstreamCode: nil)
                }
                cursor = next
                page += 1
            }
        }
        var seen = Set<String>()
        let unique = items.filter { p in
            let id = String(describing: ((p["base_info"] as? [String: Any])?["id"] ?? ""))
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        let slice = Array(unique.dropFirst(offset).prefix(limit))
        return ["items": slice.map { Self.qishuiPlaylist($0) }, "total": unique.count,
                "nextOffset": offset + min(limit, max(0, unique.count - offset)),
                "hasMore": offset + limit < unique.count]
    }

    private func likedPlaylistId() async throws -> String? {
        var cursor = ""
        var page = 0
        while true {
            let data = try await platform(path: "/me/playlist/", body: ["count": 100, "cursor": cursor], auth: .session)
            let rows = ((data["playlists"] as? [[String: Any]]) ?? (data["playlist_list"] as? [[String: Any]]) ?? [])
            for row in rows {
                let base = (row["base_info"] as? [String: Any]) ?? [:]
                if scInt(base, "type") == 1, !scStr(base, "id").isEmpty { return scStr(base, "id") }
            }
            if (data["has_more"] as? NSNumber)?.boolValue != true { break }
            let next = scStr(data, "next_cursor")
            if next.isEmpty || rows.isEmpty || page >= 19 { break }
            cursor = next
            page += 1
        }
        return nil
    }

    private func likedSongs(limit: Int, offset: Int) async throws -> [String: Any] {
        guard let pid = try await likedPlaylistId() else {
            throw QishuiError(code: "not-playable", message: "未找到我喜欢歌单", upstreamCode: nil)
        }
        let data = try await platform(path: "/playlist/detail/", body: [
            "playlist_id": pid, "owner_id": "", "count": 100, "cursor": "0", "type": 1,
        ])
        let rows = ((data["media_entities"] as? [[String: Any]]) ?? (data["media_list"] as? [[String: Any]]) ?? [])
        var ids: [String] = []
        for row in rows {
            let id = scStr(((row["track_entity"] as? [String: Any])?["base_info"] as? [String: Any]) ?? [:], "id")
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        let slice = Array(ids.dropFirst(offset).prefix(limit))
        return ["ids": slice, "whole": slice.count == ids.count, "total": ids.count]
    }

    /// playlistPage（catalog.cjs）：cursor 从 '0' 起、每页 count 100、type null；
    /// 游标记忆 TTL 5 分钟、最多 32 个歌单、key `${id}:${ownerId}`、账号切换时清空。
    private func playlistPage(id: String, ownerId: String, limit: Int, offset: Int) async throws -> [String: Any] {
        let key = "\(id):\(ownerId)"
        let mem = playlistCursors[key]
        var cursor = "0"
        var consumed = 0
        if let m = mem, Date().timeIntervalSince(m.at) < 300 {
            if let c = m.positions[offset] { cursor = c; consumed = offset }
        }
        var items: [[String: Any]] = []
        var collection: [String: Any]? = mem?.collection
        var seen: Set<String> = [cursor]
        var pages = 0
        var hasMore = false
        while items.count < limit {
            let data = try await platform(path: "/playlist/detail/", body: [
                "playlist_id": id, "owner_id": ownerId, "count": 100, "cursor": cursor, "type": NSNull(),
            ])
            if collection == nil { collection = data["playlist"] as? [String: Any] }
            guard let batch = data["media_entities"] as? [[String: Any]] else {
                throw QishuiError(code: "invalid-response", message: "汽水歌单缺 media_entities", upstreamCode: nil)
            }
            let start = max(0, offset - consumed)
            items.append(contentsOf: batch.dropFirst(start).prefix(limit - items.count).map { Self.qishuiTrack($0) })
            consumed += batch.count
            let next = scStr(data, "next_cursor")
            let upstreamMore = (data["has_more"] as? NSNumber)?.boolValue == true
            hasMore = (consumed > offset + items.count) || upstreamMore
            pages += 1
            if !upstreamMore || items.count >= limit { break }
            if batch.isEmpty || next.isEmpty || seen.contains(next) {
                throw QishuiError(code: "invalid-response", message: "Playlist cursor did not advance", upstreamCode: nil)
            }
            if pages >= 500 { throw QishuiError(code: "invalid-response", message: "Playlist page limit reached", upstreamCode: nil) }
            seen.insert(next)
            cursor = next
            playlistCursors[key] = QSPlaylistCursor(at: Date(), positions: [consumed: cursor], collection: collection)
            if playlistCursors.count > 32 { playlistCursors.removeValue(forKey: playlistCursors.keys.first!) }
        }
        return ["items": items, "collection": collection ?? [:],
                "hasMore": hasMore && !items.isEmpty, "nextOffset": offset + items.count]
    }

    private func artistDetail(id: String) async throws -> [String: Any] {
        let data = try await platform(path: "/artist/detail/", body: ["artist_id": id])
        return (data["artist_info"] as? [String: Any]) ?? [:]
    }

    private func artistSongs(id: String, limit: Int, offset: Int) async throws -> [String: Any] {
        let data = try await platform(path: "/artist/tracks/", body: ["artist_id": id, "count": 50, "cursor": "0"])
        let tracks = ((data["tracks"] as? [[String: Any]]) ?? []).map { Self.qishuiTrack($0) }
        let slice = Array(tracks.dropFirst(offset).prefix(limit))
        return ["items": slice, "total": tracks.count,
                "nextOffset": min(offset + limit, tracks.count), "hasMore": offset + limit < tracks.count]
    }

    private func recentPlayed(limit: Int, offset: Int) async throws -> [String: Any] {
        var items: [[String: Any]] = []
        var cursor = ""
        var page = 0
        while true {
            let data = try await platform(path: "/me/recent-played/", body: [
                "count": 100, "cursor": cursor, "media_type": "track", "scene": "me_tab",
            ], auth: .session)
            let rows = ((data["recent_played"] as? [[String: Any]]) ?? (data["items"] as? [[String: Any]]) ?? [])
            for row in rows {
                var t = Self.qishuiTrack(row)
                let ts = scInt(row, "play_start_timestamp")
                if ts > 0 { t["playedAt"] = ts > 1_000_000_000_000 ? ts : ts * 1000 }
                items.append(t)
            }
            if (data["has_more"] as? NSNumber)?.boolValue != true { break }
            let next = scStr(data, "next_cursor")
            if next.isEmpty || rows.isEmpty || page >= 499 { break }
            cursor = next
            page += 1
        }
        let slice = Array(items.dropFirst(offset).prefix(limit))
        return ["items": slice, "total": items.count,
                "nextOffset": offset + min(limit, max(0, items.count - offset)), "hasMore": offset + limit < items.count]
    }

    private func checkTracks(ids: [String]) async throws -> [[String: Any]] {
        guard ids.count <= 100 else {
            throw QishuiError(code: "invalid-response", message: "check_tracks 最多 100 个 id", upstreamCode: nil)
        }
        let data = try await platform(path: "/media/mcheck/", body: [
            "media_list": ids.map { ["id": $0, "type": "track"] },
        ])
        let list = (data["media_status_list"] as? [[String: Any]]) ?? []
        return list.map { row in
            let risk = (row["risk_info"] as? [String: Any]) ?? [:]
            return ["id": scStr(row, "id"), "riskResult": scInt(risk, "risk_result"),
                    "status": scInt(risk, "status")]
        }
    }

    // MARK: - 归一化（spec §4.3）

    /// pickCover：template_prefix 存在时加 `~<prefix>-<template>` 后缀；
    /// template 为空时用 `~<prefix>-resize:480:480.image`。
    private static func qsPickCover(_ raw: [String: Any]) -> String {
        guard let prefix = raw["template_prefix"] as? String, !prefix.isEmpty else { return "" }
        let template = scStr(raw, "template")
        if template.isEmpty { return "\(prefix)~\(prefix)-resize:480:480.image" }
        return "\(prefix)~\(prefix)-\(template)"
    }

    private static func qishuiTrack(_ raw: [String: Any]) -> [String: Any] {
        let track = (raw["track_entity"] as? [String: Any])
            ?? ((raw["entity"] as? [String: Any])?["media"] as? [String: Any])?["track_entity"] as? [String: Any]
            ?? ((raw["entity"] as? [String: Any])?["track"] as? [String: Any])
            ?? (raw["track"] as? [String: Any]) ?? raw
        let base = (track["base_info"] as? [String: Any]) ?? [:]
        let rel = (track["related_info"] as? [String: Any]) ?? [:]
        let display = (track["display_info"] as? [String: Any]) ?? [:]
        let artists = ((rel["artist_links"] as? [[String: Any]]) ?? []).compactMap { scStr($0, "name") }
        let album = ((rel["album_link"] as? [String: Any]) ?? [:])
        let cover = qsPickCover((display["cover"] as? [String: Any]) ?? [:])
        var out: [String: Any] = [
            "id": scStr(base, "id").isEmpty ? scStr(track, "id") : scStr(base, "id"),
            "name": scStr(base, "name"), "artists": artists,
            "album": scStr(album, "name"), "albumId": scStr(album, "id"),
            "cover": cover, "duration": scInt(base, "duration_ms"), "fee": 0,
        ]
        if let player = track["player_info"] { out["player_info"] = player }
        if let disp = track["display_info"] { out["display_info"] = disp }
        return out
    }

    private static func qishuiPlaylist(_ raw: [String: Any]) -> [String: Any] {
        let base = (raw["base_info"] as? [String: Any]) ?? [:]
        let display = (raw["display_info"] as? [String: Any]) ?? [:]
        let cover = qsPickCover((display["cover"] as? [String: Any]) ?? [:])
        return ["id": scStr(base, "id"), "name": scStr(base, "name"), "cover": cover,
                "trackCount": scInt(base, "track_count"), "playCount": scInt(base, "play_count"),
                "isLikedPlaylist": scInt(base, "type") == 1,
                "isOwned": (raw["isOwned"] as? NSNumber)?.boolValue == true,
                "creator": ["nickname": scStr(base, "creator_name")]]
    }

    private static func qishuiScene(_ raw: [String: Any]) -> [String: Any] {
        ["id": scStr(raw, "id"), "name": scStr(raw, "name"), "group": scStr(raw, "group"),
         "coverUrl": scStr(raw, "coverUrl")]
    }

    /// playlist_detail：库的 playlistPage 返回的 collection 即歌单对象
    ///（api.cjs：playlist_detail 时 data = data.collection || null）。
    private func playlistDetail(id: String, ownerId: String) async throws -> [String: Any] {
        let page = try await playlistPage(id: id, ownerId: ownerId, limit: 1, offset: 0)
        return (page["collection"] as? [String: Any]) ?? [:]
    }

    // MARK: - 路由分发（主服务形状，见 specs/sidecars.md §4.4 右列）

    /// failBody 错误映射（spec §4.2）：auth-required→401、not-playable→403、
    /// unsupported→400、invalid-response→400、unavailable/network→502、其余 502。
    private static func qsHTTPCode(_ e: QishuiError) -> Int {
        switch e.code {
        case "auth-required": return 401
        case "not-playable": return 403
        case "unsupported", "invalid-response": return 400
        default: return 502
        }
    }

    private func qsFail(_ e: QishuiError, empty: [String: Any] = [:]) -> HttpResponse {
        let code = Self.qsHTTPCode(e)
        var body: [String: Any] = ["code": code, "source": "qishui", "error": e.message]
        for (k, v) in empty { body[k] = v }
        return .json(code, body)
    }

    private func qsAuthFail(_ e: QishuiError) -> HttpResponse {
        // 账号类路由第 0 页失败时主服务固定回这句（spec §4.4）。
        if e.code == "auth-required" {
            return .json(401, ["code": 401, "source": "qishui", "error": "先在卡片上扫码登录汽水音乐"])
        }
        return qsFail(e)
    }

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        do {
            switch parts {
            case ["api", "qishui", "health"]:
                return .json(200, ["code": 200, "ok": true, "loggedIn": loadSession() != nil, "node": "",
                                   "audio": false,
                                   "audioReason": "仅元数据与公开读接口；播放需账号 guard 且只出未加密资源（最高 high）"])
            case ["api", "qishui", "status"]:
                return .json(200, ["code": 200] + (await status()))
            case ["api", "qishui", "login", "qr", "key"]:
                return .json(200, ["code": 200] + (try await loginQrKey()))
            case ["api", "qishui", "login", "qr", "create"]:
                let key = req.string("key")
                guard !key.isEmpty else { return .error(400, "缺少 key") }
                return .json(200, ["code": 200] + (try loginQrCreate(key: key)))
            case ["api", "qishui", "login", "qr", "check"]:
                let key = req.string("key")
                guard !key.isEmpty else { return .error(400, "缺少 key") }
                return .json(200, ["code": 200] + (try await loginQrCheck(key: key)))
            case ["api", "qishui", "login", "qr", "cancel"]:
                if !req.string("key").isEmpty { pending.removeValue(forKey: req.string("key")) }
                return .json(200, ["code": 200, "ok": true])
            case ["api", "qishui", "logout"]:
                clearSession()
                feedQueues.removeAll()
                playlistCursors.removeAll()
                return .json(200, ["code": 200, "loggedIn": false])
            case ["api", "qishui", "search"]:
                let q = req.string("q").isEmpty ? req.string("keyword") : req.string("q")
                if q.isEmpty { return .json(200, ["code": 200, "source": "qishui", "tracks": [], "songCount": 0]) }
                let limit = scClamp(req.int("limit", 20), 1, 50)
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await search(query: q, type: "track", limit: limit, offset: offset)
                    let tracks = ((r["items"] as? [[String: Any]]) ?? []).filter {
                        !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty
                    }
                    return .json(200, ["code": 200, "source": "qishui", "tracks": tracks,
                                       "songCount": tracks.count, "more": (r["hasMore"] as? NSNumber)?.boolValue == true])
                } catch let e as QishuiError {
                    return qsFail(e, empty: ["tracks": []])
                }
            case ["api", "qishui", "song", "url"]:
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let quality = req.string("quality")
                let q = ["standard", "high", "lossless", "hires"].contains(quality) ? quality : "standard"
                do {
                    let r = try await audio(id: req.string("id"), quality: q)
                    let preview = (r["preview"] as? NSNumber)?.boolValue == true
                    return .json(200, ["code": 200, "id": req.string("id"), "url": scStr(r, "url"),
                                       "preview": preview, "clipStartMs": scInt(r, "clipStartMs"),
                                       "quality": scStr(r, "quality").isEmpty ? q : scStr(r, "quality"),
                                       "reason": preview ? "preview" : NSNull(), "error": NSNull()])
                } catch let e as QishuiError {
                    // 边车 /audio 失败回 HTTP 200 的空地址体，主服务同理。
                    return .json(200, ["code": 200, "id": req.string("id"), "url": "", "preview": false,
                                       "clipStartMs": 0, "quality": q, "reason": e.code, "error": e.message])
                }
            case ["api", "qishui", "lyric"]:
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                do {
                    let info = try await lyrics(id: req.string("id"))
                    let content = scStr((info["lyric_entity"] as? [String: Any]) ?? [:], "content")
                    let isKrc = content.range(of: #"^\[\d+,\d+\]"#, options: [.regularExpression, .anchored]) != nil
                        || content.range(of: #"\n\[\d+,\d+\]"#, options: .regularExpression) != nil
                    let lrc = isKrc ? krcToLrc(content) : content
                    let yrc = isKrc ? krcToYrc(content) : ""
                    return .json(200, ["code": 200, "lyric": lrc, "yrc": yrc, "tlyric": "",
                                       "format": !yrc.isEmpty ? "yrc" : (!lrc.isEmpty ? "lrc" : "none")])
                } catch let e as QishuiError {
                    return .json(200, ["code": 200, "lyric": "", "yrc": "", "tlyric": "", "format": "none",
                                       "error": e.message])
                }
            case ["api", "qishui", "feed", "modes"]:
                do {
                    let modes = try await feedModes()
                    let stations = modes.map { Self.qishuiScene($0) }.filter { !scStr($0, "id").isEmpty }
                    return .json(200, ["code": 200, "source": "qishui", "stations": stations])
                } catch let e as QishuiError {
                    return qsFail(e, empty: ["stations": []])
                }
            case ["api", "qishui", "feed"]:
                let scene = req.string("scene").isEmpty ? (req.string("mode").isEmpty ? nil : req.string("mode")) : req.string("scene")
                let pref = req.string("preference").isEmpty ? nil : req.string("preference")
                let queue = req.string("queue").isEmpty ? "fm" : req.string("queue")
                let first = req.string("first") == "1" || (req.params["first"] as? NSNumber)?.boolValue == true
                let count = scClamp(req.int("count", 20), 1, 60)
                do {
                    let r = try await feed(scene: scene, preference: pref, queue: queue, first: first, count: count)
                    let tracks = ((r["items"] as? [[String: Any]]) ?? []).filter {
                        !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty
                    }
                    return .json(200, ["code": 200, "source": "qishui", "tracks": tracks])
                } catch let e as QishuiError {
                    return qsFail(e, empty: ["tracks": []])
                }
            case ["api", "qishui", "user", "playlists"]:
                let limit = scClamp(req.int("limit", 100), 1, 500)
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await userPlaylists(limit: limit, offset: offset)
                    return .json(200, ["code": 200, "source": "qishui", "playlists": r["items"] ?? [],
                                       "total": r["total"] ?? 0])
                } catch let e as QishuiError {
                    return qsAuthFail(e)
                }
            case ["api", "qishui", "liked_songs"]:
                let limit = scClamp(req.int("limit", 20), 1, 100)
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await likedSongs(limit: limit, offset: offset)
                    return .json(200, ["code": 200, "source": "qishui", "ids": r["ids"] ?? [],
                                       "total": r["total"] ?? 0])
                } catch let e as QishuiError {
                    return qsAuthFail(e)
                }
            case ["api", "qishui", "playlist", "detail"]:
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                do {
                    let collection = try await playlistDetail(id: req.string("id"), ownerId: req.string("ownerId"))
                    return .json(200, ["code": 200, "source": "qishui",
                                       "playlist": Self.qishuiPlaylist(collection)])
                } catch let e as QishuiError {
                    return .json(Self.qsHTTPCode(e), ["code": Self.qsHTTPCode(e), "source": "qishui",
                                                      "playlist": NSNull(), "error": e.message])
                }
            case ["api", "qishui", "search", "playlists"]:
                let q = req.string("q").isEmpty ? req.string("keyword") : req.string("q")
                if q.isEmpty { return .json(200, ["code": 200, "source": "qishui", "playlists": []]) }
                let limit = scClamp(req.int("limit", 20), 1, 50)
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await search(query: q, type: "playlist", limit: limit, offset: offset)
                    let lists = ((r["items"] as? [[String: Any]]) ?? []).map { Self.qishuiPlaylist($0) }
                        .filter { !scStr($0, "id").isEmpty }
                    return .json(200, ["code": 200, "source": "qishui", "playlists": lists])
                } catch let e as QishuiError {
                    return qsFail(e, empty: ["playlists": []])
                }
            case ["api", "qishui", "recent_played"]:
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await recentPlayed(limit: 50, offset: offset)
                    let tracks = ((r["items"] as? [[String: Any]]) ?? []).filter {
                        !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty
                    }
                    return .json(200, ["code": 200, "source": "qishui", "tracks": tracks])
                } catch let e as QishuiError {
                    return qsAuthFail(e)
                }
            case ["api", "qishui", "artist", "songs"]:
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await artistSongs(id: req.string("id"), limit: 50, offset: offset)
                    let tracks = ((r["items"] as? [[String: Any]]) ?? []).filter {
                        !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty
                    }
                    return .json(200, ["code": 200, "source": "qishui", "tracks": tracks])
                } catch let e as QishuiError {
                    return qsFail(e, empty: ["tracks": []])
                }
            case ["api", "qishui", "playlist", "tracks"]:
                guard !req.string("id").isEmpty else { return .error(400, "缺少 id") }
                let limit = scClamp(req.int("limit", 50), 1, 100)
                let offset = max(0, req.int("offset", 0))
                do {
                    let r = try await playlistPage(id: req.string("id"), ownerId: req.string("ownerId"),
                                                   limit: limit, offset: offset)
                    let tracks = ((r["items"] as? [[String: Any]]) ?? []).filter {
                        !scStr($0, "id").isEmpty && !scStr($0, "name").isEmpty
                    }
                    return .json(200, ["code": 200, "source": "qishui", "tracks": tracks,
                                       "more": (r["hasMore"] as? NSNumber)?.boolValue == true])
                } catch let e as QishuiError {
                    return qsFail(e, empty: ["tracks": []])
                }
            default:
                return .json(404, ["code": 404, "error": "unknown qishui api: \(parts.dropFirst(2).joined(separator: "/"))"])
            }
        } catch let e as QishuiError {
            return qsFail(e)
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

