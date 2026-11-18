import Foundation
import Compression

/// 酷我音乐：services/kuwo-api/start.mjs 的 1:1 Swift 移植（零依赖边车）。
/// www 接口（搜索/歌单/推荐/榜单/电台）+ mobi convert_url2（DES 变体加密）+
/// PC 歌词（lrcx 逐字，zlib 解压后 XOR + gb18030）+ 粘贴 Cookie 登录（无扫码）。

// MARK: - DES 变体（start.mjs 的 q 参数加密，密钥 ylzsxkwm）

enum KuwoDES {
    static let kls: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    static let klsMask: [UInt64] = [0, 0x100001, 0x300003]
    static let ke: [Int] = [31, 0, 1, 2, 3, 4, -1, -1, 3, 4, 5, 6, 7, 8, -1, -1, 7, 8, 9, 10, 11, 12, -1, -1, 11, 12, 13, 14, 15, 16, -1, -1, 15, 16, 17, 18, 19, 20, -1, -1, 19, 20, 21, 22, 23, 24, -1, -1, 23, 24, 25, 26, 27, 28, -1, -1, 27, 28, 29, 30, 31, 30, -1, -1]
    static let kip1: [Int] = [39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24]
    static let kip2: [Int] = [57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7, 56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6]
    static let kp: [Int] = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24]
    static let kpc1: [Int] = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    static let kpc2: [Int] = [13, 16, 10, 23, 0, 4, -1, -1, 2, 27, 14, 5, 20, 9, -1, -1, 22, 18, 11, 3, 25, 7, -1, -1, 15, 6, 26, 19, 12, 1, -1, -1, 40, 51, 30, 36, 46, 54, -1, -1, 29, 39, 50, 44, 32, 47, -1, -1, 43, 48, 38, 55, 33, 52, -1, -1, 45, 41, 49, 35, 28, 31, -1, -1]
    static let ksbox: [[Int]] = [
        [14, 4, 3, 15, 2, 13, 5, 3, 13, 14, 6, 9, 11, 2, 0, 5, 4, 1, 10, 12, 15, 6, 9, 10, 1, 8, 12, 7, 8, 11, 7, 0, 0, 15, 10, 5, 14, 4, 9, 10, 7, 8, 12, 3, 13, 1, 3, 6, 15, 12, 6, 11, 2, 9, 5, 0, 4, 2, 11, 14, 1, 7, 8, 13],
        [15, 0, 9, 5, 6, 10, 12, 9, 8, 7, 2, 12, 3, 13, 5, 2, 1, 14, 7, 8, 11, 4, 0, 3, 14, 11, 13, 6, 4, 1, 10, 15, 3, 13, 12, 11, 15, 3, 6, 0, 4, 10, 1, 7, 8, 4, 11, 14, 13, 8, 0, 6, 2, 15, 9, 5, 7, 1, 10, 12, 14, 2, 5, 9],
        [10, 13, 1, 11, 6, 8, 11, 5, 9, 4, 12, 2, 15, 3, 2, 14, 0, 6, 13, 1, 3, 15, 4, 10, 14, 9, 7, 12, 5, 0, 8, 7, 13, 1, 2, 4, 3, 6, 12, 11, 0, 13, 5, 14, 6, 8, 15, 2, 7, 10, 8, 15, 4, 9, 11, 5, 9, 0, 14, 3, 10, 7, 1, 12],
        [7, 10, 1, 15, 0, 12, 11, 5, 14, 9, 8, 3, 9, 7, 4, 8, 13, 6, 2, 1, 6, 11, 12, 2, 3, 0, 5, 14, 10, 13, 15, 4, 13, 3, 4, 9, 6, 10, 1, 12, 11, 0, 2, 5, 0, 13, 14, 2, 8, 15, 7, 4, 15, 1, 10, 7, 5, 6, 12, 11, 3, 8, 9, 14],
        [2, 4, 8, 15, 7, 10, 13, 6, 4, 1, 3, 12, 11, 7, 14, 0, 12, 2, 5, 9, 10, 13, 0, 3, 1, 11, 15, 5, 6, 8, 9, 14, 14, 11, 5, 6, 4, 1, 3, 10, 2, 12, 15, 0, 13, 2, 8, 5, 11, 8, 0, 15, 7, 14, 9, 4, 12, 7, 10, 9, 1, 13, 6, 3],
        [12, 9, 0, 7, 9, 2, 14, 1, 10, 15, 3, 4, 6, 12, 5, 11, 1, 14, 13, 0, 2, 8, 7, 13, 15, 5, 4, 10, 8, 3, 11, 6, 10, 4, 6, 11, 7, 9, 0, 6, 4, 2, 13, 1, 9, 15, 3, 8, 15, 3, 1, 14, 12, 5, 11, 0, 2, 12, 14, 7, 5, 10, 8, 13],
        [4, 1, 3, 10, 15, 12, 5, 0, 2, 11, 9, 6, 8, 7, 6, 9, 11, 4, 12, 15, 0, 3, 10, 5, 14, 13, 7, 8, 13, 14, 1, 2, 13, 6, 14, 9, 4, 1, 2, 14, 11, 13, 5, 0, 1, 10, 8, 3, 0, 11, 3, 5, 9, 4, 15, 2, 7, 8, 12, 15, 10, 7, 6, 12],
        [13, 7, 10, 0, 6, 9, 5, 15, 8, 4, 3, 10, 11, 14, 12, 5, 2, 11, 9, 6, 15, 12, 0, 3, 4, 1, 14, 13, 1, 2, 7, 8, 1, 2, 12, 15, 10, 4, 0, 3, 13, 14, 6, 9, 7, 8, 9, 6, 15, 1, 5, 12, 3, 10, 14, 5, 8, 7, 11, 0, 4, 13, 2, 11],
    ]

    static func bitTransform(_ table: [Int], _ n: Int, _ value: UInt64) -> UInt64 {
        var out: UInt64 = 0
        for i in 0..<n {
            let idx = table[i]
            if idx < 0 { continue }
            if value & (UInt64(1) << idx) != 0 { out |= UInt64(1) << i }
        }
        return out
    }

    static func des64(_ subKeys: [UInt64], _ value: UInt64) -> UInt64 {
        let out = bitTransform(kip2, 64, value)
        var l = UInt32(out & 0xFFFFFFFF)
        var r = UInt32((out >> 32) & 0xFFFFFFFF)
        for i in 0..<16 {
            let expanded = bitTransform(ke, 64, UInt64(r)) ^ subKeys[i]
            var sOut: UInt64 = 0
            for j in 0..<8 {
                let byteVal = Int((expanded >> (j * 8)) & 0xFF)
                sOut |= UInt64(ksbox[j][byteVal] & 0xF) << (j * 4)
            }
            let nl = r
            let nr = l ^ UInt32(bitTransform(kp, 32, sOut) & 0xFFFFFFFF)
            l = nl
            r = nr
        }
        let outv = (UInt64(l) << 32) | UInt64(r)
        return bitTransform(kip1, 64, outv)
    }

    static func buildSubKeys(_ keyStr: String, mode: Int) -> [UInt64] {
        let bytes = Array(keyStr.utf8)
        var keyLong: UInt64 = 0
        for i in 0..<8 { keyLong |= UInt64(bytes[i]) << (i * 8) }
        var value = bitTransform(kpc1, 56, keyLong)
        func rotate(_ x: UInt64, _ r: Int) -> UInt64 {
            let mask = klsMask[r]
            return ((x & mask) << (28 - r)) | ((x & ~mask) >> r)
        }
        var states = [value]
        for i in 0..<16 {
            value = rotate(value, kls[i])
            states.append(value)
        }
        var subKeys = states.dropFirst().map { bitTransform(kpc2, 64, $0) }
        if mode == 1 { subKeys.reverse() }
        return subKeys
    }

    static func cryptBlocks(_ bytes: [UInt8], keyStr: String, mode: Int) -> [UInt8] {
        let subKeys = buildSubKeys(keyStr, mode: mode)
        let n = bytes.count
        let blockCount = n / 8
        var out: [UInt64] = []
        for m in 0..<blockCount {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[m * 8 + i]) << (i * 8) }
            out.append(des64(subKeys, v))
        }
        out.append(0)
        if n - blockCount * 8 != 0 || mode == 0 {
            var tail: UInt64 = 0
            for i in (blockCount * 8)..<n {
                tail |= UInt64(bytes[i]) << ((i - blockCount * 8) * 8)
            }
            out[blockCount] = des64(subKeys, tail)
        }
        var res: [UInt8] = []
        for b in out {
            for j in 0..<8 { res.append(UInt8((b >> (j * 8)) & 0xFF)) }
        }
        return res
    }

    static func encryptQuery(_ plain: String) -> String {
        Data(cryptBlocks(Array(plain.utf8), keyStr: "ylzsxkwm", mode: 0)).base64EncodedString()
    }

    /// Secret: h(token, cookieName)，listen1 / 酷我网页的公开逆向算法。
    static func secretFor(token: String, name: String) throws -> String {
        let nameCodes = Array(name.utf16)
        var nStr = nameCodes.map { String($0) }.joined()
        let r = nStr.count / 5
        let chars = Array(nStr)
        // JS 原实现里 chars[5*r] 越界时是 undefined，join 时直接丢掉这一位，
        // 而不是整个算法抛错；当前首页 token 名（45 字符 → nStr 长 105，r=21，
        // 5r=105 恰好越界）会让旧 guard 直接抛错，www()（搜索/歌单/playUrl）全死。
        // 按 JS 语义补齐：只有第 5 个采样点可能越界（r/2r/3r/4r 恒在界内）。
        // 实测：该变体 secret 被上游接受（榜单回真实数据），其他变体均 illegal。
        var samples = [chars[r], chars[2 * r], chars[3 * r], chars[4 * r]]
        if 5 * r < chars.count { samples.append(chars[5 * r]) }
        let o = Int(String(samples)) ?? 0
        let l = (name.count + 1) / 2
        let c = 2147483647
        let d = Int.random(in: 0..<100_000_000)
        guard o >= 2 else {
            throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "酷我 Secret 算法参数异常"])
        }
        nStr += String(d)
        while nStr.count > 10 {
            let head = Int(String(nStr.prefix(10))) ?? 0
            let tail = Int(String(nStr.dropFirst(10))) ?? 0
            nStr = String(head + tail)
        }
        var n = Int(nStr) ?? 0
        n = (o * n + l) % c
        var f = ""
        for code in token.utf16 {
            let h = Int(code) ^ Int(floor(Double(n) / Double(c) * 255.0))
            f += h < 16 ? "0" + String(h, radix: 16) : String(h, radix: 16)
            n = (o * n + l) % c
        }
        var dHex = String(d, radix: 16)
        while dHex.count < 8 { dHex = "0" + dHex }
        return f + dHex
    }
}

// MARK: - 酷我服务

final class KuwoService {
    static let uaWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"
    static let uaOk = "okhttp/3.10.0"
    static let uaMobile = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36"
    static let cookiePrefix = "Hm_Iuvt_"
    static let cookieFallback = "Hm_Iuvt_cdb524f42f23cer9b268564v7y735ewrq2324"
    static let cred = "user=0&corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1"
    static let qualityMap: [String: String] = ["128": "128kmp3", "320": "320kmp3", "flac": "2000kflac"]

    private let session = SessionStore.shared
    private var userCookies: [String: String] = [:]
    private var tokenState = (token: "", name: cookieFallback, secret: "", at: Date(timeIntervalSince1970: 0))

    init() {
        if let saved = session.sidecarAuth("kuwo") {
            for (k, v) in saved where !k.hasPrefix(Self.cookiePrefix) {
                if let s = v as? String, !k.isEmpty { userCookies[k] = s }
            }
        }
    }

    private func saveUserCookies() {
        if userCookies.isEmpty { session.clearSidecarAuth("kuwo") }
        else { session.saveSidecarAuth("kuwo", userCookies) }
    }

    private func userUid() -> String {
        userCookies["userid"] ?? userCookies["userId"] ?? userCookies["uid"] ?? ""
    }
    private func userSid() -> String {
        userCookies["sid"] ?? userCookies["websid"] ?? ""
    }

    // MARK: - token + Secret

    private static func parseTokenCookie(_ raw: String) -> (name: String, value: String)? {
        let splitRe = try! NSRegularExpression(pattern: #",(?=\s*[^;=]+=[^;]*)"#)
        let ns = NSRange(raw.startIndex..., in: raw)
        var lines: [String] = []
        var last = raw.startIndex
        for m in splitRe.matches(in: raw, range: ns) {
            let r = Range(m.range, in: raw)!
            lines.append(String(raw[last..<r.lowerBound]))
            last = r.upperBound
        }
        lines.append(String(raw[last...]))
        let lineRe = try! NSRegularExpression(pattern: #"^\s*([^=;]+)=([^;]*)"#)
        for line in lines {
            guard let m = lineRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let name = String(line[Range(m.range(at: 1), in: line)!])
            let value = String(line[Range(m.range(at: 2), in: line)!])
            if name.hasPrefix(cookiePrefix) { return (name, value) }
        }
        return nil
    }

    private func refreshToken() async throws {
        let url = URL(string: "https://www.kuwo.cn/")!
        let (_, resp) = try await Upstream.fetch(url, headers: ["User-Agent": Self.uaWeb], timeout: 20)
        let setCookie = resp.value(forHTTPHeaderField: "Set-Cookie")
            ?? (resp.allHeaderFields.first { ($0.key as? String)?.lowercased() == "set-cookie" }?.value as? String)
        guard let setCookie, let hit = Self.parseTokenCookie(setCookie) else {
            throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "酷我首页没有下发 Hm_Iuvt_ token（上游可能改了鉴权）"])
        }
        let secret = try KuwoDES.secretFor(token: hit.value, name: hit.name)
        tokenState = (token: hit.value, name: hit.name, secret: secret, at: Date())
    }

    private func cookieHeader() -> String {
        var parts: [String] = []
        for (k, v) in userCookies where !k.hasPrefix(Self.cookiePrefix) { parts.append("\(k)=\(v)") }
        parts.append("\(tokenState.name)=\(tokenState.token)")
        return parts.joined(separator: "; ")
    }

    /// www 接口：token 为空或超过 5 分钟先刷新；回 illegal 时刷新后重试一次。
    private func www(_ pathname: String, retry: Bool = true, timeout: TimeInterval = 20,
                     referer: String = "https://www.kuwo.cn/") async throws -> (status: Int, text: String) {
        if tokenState.token.isEmpty || Date().timeIntervalSince(tokenState.at) > 5 * 60 {
            try await refreshToken()
        }
        let url = URL(string: "https://www.kuwo.cn" + pathname)!
        let headers = ["User-Agent": Self.uaWeb, "Referer": referer,
                       "Cookie": cookieHeader(), "Secret": tokenState.secret]
        let (data, resp) = try await Upstream.fetch(url, headers: headers, timeout: timeout)
        let text = String(data: data, encoding: .utf8) ?? ""
        if retry && text.range(of: "The request is illegal", options: .caseInsensitive) != nil {
            try await refreshToken()
            return try await www(pathname, retry: false, timeout: timeout, referer: referer)
        }
        return (resp.statusCode, text)
    }

    // MARK: - Cookie 解析 / 登录态

    static func parseCookieInput(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return out }
        if let r = text.range(of: #"^cookie\s*:\s*"#, options: .regularExpression) { text = String(text[r.upperBound...]) }
        if text.hasPrefix("{") {
            if let data = text.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in j where !k.isEmpty {
                    if let s = v as? String { out[k] = s }
                }
                return out
            }
        }
        for part in text.split(separator: ";") {
            guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
            let k = part[..<i].trimmingCharacters(in: .whitespaces)
            var v = part[part.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    private func statusBody() -> [String: Any] {
        let uid = userUid()
        let loggedIn = !uid.isEmpty && !userSid().isEmpty
        return [
            "code": 200, "loggedIn": loggedIn, "uid": uid,
            "nickname": "", "avatar": "", "vip": false, "verified": false,
            "hasCookie": !uid.isEmpty,
            "note": loggedIn
                ? "登录态来自粘贴的 Cookie；酷我 Web 没有可用的校验接口，播放时会自动带上"
                : (uid.isEmpty ? "还没粘贴酷我 Cookie" : "Cookie 里只有 userid，缺 sid/websid —— 请复制整段 Cookie"),
        ]
    }

    // MARK: - 播放直链

    private func mobiUrl(_ id: String, _ br: String) async throws -> String {
        var plain = "\(Self.cred)&type=convert_url2&sig=0&format=\(br.contains("flac") ? "flac" : "mp3")&br=\(br)&rid=\(id)"
        if !userUid().isEmpty && !userSid().isEmpty {
            plain += "&loginUid=\(scURLEncode(userUid()))&loginSid=\(scURLEncode(userSid()))"
        }
        let q = KuwoDES.encryptQuery(plain)
        let url = URL(string: "https://mobi.kuwo.cn/mobi.s?f=kuwo&q=" + scURLEncode(q))!
        let (data, _) = try await Upstream.fetch(url, headers: ["User-Agent": Self.uaOk], timeout: 20)
        let text = String(data: data, encoding: .utf8) ?? ""
        if let m = text.range(of: #"url=(https?://[^\s]+)"#, options: .regularExpression) {
            return String(text[m]).replacingOccurrences(of: "url=", with: "")
        }
        return ""
    }

    private func webPlayUrl(_ id: String) async throws -> String {
        let r = try await www("/api/v1/www/music/playUrl?mid=\(scURLEncode(id))&type=music&httpsStatus=1&plat=web_www&from=&br=128kmp3")
        let j = scParseJSONObject(r.text)
        return scStr(scDict(j, "data"), "url")
    }

    private func resolveSongUrl(_ id: String, _ quality: String) async -> [String: Any] {
        let want = Self.qualityMap[quality] ?? Self.qualityMap["320"]!
        var tries = [want]
        if want != "320kmp3" { tries.append("320kmp3") }
        if want != "128kmp3" { tries.append("128kmp3") }
        var last = ""
        for br in tries {
            do {
                let u = try await mobiUrl(id, br)
                if !u.isEmpty {
                    return ["url": u, "quality": br.replacingOccurrences(of: "kmp3", with: "").replacingOccurrences(of: "kflac", with: ""),
                            "format": br.contains("flac") ? "flac" : "mp3", "source": "mobi"]
                }
                last = "mobi 没返回 url"
            } catch { last = error.localizedDescription }
        }
        do {
            let u = try await webPlayUrl(id)
            if !u.isEmpty { return ["url": u, "quality": "web", "format": "mp3", "source": "web"] }
        } catch { last = error.localizedDescription }
        return ["url": "", "reason": "unavailable", "error": last.isEmpty ? "上游没给播放地址" : last]
    }

    // MARK: - 歌词

    static let gb18030: String.Encoding = {
        // kCFStringEncodingGB_18030_2000 = 0x0632（SDK 头文件值）。
        // Swift 的 CFStringEncodings 未暴露 gb_18030_2000 成员，直接用数值。
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
        return String.Encoding(rawValue: cf)
    }()

    private static func decodeGb18030(_ buf: Data) -> String {
        String(data: buf, encoding: gb18030) ?? String(data: buf, encoding: .utf8) ?? ""
    }

    private static func zlibInflate(_ data: Data) -> Data? {
        var size = max(data.count * 8, 65536)
        for _ in 0..<4 {
            var out = Data(count: size)
            var decoded = 0
            let ok: Bool = data.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    guard let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    decoded = compression_decode_buffer(d, size, s, data.count, nil, COMPRESSION_ZLIB)
                    return decoded > 0
                }
            }
            if ok { return out.prefix(decoded) }
            size *= 4
        }
        return nil
    }

    static func buildLyricParams(_ id: String, lrcx: Bool = true) -> String {
        var params = "user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_\(id)"
        if lrcx { params += "&lrcx=1" }
        let src = Array(params.utf8)
        let key = Array("yeelion".utf8)
        var out = [UInt8](repeating: 0, count: src.count)
        for i in 0..<src.count { out[i] = src[i] ^ key[i % key.count] }
        return Data(out).base64EncodedString()
    }

    private static let lrcxLineRe = try! NSRegularExpression(pattern: #"^\[(\d{2}):(\d{2})(?:[.:](\d{1,3}))?\](.*)$"#)
    private static let lrcxCharRe = try! NSRegularExpression(pattern: #"<(\d+),(\d+)>([^<]*)"#)
    private static let kuwoTagRe = try! NSRegularExpression(pattern: #"\[kuwo:([0-7]+)\]"#)
    private static let kuwoPairRe = try! NSRegularExpression(pattern: #"<(-?\d+),(-?\d+)>"#)

    /// lrcx 的 <左,右> 是逐字时间：[kuwo:NNN] 给出两个系数（八进制），
    /// 左/右是「起点 + 时长」的混合编码，解回 <相对行首ms,字时长ms>。
    static func decodeWordTiming(_ content: String) -> String? {
        guard let tagMatch = kuwoTagRe.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              tagMatch.range(at: 1).location != NSNotFound else { return nil }
        let digits = String(content[Range(tagMatch.range(at: 1), in: content)!])
        guard let factors = Int(digits, radix: 8) else { return nil }
        let startFactor = factors / 10
        let durationFactor = factors % 10
        guard startFactor != 0, durationFactor != 0 else { return nil }
        var result = content.replacingOccurrences(of: #"\[kuwo:[^\]]*\]"#, with: "", options: .regularExpression)
        let ns = NSRange(result.startIndex..., in: result)
        var out = ""
        var lastEnd = result.startIndex
        for m in kuwoPairRe.matches(in: result, range: ns) {
            let range = Range(m.range, in: result)!
            let a = Int(result[Range(m.range(at: 1), in: result)!]) ?? 0
            let b = Int(result[Range(m.range(at: 2), in: result)!]) ?? 0
            let start = Int(abs(Double(a + b) / Double(2 * startFactor)))
            let duration = Int(abs(Double(a - b) / Double(2 * durationFactor)))
            out += result[lastEnd..<range.lowerBound]
            out += "<\(start),\(duration)>"
            lastEnd = range.upperBound
        }
        out += result[lastEnd...]
        result = out
        return result
    }

    static func convertLrcx(_ raw: String) -> (lyric: String, yrc: String) {
        let decoded = decodeWordTiming(raw) ?? raw
        var out: [String] = []
        var yrcOut: [String] = []
        var lastTime = ""
        for line in decoded.components(separatedBy: .newlines) {
            guard let m = lrcxLineRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                if line.range(of: #"^\[(ti|ar|al|by|offset):"#, options: .regularExpression) != nil { out.append(line) }
                continue
            }
            let mm = String(line[Range(m.range(at: 1), in: line)!])
            let ss = String(line[Range(m.range(at: 2), in: line)!])
            var frac = m.range(at: 3).location != NSNotFound ? String(line[Range(m.range(at: 3), in: line)!]) : "000"
            while frac.count < 3 { frac += "0" }
            frac = String(frac.prefix(3))
            let time = "\(mm):\(ss).\(frac)"
            let content = String(line[Range(m.range(at: 4), in: line)!])
            let isTrans = content.hasPrefix("<0,0>")
            let text = content.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if isTrans && time == lastTime { continue }
            out.append("[\(time)]\(text)")
            if !isTrans { lastTime = time }
            if isTrans { continue }
            var chars: [(Int, Int, String)] = []
            for cm in lrcxCharRe.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                let off = Int(content[Range(cm.range(at: 1), in: content)!]) ?? 0
                let d = Int(content[Range(cm.range(at: 2), in: content)!]) ?? 0
                let t = String(content[Range(cm.range(at: 3), in: content)!])
                if !t.isEmpty { chars.append((off, d, t)) }
            }
            if chars.isEmpty { continue }
            let start = (Int(mm) ?? 0) * 60000 + (Int(ss) ?? 0) * 1000 + (Int(frac) ?? 0)
            let dur = chars.map { $0.0 + $0.1 }.max() ?? 0
            yrcOut.append("[\(start),\(dur)]" + chars.map { "(\(start + $0.0),\($0.1),0)\($0.2)" }.joined())
        }
        return (out.joined(separator: "\n"), yrcOut.joined(separator: "\n"))
    }

    private static func secToLrc(_ t: Double) -> String {
        let mm = String(format: "%02d", Int(t / 60))
        let ss = String(format: "%02d", Int(t.truncatingRemainder(dividingBy: 60)))
        let cs = String(format: "%02d", Int(((t - floor(t)) * 100).rounded()))
        return "\(mm):\(ss).\(cs)"
    }

    private func lyricPc(_ id: String) async throws -> (lyric: String, yrc: String) {
        let url = URL(string: "https://newlyric.kuwo.cn/newlyric.lrc?" + Self.buildLyricParams(id, lrcx: true))!
        let (data, resp) = try await Upstream.fetch(url, headers: ["User-Agent": Self.uaWeb], timeout: 20)
        guard resp.statusCode >= 200 && resp.statusCode < 300 else {
            throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "歌词 HTTP \(resp.statusCode)"])
        }
        guard data.starts(with: Data("tp=content".utf8)) else {
            throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "歌词返回格式不是 tp=content"])
        }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "歌词返回缺分隔头"])
        }
        let compressed = data.subdata(in: sep.upperBound..<data.endIndex)
        guard let inflated = Self.zlibInflate(compressed) else {
            throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "歌词解压失败"])
        }
        let asText = String(data: inflated, encoding: .utf8) ?? ""
        let raw: String
        if asText.range(of: #"^\s*\["#, options: .regularExpression) != nil {
            raw = Self.decodeGb18030(inflated)
        } else {
            guard let enc = Data(base64Encoded: asText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw NSError(domain: "Kuwo", code: -1, userInfo: [NSLocalizedDescriptionKey: "歌词 base64 解码失败"])
            }
            let key = Array("yeelion".utf8)
            var dec = [UInt8](enc)
            for i in 0..<dec.count { dec[i] ^= key[i % key.count] }
            raw = Self.decodeGb18030(Data(dec))
        }
        return Self.convertLrcx(raw)
    }

    private func lyricH5(_ id: String) async throws -> String {
        let url = URL(string: "http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=" + scURLEncode(id))!
        let (data, _) = try await Upstream.fetch(url, headers: ["User-Agent": Self.uaMobile, "Referer": "https://m.kuwo.cn/"], timeout: 15)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let j = scParseJSON(text) as? [String: Any],
              let list = scDict(j, "data")["lrclist"] as? [[String: Any]], !list.isEmpty else { return "" }
        return list.filter { $0["lineLyric"] != nil }.map {
            "[\(Self.secToLrc(($0["time"] as? NSNumber)?.doubleValue ?? 0))]\(String(describing: $0["lineLyric"]!))"
        }.joined(separator: "\n")
    }

    // MARK: - 每日推荐

    private func dailyList() async -> [String: Any] {
        do {
            let r = try await www("/api/www/rcm/index/playlist?id=37&pn=1&rn=10&httpsStatus=1")
            let j = scParseJSONObject(r.text)
            let list = scArr(scDict(j, "data"), "list")
            let pick = list.first { ($0["name"] as? String ?? "").range(of: "每日|推荐", options: .regularExpression) != nil } ?? list.first
            if let pick, !scStrOrNum(pick, "id").isEmpty {
                let pr = try await www("/api/www/playlist/playListInfo?pid=\(scURLEncode(scStrOrNum(pick, "id")))&pn=1&rn=20&httpsStatus=1")
                let pj = scParseJSONObject(pr.text)
                let tracks = scArr(scDict(pj, "data"), "musicList")
                if !tracks.isEmpty {
                    return ["code": 200, "name": scStr(pick, "name").isEmpty ? "每日最新单曲推荐" : scStr(pick, "name"),
                            "source": "playlist", "list": tracks]
                }
            }
        } catch { /* 退榜单 */ }
        let r = try? await www("/api/www/bang/bang/musicList?bangId=16&pn=1&rn=20&httpsStatus=1")
        let j = r.map { scParseJSONObject($0.text) } ?? [:]
        return ["code": 200, "name": "酷我热歌榜", "source": "rank", "list": scArr(scDict(j, "data"), "musicList")]
    }

    // MARK: - 归一化

    private static func firstNonEmpty(_ values: [String]) -> String {
        values.first(where: { !$0.isEmpty }) ?? ""
    }

    func kuwoTrack(_ it: [String: Any]) -> [String: Any]? {
        var rid = scStrOrNum(it, "rid")
        if rid.isEmpty { rid = scStrOrNum(it, "DC_TARGETID") }
        if rid.isEmpty {
            let m = scStr(it, "MUSICRID")
            if !m.isEmpty { rid = m.hasPrefix("MUSIC_") ? String(m.dropFirst(6)) : m }
        }
        if rid.isEmpty { rid = scStrOrNum(it, "id") }
        let name = Self.firstNonEmpty([scStr(it, "name"), scStr(it, "NAME"), scStr(it, "SONGNAME")])
        let artists = Self.firstNonEmpty([scStr(it, "artist"), scStr(it, "ARTIST"), scStr(it, "FARTIST")])
        var cover = Self.firstNonEmpty([scStr(it, "pic"), scStr(it, "albumpic"), scStr(it, "albumpic_short"), scStr(it, "web_albumpic_short")])
        if !cover.isEmpty && !cover.hasPrefix("http") {
            cover = "https://img1.kuwo.cn/star/albumcover/" + cover.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let album = Self.firstNonEmpty([scStr(it, "album"), scStr(it, "ALBUM")])
        let albumId = scStrOrNum(it, "albumid").isEmpty ? scStrOrNum(it, "ALBUMID") : scStrOrNum(it, "albumid")
        let d = scNum(it["duration"]) != 0 ? scNum(it["duration"]) : scNum(it["DURATION"])
        return [
            "id": rid, "source": "kuwo", "name": name,
            "artists": artists.isEmpty ? "未知歌手" : artists,
            "album": album, "albumId": albumId, "cover": cover,
            "duration": d * 1000, "fee": 0,
        ]
    }

    func kuwoPlaylist(_ it: [String: Any]) -> [String: Any]? {
        let id = scStrOrNum(it, "sourceid").isEmpty ? scStrOrNum(it, "id") : scStrOrNum(it, "sourceid")
        guard !id.isEmpty else { return nil }
        let cover = Self.firstNonEmpty([scStr(it, "img"), scStr(it, "img500"), scStr(it, "img300"), scStr(it, "pic")])
        return [
            "id": id, "source": "kuwo",
            "name": scStr(it, "name").isEmpty ? "未命名歌单" : scStr(it, "name"),
            "cover": cover,
            "trackCount": scNum(it["total"]),
            "playCount": scNum(it["listencnt"]),
            "creator": ["nickname": Self.firstNonEmpty([scStr(it, "uname"), scStr(it, "userName")])],
            "rank": it["sourceid"] != nil,
        ]
    }

    // MARK: - 路由（主服务翻译层，handleKuwo）

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/kuwo/".count))
        do {
            switch part {
            case "", "health":
                return .json(200, ["code": 200, "ok": true, "audio": true, "login": "cookie"])
            case "status", "login/status":
                return .json(200, statusBody())
            case "login/cookie":
                return loginCookie(req)
            case "logout":
                userCookies = [:]
                saveUserCookies()
                return .json(200, ["code": 200, "loggedIn": false])
            case "login/qr/key", "login/qr/create", "login/qr/check":
                return .json(200, ["code": 501, "error": "酷我 Web 端不提供扫码登录；请在浏览器登录 www.kuwo.cn 后粘贴 Cookie"])
            case "search":
                return try await search(req)
            case "playlist/tracks":
                return try await playlistTracks(req)
            case "playlist/search":
                return try await playlistSearch(req)
            case "recommend/playlists":
                return try await recommendPlaylists(req)
            case "rank/list":
                return try await rankList()
            case "rank/tracks":
                return try await rankTracks(req)
            case "radio/stations":
                return try await radioStations()
            case "album/tracks":
                return try await albumTracks(req)
            case "daily":
                return try await daily(req)
            case "song/url":
                return try await songUrl(req)
            case "lyric":
                return try await lyric(req)
            case "user/playlists":
                return .json(200, ["code": 200, "source": "kuwo", "playlists": [], "tracks": [],
                                   "error": "酷我 Web 没有用户歌单接口，不编内容"])
            case "liked":
                return .json(200, ["code": 200, "source": "kuwo", "playlists": [], "tracks": [],
                                   "error": "酷我 Web 没有「我喜欢的音乐」接口，不编内容"])
            default:
                return .json(404, ["code": 404, "error": "unknown kuwo api: \(part)"])
            }
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    private func loginCookie(_ req: HttpRequest) -> HttpResponse {
        guard req.method == "POST" else {
            return .json(405, ["code": 405, "error": "请用 POST 提交 Cookie"])
        }
        let raw = req.string("cookie").isEmpty ? req.string("value") : req.string("cookie")
        guard !raw.isEmpty else {
            return .json(200, ["code": 200, "loggedIn": false, "error": "Cookie 是空的"])
        }
        let parsed = Self.parseCookieInput(raw)
        let uid = parsed["userid"] ?? parsed["userId"] ?? parsed["uid"] ?? ""
        let sid = parsed["sid"] ?? parsed["websid"] ?? ""
        guard !uid.isEmpty, !sid.isEmpty else {
            return .json(200, ["code": 200, "loggedIn": false,
                               "error": "Cookie 里没有 userid / sid（或 websid）。请登录 www.kuwo.cn 后复制整段 Cookie"])
        }
        userCookies = parsed.filter { !$0.key.hasPrefix(Self.cookiePrefix) && !$0.key.isEmpty }
        saveUserCookies()
        return .json(200, statusBody())
    }

    private func upstreamCode(_ j: [String: Any]) -> Int {
        let c = scNum(j["code"])
        return c != 0 ? c : 502
    }
    private func upstreamError(_ j: [String: Any], _ fallback: String) -> String {
        let m = scStr(j, "msg")
        if !m.isEmpty { return m }
        let m2 = scStr(j, "message")
        return m2.isEmpty ? fallback : m2
    }

    private func search(_ req: HttpRequest) async throws -> HttpResponse {
        let s = [req.string("s"), req.string("key"), req.string("keywords")].first(where: { !$0.isEmpty }) ?? ""
        let sTrim = s.trimmingCharacters(in: .whitespaces)
        guard !sTrim.isEmpty else {
            return .json(200, ["code": 200, "source": "kuwo", "tracks": [], "songCount": 0])
        }
        let limit = scClamp(req.int("limit", 20), 1, 50)
        let page = max(1, req.int("page", 1))
        let path = "/search/searchMusicBykeyWord?vipver=1&client=kt&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&mobi=1&issubtitle=1&show_copyright_off=1&pn=\(page - 1)&rn=\(limit)&all=\(scURLEncode(sTrim))"
        let r = try await www(path, referer: "https://www.kuwo.cn/search")
        let j = scParseJSONObject(r.text)
        guard let abslist = j["abslist"] as? [[String: Any]] else {
            return .json(200, ["code": 502, "source": "kuwo", "tracks": [], "songCount": 0, "error": "酷我搜索返回无法解析"])
        }
        let tracks = abslist.compactMap { kuwoTrack($0) }.filter {
            !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
        }
        return .json(200, ["code": 200, "source": "kuwo", "tracks": tracks,
                           "songCount": scNum(j["TOTAL"]) != 0 ? scNum(j["TOTAL"]) : abslist.count])
    }

    private func playlistTracks(_ req: HttpRequest) async throws -> HttpResponse {
        let id = req.string("id").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        let limit = scClamp(req.int("limit", 100), 1, 200)
        let page = max(1, req.int("page", 1))
        let r = try await www("/api/www/playlist/playListInfo?pid=\(scURLEncode(id))&pn=\(page)&rn=\(limit)&httpsStatus=1")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "id": id, "tracks": [],
                               "error": upstreamError(j, "取歌单失败")])
        }
        let d = scDict(j, "data")
        let list = scArr(d, "musicList")
        let tracks = list.compactMap { kuwoTrack($0) }.filter {
            !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
        }
        return .json(200, ["code": 200, "source": "kuwo", "id": scStrOrNum(d, "id").isEmpty ? id : scStrOrNum(d, "id"),
                           "name": scStr(d, "name"), "cover": scStr(d, "img"),
                           "creator": Self.firstNonEmpty([scStr(d, "uname"), scStr(d, "userName")]),
                           "total": scNum(d["total"]) != 0 ? scNum(d["total"]) : list.count,
                           "tracks": tracks])
    }

    private func playlistSearch(_ req: HttpRequest) async throws -> HttpResponse {
        let key = [req.string("key"), req.string("s")].first(where: { !$0.isEmpty }) ?? ""
        let keyTrim = key.trimmingCharacters(in: .whitespaces)
        guard !keyTrim.isEmpty else {
            return .json(200, ["code": 200, "source": "kuwo", "playlists": [], "total": 0])
        }
        let limit = scClamp(req.int("limit", 30), 1, 50)
        let page = max(1, req.int("page", 1))
        let r = try await www("/api/www/search/searchPlayListBykeyWord?key=\(scURLEncode(keyTrim))&pn=\(page)&rn=\(limit)&httpsStatus=1")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "playlists": [], "total": 0,
                               "error": upstreamError(j, "搜索歌单失败")])
        }
        let d = scDict(j, "data")
        let list = scArr(d, "list")
        let playlists = list.compactMap { kuwoPlaylist($0) }.filter { !($0["name"] as? String ?? "").isEmpty }
        return .json(200, ["code": 200, "source": "kuwo", "playlists": playlists,
                           "total": scNum(d["total"]) != 0 ? scNum(d["total"]) : list.count])
    }

    private func recommendPlaylists(_ req: HttpRequest) async throws -> HttpResponse {
        let limit = scClamp(req.int("limit", 12), 1, 50)
        let id = req.string("id").isEmpty ? "37" : req.string("id")
        let r = try await www("/api/www/rcm/index/playlist?id=\(scURLEncode(id))&pn=1&rn=\(limit)&httpsStatus=1")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "playlists": [],
                               "error": upstreamError(j, "取推荐歌单失败")])
        }
        let list = scArr(scDict(j, "data"), "list")
        let playlists = list.compactMap { kuwoPlaylist($0) }.filter { !($0["name"] as? String ?? "").isEmpty }
        return .json(200, ["code": 200, "source": "kuwo", "playlists": playlists])
    }

    private func rankList() async throws -> HttpResponse {
        let r = try await www("/api/www/bang/bang/bangMenu?&httpsStatus=1", referer: "https://www.kuwo.cn/rankList")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "playlists": [],
                               "error": upstreamError(j, "取榜单目录失败")])
        }
        var playlists: [[String: Any]] = []
        for g in (j["data"] as? [[String: Any]] ?? []) {
            for it in scArr(g, "list") {
                if let p = kuwoPlaylist(it), !(p["name"] as? String ?? "").isEmpty { playlists.append(p) }
            }
        }
        return .json(200, ["code": 200, "source": "kuwo", "playlists": playlists])
    }

    private func rankTracks(_ req: HttpRequest) async throws -> HttpResponse {
        let id = req.string("id").isEmpty ? "16" : req.string("id")
        let limit = scClamp(req.int("limit", 30), 1, 200)
        let page = max(1, req.int("page", 1))
        let r = try await www("/api/www/bang/bang/musicList?bangId=\(scURLEncode(id))&pn=\(page)&rn=\(limit)&httpsStatus=1",
                              referer: "https://www.kuwo.cn/rankList")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "id": id, "tracks": [],
                               "error": upstreamError(j, "取榜单失败")])
        }
        let d = scDict(j, "data")
        let list = scArr(d, "musicList")
        let tracks = list.compactMap { kuwoTrack($0) }.filter {
            !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
        }
        return .json(200, ["code": 200, "source": "kuwo", "id": id,
                           "total": scNum(d["num"]) != 0 ? scNum(d["num"]) : list.count, "tracks": tracks])
    }

    private func radioStations() async throws -> HttpResponse {
        let r = try await www("/api/www/radio/index/radioList?&httpsStatus=1", referer: "https://www.kuwo.cn/rankList")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "stations": [],
                               "error": upstreamError(j, "取电台目录失败")])
        }
        let list = scArr(scDict(j, "data"), "albumList")
        let stations = list.map { it -> [String: Any] in
            ["id": scStrOrNum(it, "rid"), "source": "kuwo",
             "name": scStr(it, "album").isEmpty ? "未命名电台" : scStr(it, "album"),
             "cover": scStr(it, "pic"),
             "creator": ["nickname": scStr(it, "artist")],
             "playCount": scNum(it["listencnt"]), "playable": false]
        }
        return .json(200, ["code": 200, "source": "kuwo", "playable": false, "stations": stations,
                           "note": "酷我只开放电台栏目目录，没有单集曲目接口"])
    }

    private func albumTracks(_ req: HttpRequest) async throws -> HttpResponse {
        let id = req.string("id").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        let limit = scClamp(req.int("limit", 100), 1, 200)
        let page = max(1, req.int("page", 1))
        let r = try await www("/api/www/album/albumInfo?albumId=\(scURLEncode(id))&pn=\(page)&rn=\(limit)&httpsStatus=1")
        let j = scParseJSONObject(r.text)
        guard scNum(j["code"]) == 200 else {
            return .json(200, ["code": upstreamCode(j), "source": "kuwo", "id": id, "tracks": [],
                               "error": upstreamError(j, "取专辑失败")])
        }
        let d = scDict(j, "data")
        let list = scArr(d, "musicList")
        let tracks = list.compactMap { kuwoTrack($0) }.filter {
            !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
        }
        return .json(200, ["code": 200, "source": "kuwo",
                           "id": scStrOrNum(d, "albumid").isEmpty ? id : scStrOrNum(d, "albumid"),
                           "name": scStr(d, "album"), "cover": scStr(d, "pic"),
                           "total": scNum(d["total"]), "tracks": tracks])
    }

    private func daily(_ req: HttpRequest) async throws -> HttpResponse {
        let d = await dailyList()
        let tracks = (d["list"] as? [[String: Any]] ?? []).compactMap { kuwoTrack($0) }.filter {
            !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
        }
        return .json(200, ["code": 200, "source": "kuwo", "name": scStr(d, "name").isEmpty ? "每日推荐" : scStr(d, "name"),
                           "from": scStr(d, "source"), "tracks": tracks])
    }

    private func songUrl(_ req: HttpRequest) async throws -> HttpResponse {
        let id = [req.string("id"), req.string("mid")].first(where: { !$0.isEmpty }) ?? ""
        let idTrim = id.trimmingCharacters(in: .whitespaces)
        guard !idTrim.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        let quality = req.string("quality", "320")
        let hit = await resolveSongUrl(idTrim, quality)
        let url = hit["url"] as? String ?? ""
        return .json(200, ["code": 200, "id": idTrim, "url": url,
                           "quality": hit["quality"] as Any, "format": hit["format"] as Any,
                           "preview": false, "source": hit["source"] as Any,
                           "reason": url.isEmpty ? (hit["reason"] as Any) : NSNull(),
                           "error": url.isEmpty ? (hit["error"] as Any) : NSNull()])
    }

    private func lyric(_ req: HttpRequest) async throws -> HttpResponse {
        let id = [req.string("id"), req.string("mid")].first(where: { !$0.isEmpty }) ?? ""
        let idTrim = id.trimmingCharacters(in: .whitespaces)
        guard !idTrim.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        var parsed = (lyric: "", yrc: "")
        var source = "kw-pc"
        var error: String? = nil
        do {
            parsed = try await lyricPc(idTrim)
        } catch let e { error = e.localizedDescription }
        if parsed.lyric.isEmpty && parsed.yrc.isEmpty {
            source = "kw-h5"
            do {
                parsed = (lyric: try await lyricH5(idTrim), yrc: "")
            } catch let e { if error == nil { error = e.localizedDescription } }
        }
        let hasLyric = !parsed.lyric.isEmpty || !parsed.yrc.isEmpty
        if !hasLyric {
            // 第 11 轮：PC + H5 两路都空，走 LRCLIB 兜底；元数据来自前端
            // srcLyric 传参（酷我没有现成的单曲详情接口，不新写）。
            // 兜底命中时 source 记 lrclib，error 清掉；兜底也空时回原来的
            // source/error，原样不变。
            if let fb = await Lrclib.fetch(artist: req.string("artist"), track: req.string("s"),
                                           album: req.string("album"), duration: req.int("duration")) {
                return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": fb.yrc,
                                   "format": "lrc", "source": "lrclib", "error": NSNull()])
            }
        }
        return .json(200, ["code": 200, "lyric": parsed.lyric, "yrc": parsed.yrc,
                           "format": !parsed.yrc.isEmpty ? "yrc" : (!parsed.lyric.isEmpty ? "lrc" : "none"),
                           "source": source,
                           "error": hasLyric ? NSNull() as Any : (error ?? "酷我没给这首歌歌词（或上游限流）")])
    }
}
