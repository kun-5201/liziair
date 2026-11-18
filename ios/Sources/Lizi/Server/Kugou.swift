import Foundation
import CommonCrypto
import CoreImage
import Compression
import UIKit

/// 酷狗边车：kugoumusicapi@1.6.0（MIT）的 Swift 移植。
/// 上游细节见 /tmp/kugou-details.md（逐字摘自包内 util/ 与 module/）。
/// 主服务路由与归一化见 specs/sidecars.md §2。
/// 注意：
/// - 平台固定标准版（appid 1005），lite 分支（3116）未启用，start.mjs 里 platform 默认为空串。
/// - 密码登录（login.js 的 t1/t2）与 token 刷新（login_token.js）主服务没接，不移植。
/// - ssa-code 响应头的 edt/sid 需 util/generate_simulate.js 的算法，细节提取未覆盖，
///   这里只透传 ssaCode，不算 edt/sid。
/// - 20028 风控（本次请求需要验证）由上游返回，song/url 据此报 reason 'login'，不自动走验证流程。

struct KugouError: Error {
    let code: Int
    let message: String
    let upstreamCode: Int?
}

/// QR 二维码 data URL（酷狗与波点共用，做法同 NetEase.swift 的 qrDataURL）。
func scQRCodeDataURL(_ urlString: String) -> String {
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

final class KugouService {
    private let session = SessionStore.shared

    // MARK: - 常量（util/config.json、util/request.js、util/helper.js）

    private static let gateway = "https://gateway.kugou.com"
    private static let loginUserBase = "https://login-user.kugou.com"
    private static let userServiceBase = "https://userservice.kugou.com"
    private static let lyricsBase = "https://lyrics.kugou.com"
    private static let verifyBase = "https://verifyservice.kugou.com"
    private static let appid = 1005
    private static let clientver = 20489
    private static let srcappid = 2919
    private static let ua = "Android15-1070-11083-46-0-DiscoveryDRADprotocol-wifi"
    private static let webSalt = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
    private static let androidSalt = "OIlwieks28dk2k092lksi2UIkp"
    private static let signKeySalt = "57ae12eb6890223e355ccfcb74edf70d"
    private static let signParamsSalt = "R6snCXJgbCaj9WFRJKefTMIFp0ey6Gza"
    private static let signCloudSalt = "ebd1ac3134c880bda6a2194537843caa0162e2e7"
    private static let krcXorKey: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
    private static let randomCharset = Array("1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// util/crypto.js L4 的 publicRasKey（1024 位标准版）。
    private static let rsaPublicKeyPEM = """
        -----BEGIN PUBLIC KEY-----
        MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/gbjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5E221wf/4WLFxwAtRQIDAQAB
        -----END PUBLIC KEY-----
        """

    // MARK: - 设备与登录态

    /// 设备身份：guid（32 位 hex，删了等于换设备）+ dev 名 + mac，持久化。
    private struct Device { var guid: String; var dev: String; var mac: String; var mid: String }
    private var deviceCache: Device?
    /// deviceCache 读写锁（第 10 轮）：device() 曾无同步，song/url 与 lyric 并发请求时
    /// 存在 ARC 竞态；锁顺序单向（deviceLock → SessionStore 锁，无回拿），无死锁。
    private let deviceLock = NSLock()
    /// 官方二维码图地址（key → 含 appid 的完整地址），最多 64 张，对标 start.mjs 的内存 Map。
    private var qrImages: [String: String] = [:]

    private func device() -> Device {
        deviceLock.lock()
        defer { deviceLock.unlock() }
        if let d = deviceCache { return d }
        let saved = session.sidecarAuth("kugou-device")
        let guid: String
        if let g = saved?["guid"] as? String, !g.isEmpty {
            guid = g
        } else {
            guid = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        let dev = (saved?["dev"] as? String ?? "").isEmpty
            ? ("LIZI" + guid.prefix(8)).uppercased() : (saved?["dev"] as? String ?? "")
        let mac = (saved?["mac"] as? String ?? "").isEmpty ? "02:00:00:00:00:00" : (saved?["mac"] as? String ?? "")
        let d = Device(guid: guid, dev: dev, mac: mac, mid: Self.kgCalculateMid(guid))
        session.saveSidecarAuth("kugou-device", ["guid": guid, "dev": dev, "mac": mac])
        deviceCache = d
        return d
    }

    /// 登录态 jar：只收 token / userid / vip_type / vip_token（+ dfid），对标 services/kugou-api/.auth-cookies.json。
    private func jar() -> [String: Any] { session.sidecarAuth("kugou") ?? [:] }
    private func saveJar(_ j: [String: Any]) { session.saveSidecarAuth("kugou", j) }
    private func jarToken() -> String { scStr(jar(), "token") }
    private func jarUserid() -> Int { scInt(jar(), "userid") }

    private func collectSetCookies(_ cookies: [String]) {
        guard !cookies.isEmpty else { return }
        var j = jar()
        for c in cookies {
            for key in ["token", "userid", "vip_type", "vip_token", "dfid"] {
                if let v = Self.kgCookieValue(c, key), !v.isEmpty { j[key] = v }
            }
        }
        saveJar(j)
    }

    // MARK: - 小工具

    /// randomString：字符集 1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ，下标 ceil(35 * random)。
    private static func randomString(_ len: Int) -> String {
        (0..<len).map { _ in
            let idx = Int(ceil(35.0 * Double.random(in: 0..<1)))
            return randomCharset[min(idx, 35)]
        }.map(String.init).joined()
    }

    /// calculateMid：MD5(guid) 的 hex 当 16 进制大整数转 10 进制串。
    private static func kgCalculateMid(_ guid: String) -> String {
        let hex = Crypto.md5Hex(guid)
        var dec = "0"
        for ch in hex {
            let digit = Int(String(ch), radix: 16) ?? 0
            dec = kgDecimalMulAdd(dec, mul: 16, add: digit)
        }
        return dec
    }

    private static func kgDecimalMulAdd(_ dec: String, mul: Int, add: Int) -> String {
        var digits = dec.compactMap { Int(String($0)) }
        var carry = add
        for i in stride(from: digits.count - 1, through: 0, by: -1) {
            let v = digits[i] * mul + carry
            digits[i] = v % 10
            carry = v / 10
        }
        while carry > 0 {
            digits.insert(carry % 10, at: 0)
            carry /= 10
        }
        return digits.map(String.init).joined()
    }

    /// JS 值转签名字符串：数字→十进制，布尔→true/false，对象→JSON，字符串→本身。
    private static func jsString(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as Int: return String(n)
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        case let d as [String: Any]:
            return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        case let a as [Any]:
            return (try? JSONSerialization.data(withJSONObject: a)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        default: return ""
        }
    }

    private static func jsSortedKV(_ params: [String: Any], withEquals: Bool) -> String {
        params.keys.sorted().map { k in
            withEquals ? "\(k)=\(jsString(params[k]))" : "\(k)\(jsString(params[k]))"
        }.joined()
    }

    // MARK: - 签名（util/helper.js）

    /// web：MD5(salt + sort后的 key=value 串 + salt)。注意是先拼 key=value 再对整串排序。
    private static func signatureWebParams(_ params: [String: Any]) -> String {
        let parts = params.keys.map { "\($0)=\(jsString(params[$0]))" }.sorted()
        return Crypto.md5Hex(webSalt + parts.joined() + webSalt)
    }

    /// android：MD5(salt + paramsString + data + salt)，paramsString 为 key 排序后 key=value 拼接。
    private static func signatureAndroidParams(_ params: [String: Any], data: String) -> String {
        Crypto.md5Hex(androidSalt + jsSortedKV(params, withEquals: true) + data + androidSalt)
    }

    /// register：只取值忽略 key，MD5('1014' + sort后的值串 + '1014')。
    private static func signatureRegisterParams(_ params: [String: Any]) -> String {
        let values = params.keys.map { jsString(params[$0]) }.sorted()
        return Crypto.md5Hex("1014" + values.joined() + "1014")
    }

    /// signParams：MD5(key+value 无=拼接 + data + salt)，salt 只在末尾。
    private static func signParams(_ params: [String: Any], data: String) -> String {
        Crypto.md5Hex(jsSortedKV(params, withEquals: false) + data + signParamsSalt)
    }

    /// signKey：MD5(hash + salt + appid + mid + (userid || 0))。
    private static func signKey(_ hash: String, mid: String, userid: Int, appid: Int) -> String {
        Crypto.md5Hex(hash + signKeySalt + String(appid) + mid + String(userid))
    }

    /// signCloudKey：MD5('musicclound' + hash + pid + salt)。
    private static func signCloudKey(_ hash: String, pid: String) -> String {
        Crypto.md5Hex("musicclound" + hash + pid + signCloudSalt)
    }

    /// signParamsKey：MD5(appid + salt + clientver + data)。
    private static func signParamsKey(_ data: String, appid: Int = appid, clientver: Int = clientver) -> String {
        Crypto.md5Hex(String(appid) + androidSalt + String(clientver) + data)
    }

    // MARK: - AES / RSA（util/crypto.js）

    /// AES-CBC + PKCS7：key/iv 作 UTF-8 字节直接用（32 字节 key 即 AES-256）。
    private static func aesCBCEncrypt(_ text: String, key: String, iv: String) -> String? {
        guard let data = text.data(using: .utf8),
              let keyData = key.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else { return nil }
        var outLen = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return out.map { String(format: "%02x", $0) }.joined()
    }

    private static func aesCBCDecryptHex(_ hex: String, key: String, iv: String) -> String? {
        let data = Crypto.hexToData(hex)
        guard !data.isEmpty,
              let keyData = key.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else { return nil }
        var outLen = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return String(data: out, encoding: .utf8)
    }

    /// cryptoAesEncrypt（无固定 key）：tempKey = randomString(16).lowercased()，
    /// key = MD5(tempKey) 前 32 字符，iv = 其后 16 字符；返回 (hex, tempKey)。
    private static func aesEncryptRandom(_ object: [String: Any]) -> (hex: String, key: String)? {
        guard let text = (try? JSONSerialization.data(withJSONObject: object)).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let tempKey = randomString(16).lowercased()
        let derived = Crypto.md5Hex(tempKey)
        let key = String(derived.prefix(32))
        let iv = String(derived.suffix(16))
        guard let hex = aesCBCEncrypt(text, key: key, iv: iv) else { return nil }
        return (hex, tempKey)
    }

    /// playlistAesEncrypt：key = randomString(6).lowercased()，
    /// encryptKey = MD5(key) 前 16 字符，iv = 后 16 字符；返回 (key, Base64密文)。
    private static func playlistAesEncrypt(_ object: [String: Any]) -> (key: String, str: String)? {
        guard let text = (try? JSONSerialization.data(withJSONObject: object)).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let key = randomString(6).lowercased()
        let md5 = Crypto.md5Hex(key)
        let encKey = String(md5.prefix(16))
        let iv = String(md5.suffix(16))
        guard let data = text.data(using: .utf8),
              let keyData = encKey.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else { return nil }
        var outLen = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return (key, out.base64EncodedString())
    }

    private static func playlistAesDecrypt(str: String, key: String) -> [String: Any]? {
        let md5 = Crypto.md5Hex(key)
        let encKey = String(md5.prefix(16))
        let iv = String(md5.suffix(16))
        guard let data = Data(base64Encoded: str),
              let keyData = encKey.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else { return nil }
        var outLen = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        guard let text = String(data: out, encoding: .utf8) else { return nil }
        return scParseJSONObject(text)
    }

    /// RSA 原始加密（无填充）：明文字节放开头、零字节补在末尾到 128 字节；返回小写 hex。
    private static func rsaRawEncrypt(_ text: String) -> String? {
        guard let pemData = rsaPublicKeyDER(),
              let key = rsaSecKey(fromDER: pemData) else { return nil }
        let blockSize = SecKeyGetBlockSize(key)
        guard var plain = text.data(using: .utf8), plain.count <= blockSize else { return nil }
        plain.append(Data(count: blockSize - plain.count))
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, plain as CFData, &error) as Data? else { return nil }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    /// rsaEncrypt2：PKCS#1 v1.5，返回小写 hex。
    private static func rsaPKCS1Encrypt(_ text: String) -> String? {
        guard let pemData = rsaPublicKeyDER(),
              let key = rsaSecKey(fromDER: pemData),
              let plain = text.data(using: .utf8) else { return nil }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plain as CFData, &error) as Data? else { return nil }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    private static func rsaPublicKeyDER() -> Data? {
        let lines = rsaPublicKeyPEM.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        return Data(base64Encoded: lines.joined())
    }

    private static func rsaSecKey(fromDER der: Data) -> SecKey? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }

    // MARK: - 核心请求（util/request.js）

    private struct KGResponse {
        let json: [String: Any]?
        let raw: Data
        let cookies: [String]
        let ssaCode: String?
    }

    /// 默认 query 参数（L73–L107）：dfid / mid / uuid / appid / clientver / clienttime，
    /// 有 token/userid 时追加；clearDefaultParams 时只用调用方参数。
    private func defaultParams(jar j: [String: Any]) -> [String: Any] {
        let d = device()
        var p: [String: Any] = [
            "dfid": scStr(j, "dfid").isEmpty ? "-" : scStr(j, "dfid"),
            "mid": d.mid,
            "uuid": "-",
            "appid": Self.appid,
            "clientver": Self.clientver,
            "clienttime": Int(Date().timeIntervalSince1970),
        ]
        if let token = j["token"] as? String, !token.isEmpty { p["token"] = token }
        if let userid = j["userid"] as? NSNumber, userid.intValue != 0 { p["userid"] = userid.intValue }
        else if let userid = j["userid"] as? Int, userid != 0 { p["userid"] = userid }
        return p
    }

    private func kgRequest(baseURL: String = gateway, path: String, method: String = "GET",
                           params: [String: Any] = [:], body: Any? = nil,
                           encryptType: String = "android", encryptKey: Bool = false,
                           notSignature: Bool = false, clearDefaultParams: Bool = false,
                           extraHeaders: [String: String] = [:],
                           rawResponse: Bool = false, jarOverride: [String: Any]? = nil,
                           timeout: TimeInterval = 20) async throws -> KGResponse {
        // 合并参数（clearDefaultParams 时只用调用方参数；jarOverride 只替换本次的 jar）。
        var allParams: [String: Any] = clearDefaultParams ? [:] : defaultParams(jar: jarOverride ?? jar())
        for (k, v) in params { allParams[k] = v }
        // body 序列化（只序列化一次，签名与发送共用同一串）。
        let bodyString: String
        if let s = body as? String { bodyString = s }
        else if let b = body, let data = try? JSONSerialization.data(withJSONObject: b),
                let s = String(data: data, encoding: .utf8) { bodyString = s }
        else { bodyString = "" }
        // encryptKey 在签名前算出，key 本身进入签名参数集。
        if encryptKey {
            allParams["key"] = Self.signKey(scStr(allParams, "hash"), mid: scStr(allParams, "mid"),
                                            userid: scInt(allParams, "userid"), appid: scInt(allParams, "appid"))
        }
        // 签名。
        if allParams["signature"] == nil && !notSignature {
            switch encryptType {
            case "register": allParams["signature"] = Self.signatureRegisterParams(allParams)
            case "web": allParams["signature"] = Self.signatureWebParams(allParams)
            default: allParams["signature"] = Self.signatureAndroidParams(allParams, data: bodyString)
            }
        }
        // URL + query。
        var comps = URLComponents(string: baseURL + path) ?? URLComponents()
        comps.queryItems = allParams.map { URLQueryItem(name: $0.key, value: Self.jsString($0.value)) }
        guard let url = comps.url else {
            throw KugouError(code: -1, message: "酷狗请求构造失败", upstreamCode: nil)
        }
        // 头：UA + 调用方头 + dfid/clienttime/mid + kg-* 固定头。
        let d = device()
        var headers: [String: String] = ["User-Agent": Self.ua]
        for (k, v) in extraHeaders { headers[k] = v }
        headers["dfid"] = scStr(allParams, "dfid")
        headers["clienttime"] = Self.jsString(allParams["clienttime"])
        headers["mid"] = d.mid
        headers["kg-rc"] = "1"
        headers["kg-thash"] = "5d816a0"
        headers["kg-rec"] = "1"
        headers["kg-rf"] = "B9EDA08A64250DEFFBCADDEE00F8F25F"
        var bodyData: Data?
        if method == "POST", !bodyString.isEmpty {
            bodyData = bodyString.data(using: .utf8)
            if headers["Content-Type"] == nil {
                headers["Content-Type"] = (body is String) ? "application/x-www-form-urlencoded" : "application/json"
            }
        }
        let (data, resp) = try await Upstream.fetch(url, headers: headers, timeout: timeout, method: method, body: bodyData)
        let ssaCode = resp.value(forHTTPHeaderField: "ssa-code") ?? resp.value(forHTTPHeaderField: "SSA-CODE")
        let cookies = Self.kgParseSetCookie(resp.value(forHTTPHeaderField: "Set-Cookie"))
        if rawResponse {
            return KGResponse(json: nil, raw: data, cookies: cookies, ssaCode: ssaCode)
        }
        guard let obj = Upstream.jsonObject(data) else {
            throw KugouError(code: 502, message: "酷狗返回无法解析", upstreamCode: nil)
        }
        // 判定：status === 0 或 error_code 非 0 → 502。注意 status 字段缺失时不算失败
        //（Node 的判定是 response.data.status === 0，undefined 不触发）。
        let hasStatus = obj["status"] != nil
        let status = scInt(obj, "status")
        let errorCode = obj["error_code"] != nil ? scInt(obj, "error_code") : 0
        if (hasStatus && status == 0) || (obj["error_code"] != nil && errorCode != 0) {
            let msg = [scStr(obj, "msg"), scStr(obj, "error_msg"), scStr(obj, "errmsg")]
                .first(where: { !$0.isEmpty }) ?? "酷狗接口失败"
            throw KugouError(code: 502, message: msg, upstreamCode: errorCode != 0 ? errorCode : status)
        }
        var out = obj
        if let ssa = ssaCode, !ssa.isEmpty { out["ssaCode"] = ssa }
        return KGResponse(json: out, raw: data, cookies: cookies, ssaCode: ssaCode)
    }

    /// Set-Cookie 合并串切分（对标 kuwo 的做法：逗号 + 含 = 的 token 处切分）。
    private static func kgParseSetCookie(_ header: String?) -> [String] {
        guard let header, !header.isEmpty else { return [] }
        let re = try? NSRegularExpression(pattern: #",(?=\s*[^;=]+=[^;]*)"#)
        let ns = NSRange(header.startIndex..., in: header)
        var parts: [String] = []
        var last = header.startIndex
        for m in re?.matches(in: header, range: ns) ?? [] {
            let r = Range(m.range, in: header)!
            parts.append(String(header[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(header[last...]))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
            .map { kgStripCookieAttrs($0) }
            .filter { !$0.isEmpty }
    }

    private static func kgStripCookieAttrs(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\s*(Domain|domain|path|expires)=[^;]*;*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: ";HttpOnly", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// cookieToJson：按 ; 切、逐段 trim、key=value（值里含 = 只取第一段后）。
    private static func kgCookieValue(_ cookie: String, _ name: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == name {
                return String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

extension KugouService {
    // MARK: - 设备注册（module/register_dev.js）

    /// POST userservice.kugou.com/risk/v2/r_register_dev。
    /// 成功时把返回的 dfid 写进 jar。主服务不自动调它（song/url 用随机 dfid 的 Node 做法）。
    private func registerDev() async throws -> [String: Any]? {
        let d = device()
        let dataMap: [String: Any] = [
            "availableRamSize": 4983533568, "availableRomSize": 48114719, "availableSDSize": 48114717,
            "basebandVer": "", "batteryLevel": 100, "batteryStatus": 3, "brand": "Redmi",
            "buildSerial": "unknown", "device": "marble",
            "imei": d.guid, "imsi": "", "manufacturer": "Xiaomi", "uuid": d.guid,
            "accelerometer": false, "gravity": false, "gyroscope": false, "light": false,
            "magnetic": false, "orientation": false, "pressure": false, "step_counter": false,
            "temperature": false,
            "accelerometerValue": "", "gravityValue": "", "gyroscopeValue": "", "lightValue": "",
            "magneticValue": "", "orientationValue": "", "pressureValue": "",
            "step_counterValue": "", "temperatureValue": "",
        ]
        guard let enc = Self.playlistAesEncrypt(dataMap) else { return nil }
        let pObj: [String: Any] = ["aes": enc.key, "uid": jarUserid(), "token": jarToken()]
        guard let pText = (try? JSONSerialization.data(withJSONObject: pObj)).flatMap({ String(data: $0, encoding: .utf8) }),
              let p = Self.rsaPKCS1Encrypt(pText) else { return nil }
        let resp = try await kgRequest(baseURL: Self.userServiceBase, path: "/risk/v2/r_register_dev",
                                       method: "POST",
                                       params: ["part": 1, "platid": 1, "p": p],
                                       body: enc.str, encryptType: "android", rawResponse: true)
        let body = Self.playlistAesDecrypt(str: resp.raw.base64EncodedString(), key: enc.key) ?? [:]
        if scInt(body, "status") == 1,
           let data = body["data"] as? [String: Any],
           let dfid = data["dfid"] as? String, !dfid.isEmpty {
            var j = jar()
            j["dfid"] = dfid
            saveJar(j)
        }
        return body
    }

    // MARK: - 扫码登录

    /// key：GET login-user.kugou.com/v2/qrcode（web 签名）。
    /// key 取 data.qrcode || data.key；再不行从官方图地址里提 qrcode=。
    private func loginQrKey() async throws -> String {
        let resp = try await kgRequest(baseURL: Self.loginUserBase, path: "/v2/qrcode", method: "GET",
                                       params: ["appid": 1001, "type": 1, "plat": 4,
                                                "qrcode_txt": "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=\(Self.appid)&",
                                                "srcappid": Self.srcappid],
                                       encryptType: "web")
        let data = (resp.json?["data"] as? [String: Any]) ?? [:]
        var key = scStr(data, "qrcode")
        if key.isEmpty { key = scStr(data, "key") }
        if key.isEmpty { key = scStr(data, "qrCode") }
        var imageURL: String?
        for (_, v) in data {
            if let s = v as? String, s.contains("qrcode=") {
                imageURL = s
                if key.isEmpty, let range = s.range(of: "qrcode=") {
                    key = String(s[range.upperBound...]).components(separatedBy: "&").first ?? ""
                }
            }
        }
        guard !key.isEmpty else {
            throw KugouError(code: 502, message: "拿不到二维码 key", upstreamCode: nil)
        }
        qrImages[key] = imageURL ?? "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=\(Self.appid)&qrcode=\(key)"
        if qrImages.count > 64, let oldest = qrImages.keys.first { qrImages.removeValue(forKey: oldest) }
        return key
    }

    /// create：本地画官方图地址的二维码（带 appid 的完整地址，见 start.mjs 的修正）。
    private func loginQrCreate(key: String) -> String {
        let url = qrImages[key] ?? "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=\(key)"
        return scQRCodeDataURL(url)
    }

    /// check：GET login-user.kugou.com/v2/get_userinfo_qrcode（web 签名，带 dev）。
    /// 状态 0/1/2/4 → 800/801/802/803；4 时收 token/userid/vip 进 jar 并补昵称头像。
    private func loginQrCheck(key: String) async throws -> [String: Any] {
        let d = device()
        let resp = try await kgRequest(baseURL: Self.loginUserBase, path: "/v2/get_userinfo_qrcode",
                                       method: "GET",
                                       params: ["plat": 4, "appid": Self.appid, "srcappid": Self.srcappid,
                                                "qrcode": key, "dev": d.dev],
                                       encryptType: "web", timeout: 25)
        let data = (resp.json?["data"] as? [String: Any]) ?? [:]
        let st = scInt(data, "status")
        let map = [0: 800, 1: 801, 2: 802, 4: 803]
        var out: [String: Any] = ["code": map[st] ?? 801, "state": st]
        if st == 4 {
            collectSetCookies(resp.cookies)
            var j = jar()
            for k in ["token", "userid", "vip_type", "vip_token"] {
                if let v = data[k] { j[k] = v }
            }
            saveJar(j)
            out["loggedIn"] = true
            if let detail = try? await userDetail(), detail["ok"] as? Bool == true {
                out["nickname"] = detail["nickname"] as? String ?? ""
                out["avatar"] = detail["avatar"] as? String ?? ""
            }
        }
        return out
    }

    // MARK: - 用户详情与 status

    /// POST /v3/get_my_info（p 为 RSA 原始加密 {"token","clienttime"} 后转大写 hex）。
    private func userDetail() async throws -> [String: Any] {
        let clienttime = Int(Date().timeIntervalSince1970)
        let pkObj: [String: Any] = ["token": jarToken(), "clienttime": clienttime]
        guard let pkText = (try? JSONSerialization.data(withJSONObject: pkObj)).flatMap({ String(data: $0, encoding: .utf8) }),
              let pk = Self.rsaRawEncrypt(pkText)?.uppercased() else {
            throw KugouError(code: 502, message: "酷狗用户详情失败", upstreamCode: nil)
        }
        let body: [String: Any] = ["visit_time": clienttime, "usertype": 1, "p": pk, "userid": jarUserid()]
        let resp = try await kgRequest(path: "/v3/get_my_info", method: "POST",
                                       params: ["plat": 1], body: body, encryptType: "android",
                                       extraHeaders: ["x-router": "usercenter.kugou.com"])
        let b = resp.json ?? [:]
        let d = (b["data"] as? [String: Any]) ?? [:]
        let ok = scInt(b, "status") == 1
        let nickname = ok ? (scStr(d, "nickname").isEmpty ? (scStr(d, "user_name").isEmpty ? "酷狗用户" : scStr(d, "user_name")) : scStr(d, "nickname")) : ""
        let avatar = ok ? (scStr(d, "pic").isEmpty ? scStr(d, "avatar") : scStr(d, "pic")) : ""
        let uid = ok ? (scStr(d, "userid").isEmpty ? String(jarUserid()) : scStr(d, "userid")) : ""
        return ["ok": ok, "nickname": nickname, "avatar": avatar, "uid": uid,
                "vip": ok ? (scInt(d, "vip_type") > 0) : false]
    }

    private func status() async -> HttpResponse {
        guard !jarToken().isEmpty else {
            return .json(200, ["code": 200, "loggedIn": false])
        }
        do {
            let detail = try await userDetail()
            let ok = detail["ok"] as? Bool ?? false
            return .json(200, ["code": 200, "loggedIn": ok,
                                "nickname": ok ? (detail["nickname"] as? String ?? "") : "",
                                "avatar": ok ? (detail["avatar"] as? String ?? "") : "",
                                "uid": ok ? (detail["uid"] as? String ?? "") : "",
                                "vip": ok ? (detail["vip"] as? Bool ?? false) : false,
                                "error": ok ? NSNull() : "登录态可能已过期（重新扫码）"])
        } catch {
            return .json(200, ["code": 200, "loggedIn": false, "error": "登录态可能已过期（重新扫码）"])
        }
    }

    // MARK: - 播放地址

    private static func magicQuality(_ q: String) -> String {
        ["piano", "acappella", "subwoofer", "ancient", "dj", "surnay"].contains(q) ? "magic_\(q)" : q
    }

    /// kugouUrlOf：d = data.data || data；one = 数组取首项；url 取 one.url || one.urls[0]。
    private func kgUrlOf(_ body: [String: Any]) -> (url: String, preview: Bool, upstream: String?) {
        let dRaw = body["data"] ?? body
        let one: [String: Any]
        if let arr = dRaw as? [[String: Any]] { one = arr.first ?? [:] }
        else if let dict = dRaw as? [String: Any] { one = dict }
        else { one = [:] }
        var raw: Any? = one["url"]
        if raw == nil, let urls = one["urls"] as? [Any] { raw = urls.first }
        var url = ""
        if let arr = raw as? [Any] { url = arr.first as? String ?? "" }
        else if let s = raw as? String { url = s }
        let preview = ((one["free_part"] as? NSNumber)?.boolValue ?? false)
            || ((one["is_free_part"] as? NSNumber)?.boolValue ?? false)
        var upstream: String?
        if let e = body["error"] as? String, !e.isEmpty { upstream = e }
        else if let m = body["message"] as? String, !m.isEmpty { upstream = m }
        else if let ec = body["errcode"] as? NSNumber { upstream = "errcode \(ec.intValue)" }
        else if one["status"] != nil, scInt(one, "status") != 1 { upstream = "status \(scInt(one, "status"))" }
        return (url, preview, upstream)
    }

    private func kugouUrl(hash: String, albumId: Int, audioId: Int, quality: String, freePart: Bool) async -> (url: String, preview: Bool, upstream: String?) {
        // cookie 里强制塞 dfid（无则 randomString(24)），调用方 cookie 覆盖它。
        var jarOverride = jar()
        if scStr(jarOverride, "dfid").isEmpty { jarOverride["dfid"] = Self.randomString(24) }
        let params: [String: Any] = [
            "album_id": albumId, "area_code": 1, "hash": hash, "ssa_flag": "is_fromtrack",
            "version": 11430, "page_id": 151369488, "quality": Self.magicQuality(quality),
            "album_audio_id": audioId, "behavior": "play", "pid": 2, "cmd": 26,
            "pidversion": 3001, "IsFreePart": freePart ? 1 : 0,
            "ppage_id": "463467626,350369493,788954147", "cdnBackup": 1, "module": "",
            "clientver": 11430,
        ]
        do {
            // 注意：上游 song_url.js 写的是 notSign: true，但 request.js 只认
            // notSignature，所以上游实际是带 android 签名的（key 也进签名集）。
            // 这里绝不能加 notSignature: true——不带签名上游回 errcode 20006
            // "err signature"，平台取址直接断（2026-11-18 实测）。
            let resp = try await kgRequest(path: "/v5/url", method: "GET", params: params,
                                           encryptType: "android", encryptKey: true,
                                           extraHeaders: ["x-router": "trackercdn.kugou.com"],
                                           jarOverride: jarOverride)
            return kgUrlOf(resp.json ?? [:])
        } catch {
            return ("", false, (error as? KugouError)?.message)
        }
    }

    private func songUrl(req: HttpRequest) async -> HttpResponse {
        let hash = (req.string("hash").isEmpty ? req.string("id") : req.string("hash")).lowercased()
        guard !hash.isEmpty else { return .json(400, ["code": 400, "error": "hash required"]) }
        let albumId = req.int("albumId", 0)
        let audioId = req.int("albumAudioId", 0)
        var quality = req.string("quality", "128")
        if !["128", "320", "flac"].contains(quality) { quality = "128" }
        var pick = await kugouUrl(hash: hash, albumId: albumId, audioId: audioId, quality: quality, freePart: false)
        if pick.url.isEmpty {
            pick = await kugouUrl(hash: hash, albumId: albumId, audioId: audioId, quality: quality, freePart: true)
        }
        let upstream = pick.upstream ?? ""
        let needLogin = upstream.range(of: "20028|需要验证|check r failed", options: .regularExpression) != nil
        DiagLog.shared.recordPlaybackStep("kugou song/url hash=\(hash.prefix(8)) url=\(pick.url.isEmpty ? "EMPTY" : "OK") upstream=\(upstream)")
        return .json(200, ["code": 200, "hash": hash, "url": pick.url, "preview": pick.preview,
                            "quality": pick.preview ? "preview" : quality,
                            "reason": pick.url.isEmpty ? (needLogin ? "login" : "unavailable") : NSNull(),
                            "upstream": pick.upstream.map { $0 as Any } ?? NSNull()])
    }

    // MARK: - 搜索

    private func search(req: HttpRequest) async -> HttpResponse {
        let s = req.string("s").isEmpty ? req.string("keywords") : req.string("s")
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(200, ["code": 200, "source": "kugou", "tracks": [], "songCount": 0])
        }
        let limit = scClamp(req.int("limit", 20), 1, 30)
        let page = max(1, req.int("page", 1))
        let typeRaw = req.string("type", "song")
        let type = ["special", "lyric", "song", "album", "author", "mv"].contains(typeRaw) ? typeRaw : "song"
        let path = type == "song" ? "/v3/search/song" : "/v1/search/\(type)"
        do {
            let resp = try await kgRequest(path: path, method: "GET",
                                           params: ["albumhide": 0, "iscorrection": 1, "keyword": s,
                                                    "nocollect": 0, "page": page, "pagesize": limit,
                                                    "platform": "AndroidFilter"],
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "complexsearch.kugou.com"])
            let b = resp.json ?? [:]
            let d = (b["data"] as? [String: Any]) ?? [:]
            let lists = scArr(d, "lists")
            if lists.isEmpty {
                let err = [scStr(b, "error"), scStr(b, "message")].first(where: { !$0.isEmpty })
                    ?? (scInt(b, "status") == 1 ? "没有结果" : "酷狗搜索失败")
                return .json(200, ["code": 200, "source": "kugou", "tracks": [], "songCount": 0, "error": err])
            }
            let tracks = lists.compactMap { kugouTrack($0) }
                .filter { !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks,
                                "songCount": scInt(d, "total") == 0 ? lists.count : scInt(d, "total")])
        } catch {
            return .json(200, ["code": 502, "source": "kugou", "tracks": [], "songCount": 0,
                                "error": (error as? KugouError)?.message ?? "酷狗搜索失败"])
        }
    }

    // MARK: - 歌词（两步：search/lyric → download）

    /// KRC 解码：base64 → 跳前 4 字节 → 循环 XOR → zlib 解压 → UTF-8。
    private static func kgDecodeKRC(_ base64: String) -> String {
        guard var bytes = Data(base64Encoded: base64), bytes.count > 4 else { return "" }
        bytes.removeFirst(4)
        var out = [UInt8](repeating: 0, count: bytes.count)
        for i in 0..<bytes.count { out[i] = bytes[i] ^ krcXorKey[i % krcXorKey.count] }
        guard let inflated = kgZlibInflate(Data(out)) else { return "" }
        return String(data: inflated, encoding: .utf8) ?? ""
    }

    private static func kgZlibInflate(_ data: Data) -> Data? {
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

    /// LRCLIB 兜底（第 11 轮）：官方无候选/空内容/异常时，用前端 srcLyric 传来的
    /// 元数据（s/artist/album/duration）查一次。成功回 syncedLyrics，失败回
    /// nil，调用方保持原来的空返回——不把兜底失败伪装成别的东西。
    private func lrclibFallback(req: HttpRequest) async -> (lyric: String, yrc: String)? {
        await Lrclib.fetch(artist: req.string("artist"), track: req.string("s"),
                           album: req.string("album"), duration: req.int("duration"))
    }

    private func lyric(req: HttpRequest) async -> HttpResponse {
        let hash = req.string("hash").isEmpty ? req.string("id") : req.string("hash")
        let keyword = req.string("s")
        guard !hash.isEmpty || !keyword.isEmpty else {
            return .json(400, ["code": 400, "error": "hash or s required"])
        }
        do {
            // 注意：上游 search_lyric.js 写的是 notSign: true，但 request.js 只认
            // notSignature，所以上游实际是带 android 签名的。这里绝不能加
            // notSignature: true——不带签名 lyrics.kugou.com 回 200 空体
            // （2026-11-18 实测：无签名 len 0，有签名 3480 字节正常出候选）。
            let sr = try await kgRequest(baseURL: Self.lyricsBase, path: "/v1/search", method: "GET",
                                         params: ["album_audio_id": req.int("album_audio_id", 0),
                                                  "appid": Self.appid, "clientver": Self.clientver,
                                                  "duration": req.int("duration", 0), "hash": hash,
                                                  "keyword": keyword.isEmpty ? hash : keyword,
                                                  "lrctxt": 1, "man": "no"],
                                         encryptType: "android", clearDefaultParams: true)
            let sBody = sr.json ?? [:]
            let candidates = (sBody["candidates"] as? [[String: Any]])
                ?? ((sBody["data"] as? [String: Any])?["candidates"] as? [[String: Any]]) ?? []
            let hit = candidates.first(where: { !scStr($0, "id").isEmpty && !scStr($0, "accesskey").isEmpty })
                ?? candidates.first
            guard let hit, !scStr(hit, "id").isEmpty, !scStr(hit, "accesskey").isEmpty else {
                // 2026-11-18 第 9 轮：真机上酷狗播了没歌词，分不清是取不到还是显示不出；
                // 之前 lyric() 全程零日志。记一条，进设置页诊断（/api/diag/search）就能看到。
                DiagLog.shared.recordLog(category: "lyric",
                    message: "kugou lyric no candidate hash=\(hash.prefix(8)) s=\(keyword) candidates=\(candidates.count)",
                    fields: ["host": "lyrics.kugou.com", "reason": "lyric-no-candidate"])
                DiagLog.shared.recordPlaybackStep("kugou lyric-no-candidate hash=\(hash.prefix(8))")
                // 第 11 轮：官方无候选，走 LRCLIB 兜底；兜底也空才回 none。
                if let fb = await lrclibFallback(req: req) {
                    DiagLog.shared.recordPlaybackStep("kugou lyric-lrclib-ok hash=\(hash.prefix(8))")
                    return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": "", "tlyric": "",
                                        "format": "lrc"])
                }
                return .json(200, ["code": 200, "lyric": "", "yrc": "", "tlyric": "", "format": "none"])
            }
            let lr = try await kgRequest(baseURL: Self.lyricsBase, path: "/download", method: "GET",
                                         params: ["ver": 1, "client": "android", "id": scStr(hit, "id"),
                                                  "accesskey": scStr(hit, "accesskey"), "fmt": "krc",
                                                  "charset": "utf8"],
                                         encryptType: "android")
            let lBody = lr.json ?? [:]
            let content = scStr(lBody, "content")
            guard !content.isEmpty else {
                DiagLog.shared.recordLog(category: "lyric",
                    message: "kugou lyric empty content id=\(scStr(hit, "id"))",
                    fields: ["host": "lyrics.kugou.com", "reason": "lyric-empty-content"])
                DiagLog.shared.recordPlaybackStep("kugou lyric-empty-content id=\(scStr(hit, "id"))")
                // 第 11 轮：官方空内容，走 LRCLIB 兜底；兜底也空才回 none。
                if let fb = await lrclibFallback(req: req) {
                    DiagLog.shared.recordPlaybackStep("kugou lyric-lrclib-ok hash=\(hash.prefix(8))")
                    return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": "", "tlyric": "",
                                        "format": "lrc"])
                }
                return .json(200, ["code": 200, "lyric": "", "yrc": "", "tlyric": "", "format": "none"])
            }
            let decoded: String
            if scInt(lBody, "contenttype") != 0 {
                decoded = Data(base64Encoded: content).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            } else {
                decoded = Self.kgDecodeKRC(content)
            }
            let isKrc = decoded.range(of: #"^\[\d+,\d+\]"#, options: [.regularExpression, .anchored]) != nil
                || decoded.range(of: #"\n\[\d+,\d+\]"#, options: .regularExpression) != nil
            if isKrc {
                let lrc = krcToLrc(decoded)
                let yrc = krcToYrc(decoded)
                // 只记行数/长度，不记歌词正文。
                DiagLog.shared.recordLog(category: "lyric",
                    message: "kugou lyric ok format=\(yrc.isEmpty ? "lrc" : "yrc") lrcChars=\(lrc.count) yrcChars=\(yrc.count)",
                    fields: ["host": "lyrics.kugou.com", "reason": "lyric-ok"])
                DiagLog.shared.recordPlaybackStep("kugou lyric-ok format=\(yrc.isEmpty ? "lrc" : "yrc")")
                return .json(200, ["code": 200, "lyric": lrc, "yrc": yrc, "tlyric": "",
                                    "format": yrc.isEmpty ? "lrc" : "yrc"])
            }
            // 第 11 轮：解码后是空串（等价于官方空内容），先走兜底，别记 lyric-ok。
            if decoded.isEmpty, let fb = await lrclibFallback(req: req) {
                DiagLog.shared.recordPlaybackStep("kugou lyric-lrclib-ok hash=\(hash.prefix(8))")
                return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": "", "tlyric": "",
                                    "format": "lrc"])
            }
            DiagLog.shared.recordLog(category: "lyric",
                message: "kugou lyric ok format=lrc decodedChars=\(decoded.count)",
                fields: ["host": "lyrics.kugou.com", "reason": "lyric-ok"])
            DiagLog.shared.recordPlaybackStep("kugou lyric-ok format=lrc")
            return .json(200, ["code": 200, "lyric": decoded, "yrc": "", "tlyric": "",
                                "format": decoded.isEmpty ? "none" : "lrc"])
        } catch {
            DiagLog.shared.recordLog(category: "lyric",
                message: "kugou lyric failed: \((error as? KugouError)?.message ?? "酷狗歌词失败")",
                fields: ["host": "lyrics.kugou.com", "reason": "lyric-error"])
            // 第 11 轮：官方异常也试一次兜底（LRCLIB 是另一个 host，酷狗挂了它
            // 未必挂）。官方异常日志上面已经记了，这里只记兜底命中，不把
            // 官方异常伪装成兜底成功；兜底也失败时回原来的 error 形状。
            if let fb = await lrclibFallback(req: req) {
                DiagLog.shared.recordPlaybackStep("kugou lyric-lrclib-ok-after-error hash=\(hash.prefix(8))")
                return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": "", "tlyric": "",
                                    "format": "lrc"])
            }
            return .json(200, ["code": 200, "lyric": "", "yrc": "", "tlyric": "", "format": "none",
                                "error": (error as? KugouError)?.message ?? "酷狗歌词失败"])
        }
    }
}

extension KugouService {
    // MARK: - 归一化（spec §2.5；搜索结果 PascalCase，列表接口小写）

    private func kgFirstInt(_ d: [String: Any], _ keys: [String]) -> Int {
        for k in keys where d[k] != nil { return scInt(d, k) }
        return 0
    }

    private func kugouTrack(_ it: [String: Any]) -> [String: Any]? {
        let hash = scStr(it, "FileHash")
        guard !hash.isEmpty else { return nil }
        var name = scStr(it, "SongName")
        if name.isEmpty {
            let fn = scStr(it, "FileName")
            if let range = fn.range(of: " - ") { name = String(fn[range.upperBound...]) } else { name = fn }
        }
        let singers = scArr(it, "Singers")
        var artists = singers.map { scStr($0, "name") }.filter { !$0.isEmpty }.joined(separator: " / ")
        if artists.isEmpty {
            let sn = scStr(it, "SingerName")
            let parts = sn.components(separatedBy: CharacterSet(charactersIn: "[、,&]"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            artists = parts.joined(separator: " / ")
        }
        if artists.isEmpty { artists = "未知歌手" }
        let cover = scStr(scDict(it, "trans_param"), "union_cover").replacingOccurrences(of: "{size}", with: "240")
        return [
            "id": hash, "source": "kugou", "name": name, "artists": artists,
            "artistIds": singers.map { scStr($0, "id") }.filter { !$0.isEmpty },
            "album": scStr(it, "AlbumName"),
            "albumId": scStrOrNum(it, "AlbumID"),
            "cover": cover,
            "duration": scInt(it, "Duration") * 1000,
            "fee": scInt(it, "PayType") > 0 ? 1 : 0,
            "hash": hash,
            "albumAudioId": scInt(it, "Audioid") == 0 ? scInt(it, "MixSongID") : scInt(it, "Audioid"),
            "albumIdNum": scInt(it, "AlbumID"),
        ]
    }

    private func kugouListTrack(_ it: [String: Any]) -> [String: Any]? {
        var hash = scStr(it, "hash")
        if hash.isEmpty { hash = scStr(it, "FileHash") }
        if hash.isEmpty { hash = scStrOrNum(it, "id") }
        guard !hash.isEmpty else { return nil }
        var name = scStr(it, "songname")
        var artists = scStr(it, "author_name")
        if name.isEmpty || artists.isEmpty {
            let fn = scStr(it, "filename")
            if let range = fn.range(of: " - ") {
                if artists.isEmpty { artists = String(fn[..<range.lowerBound]) }
                if name.isEmpty { name = String(fn[range.upperBound...]) }
            } else if name.isEmpty { name = fn }
        }
        if artists.isEmpty { artists = "未知歌手" }
        var cover = scStr(scDict(it, "trans_param"), "union_cover")
        if cover.isEmpty { cover = scStr(it, "sizable_cover") }
        if cover.isEmpty { cover = scStr(it, "album_sizable_cover") }
        cover = cover.replacingOccurrences(of: "{size}", with: "240")
        var duration = scInt(it, "timelength")
        if duration == 0 { duration = scInt(it, "time_length") * 1000 }
        return [
            "id": hash, "source": "kugou", "name": name, "artists": artists, "artistIds": [],
            "album": scStr(it, "album_name"), "cover": cover, "duration": duration,
            "fee": scInt(it, "pay_type") > 0 ? 1 : 0, "hash": hash,
            "albumAudioId": scInt(it, "audio_id") == 0 ? scInt(it, "mixsongid") : scInt(it, "audio_id"),
            "albumIdNum": scInt(it, "album_id"),
        ]
    }

    private func kugouPlaylistTrack(_ it: [String: Any]) -> [String: Any]? {
        var hash = scStr(it, "hash")
        if hash.isEmpty { hash = scStr(it, "FileHash") }
        if hash.isEmpty { hash = scStrOrNum(it, "id") }
        guard !hash.isEmpty else { return nil }
        let full = scStr(it, "songname").isEmpty ? scStr(it, "filename") : scStr(it, "songname")
        guard !full.isEmpty else { return nil }
        var name = full
        var artists = "未知歌手"
        if let range = full.range(of: " - ") {
            artists = String(full[..<range.lowerBound])
            name = String(full[range.upperBound...])
        }
        var duration = scInt(it, "timelen")
        if duration == 0 { duration = scInt(it, "timelength") }
        return [
            "id": hash, "source": "kugou", "name": name, "artists": artists, "artistIds": [],
            "album": scStr(it, "album_name"), "cover": "", "duration": duration,
            "fee": kgFirstInt(it, ["feetype", "pay_type"]) > 0 ? 1 : 0, "hash": hash,
            "albumAudioId": scInt(it, "audio_id") == 0 ? scInt(it, "mixsongid") : scInt(it, "audio_id"),
            "albumIdNum": scInt(it, "album_id"),
        ]
    }

    private func kugouFmTrack(_ it: [String: Any]) -> [String: Any]? {
        var hash = scStr(it, "hash")
        if hash.isEmpty { hash = scStr(it, "FileHash") }
        if hash.isEmpty { hash = scStrOrNum(it, "id") }
        guard !hash.isEmpty else { return nil }
        let name = scStr(it, "songname").isEmpty ? scStr(it, "filename") : scStr(it, "songname")
        guard !name.isEmpty else { return nil }
        let artists = scStr(it, "author_name").isEmpty ? "未知歌手" : scStr(it, "author_name")
        var duration = scInt(it, "time")
        if duration == 0 { duration = scInt(it, "timelength") }
        return [
            "id": hash, "source": "kugou", "name": name, "artists": artists, "artistIds": [],
            "album": "", "cover": "", "duration": duration,
            "fee": scInt(it, "pay_type") > 0 ? 1 : 0, "hash": hash,
            "albumAudioId": 0, "albumIdNum": 0,
        ]
    }

    private func kugouFmStation(_ it: [String: Any], _ cls: [String: Any]) -> [String: Any]? {
        let fmid = scStrOrNum(it, "fmid")
        guard !fmid.isEmpty else { return nil }
        let imgurl = scStr(it, "imgurl").replacingOccurrences(of: "{size}", with: "240")
        return [
            "id": fmid, "source": "kugou",
            "name": scStr(it, "fmname").isEmpty ? "未命名电台" : scStr(it, "fmname"),
            "cover": imgurl, "trackCount": scArr(it, "songlist").count, "playCount": 0,
            "creator": ["nickname": scStr(cls, "classname")],
        ]
    }

    private func kugouPlaylist(_ it: [String: Any]) -> [String: Any]? {
        let id = [scStrOrNum(it, "global_collection_id"), scStrOrNum(it, "listid"),
                  scStrOrNum(it, "list_id"), scStrOrNum(it, "specialid")].first(where: { !$0.isEmpty }) ?? ""
        guard !id.isEmpty else { return nil }
        var cover = [scStr(it, "img_url"), scStr(it, "imgurl"), scStr(it, "pic"), scStr(it, "cover")]
            .first(where: { !$0.isEmpty }) ?? ""
        cover = cover.replacingOccurrences(of: "{size}", with: "400")
        let name = scStr(it, "name").isEmpty
            ? (scStr(it, "title").isEmpty ? "未命名歌单" : scStr(it, "title")) : scStr(it, "name")
        return [
            "id": id, "source": "kugou", "name": name, "cover": cover,
            "trackCount": kgFirstInt(it, ["songcount", "song_count", "total"]),
            "playCount": kgFirstInt(it, ["playcount", "play_count"]),
            "creator": ["nickname": scStr(it, "nickname")],
        ]
    }

    // MARK: - 其余路由

    private func topSongs(req: HttpRequest) async -> HttpResponse {
        let type = req.int("type", 0)
        let rankId = type > 1 ? type : 21608
        do {
            let resp = try await kgRequest(path: "/musicadservice/container/v1/newsong_publish", method: "POST",
                                           body: ["rank_id": rankId, "userid": jarUserid(),
                                                  "page": max(1, req.int("page", 1)),
                                                  "pagesize": scClamp(req.int("limit", 30), 1, 100),
                                                  "tags": []] as [String: Any],
                                           encryptType: "android")
            let list = (resp.json?["data"] as? [[String: Any]]) ?? []
            if list.isEmpty {
                let err = [scStr(resp.json ?? [:], "errmsg"), scStr(resp.json ?? [:], "error")]
                    .first(where: { !$0.isEmpty }) ?? "新歌速递没有返回内容"
                return .json(200, ["code": 200, "source": "kugou", "tracks": [], "error": err])
            }
            let tracks = list.compactMap { kugouListTrack($0) }.filter { !($0["id"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "tracks": [],
                                "error": (error as? KugouError)?.message ?? "酷狗新歌速递失败"])
        }
    }

    private func everydayRecommend(req: HttpRequest) async -> HttpResponse {
        do {
            let resp = try await kgRequest(path: "/everyday_song_recommend", method: "POST",
                                           params: ["platform": req.string("platform", "ios")],
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "everydayrec.service.kugou.com"])
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            let tracks = scArr(d, "song_list").compactMap { kugouListTrack($0) }
                .filter { !($0["id"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks,
                                "cover": scStr(d, "cover_img_url"), "date": scStr(d, "creation_date")])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "tracks": [],
                                "error": (error as? KugouError)?.message ?? "酷狗每日推荐失败"])
        }
    }

    private func playlistTracks(req: HttpRequest) async -> HttpResponse {
        let id = req.string("id")
        guard !id.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        let page = max(1, req.int("page", 1))
        let pagesize = scClamp(req.int("limit", 30), 1, 100)
        do {
            let resp = try await kgRequest(path: "/pubsongs/v2/get_other_list_file_nofilt", method: "GET",
                                           params: ["area_code": 1, "begin_idx": (page - 1) * pagesize,
                                                    "plat": 1, "type": 1, "mode": 1, "personal_switch": 1,
                                                    "extend_fields": "abtags,hot_cmt,popularization",
                                                    "pagesize": pagesize, "global_collection_id": id],
                                           encryptType: "android")
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            var list = scArr(d, "songs")
            if list.isEmpty { list = scArr(d, "info") }
            if list.isEmpty { list = scArr(d, "list") }
            let tracks = list.compactMap { kugouPlaylistTrack($0) }
                .filter { !($0["id"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty }
            let count = scInt(d, "count") != 0 ? scInt(d, "count")
                : (scInt(d, "total") != 0 ? scInt(d, "total") : list.count)
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks, "trackCount": count])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "tracks": [],
                                "error": (error as? KugouError)?.message ?? "酷狗歌单取不到"])
        }
    }

    /// 我的歌单逐页翻到底（最多 20 页），供路由与 playlist/create 回读共用。
    private func fetchUserPlaylists(pageSize: Int) async throws -> [[String: Any]] {
        var playlists: [[String: Any]] = []
        var seen = Set<String>()
        var page = 1
        while page <= 20 {
            let resp = try await kgRequest(path: "/v7/get_all_list", method: "POST",
                                           params: ["plat": 1, "userid": jarUserid(), "token": jarToken()],
                                           body: ["userid": jarUserid(), "token": jarToken(),
                                                  "total_ver": 979, "type": 2,
                                                  "page": page, "pagesize": pageSize] as [String: Any],
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "cloudlist.service.kugou.com"])
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            guard let info = d["info"] as? [[String: Any]] else {
                if page == 1 {
                    throw KugouError(code: 401, message: "先在卡片上扫码登录酷狗（这个接口要登录）", upstreamCode: nil)
                }
                break
            }
            if info.isEmpty { break }
            for it in info {
                if let p = kugouPlaylist(it), let pid = p["id"] as? String, !seen.contains(pid) {
                    seen.insert(pid)
                    playlists.append(p)
                }
            }
            let total = scInt(d, "total")
            if info.count < pageSize { break }
            if total > 0 && playlists.count >= total { break }
            page += 1
        }
        return playlists
    }

    private func userPlaylists(req: HttpRequest) async -> HttpResponse {
        let pageSize = scClamp(req.int("pagesize", 100), 1, 100)
        do {
            let playlists = try await fetchUserPlaylists(pageSize: pageSize)
            return .json(200, ["code": 200, "source": "kugou", "playlists": playlists])
        } catch let e as KugouError {
            return .json(200, ["code": e.code, "source": "kugou", "playlists": [], "error": e.message])
        } catch {
            return .json(200, ["code": 502, "source": "kugou", "playlists": [], "error": "酷狗歌单失败"])
        }
    }

    private func fmClass() async -> HttpResponse {
        do {
            let dateTime = Int(Date().timeIntervalSince1970 * 1000)
            let body: [String: Any] = [
                "kguid": jarUserid(), "clienttime": dateTime, "mid": device().mid, "platform": "android",
                "clientver": Self.clientver, "uid": jarUserid(), "get_tracker": 1,
                "key": Self.signParamsKey(String(dateTime)), "appid": Self.appid,
            ]
            let resp = try await kgRequest(path: "/v1/class_fm_song", method: "POST", body: body,
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "fm.service.kugou.com"])
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            var stations: [[String: Any]] = []
            for cls in scArr(d, "class_list") {
                for fm in scArr(cls, "fmlist") {
                    if let s = kugouFmStation(fm, cls) { stations.append(s) }
                }
            }
            return .json(200, ["code": 200, "source": "kugou", "stations": stations])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "stations": [],
                                "error": (error as? KugouError)?.message ?? "酷狗电台分类失败"])
        }
    }

    private func fmSongs(req: HttpRequest) async -> HttpResponse {
        let fmid = req.string("fmid").isEmpty ? req.string("id") : req.string("fmid")
        guard !fmid.isEmpty else { return .json(400, ["code": 400, "error": "fmid required"]) }
        let size = scClamp(req.int("limit", 30), 1, 100)
        do {
            let dateTime = Int(Date().timeIntervalSince1970 * 1000)
            var fmData: [[String: Any]] = fmid.components(separatedBy: ",").map {
                ["fmid": $0.trimmingCharacters(in: .whitespaces), "fmtype": req.int("type", 2),
                 "offset": req.int("offset", -1), "size": size, "singername": ""]
            }
            let fmtypeParts = req.string("fmtype").components(separatedBy: ",")
            for (i, part) in fmtypeParts.enumerated() where i < fmData.count {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)) { fmData[i]["fmtype"] = n }
            }
            let fmoffsetParts = req.string("fmoffset").components(separatedBy: ",")
            for (i, part) in fmoffsetParts.enumerated() where i < fmData.count {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)) { fmData[i]["offset"] = n }
            }
            let fmsizeParts = req.string("fmsize").components(separatedBy: ",")
            for (i, part) in fmsizeParts.enumerated() where i < fmData.count {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)) { fmData[i]["size"] = n }
            }
            let body: [String: Any] = [
                "appid": Self.appid, "area_code": 1, "clienttime": dateTime, "clientver": Self.clientver,
                "data": fmData, "get_tracker": 1, "key": Self.signParamsKey(String(dateTime)),
                "mid": device().mid, "uid": jarUserid(),
            ]
            let resp = try await kgRequest(path: "/v1/app_song_list_offset", method: "POST", body: body,
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "fm.service.kugou.com",
                                                          "Content-Type": "application/json"])
            let blocks = (resp.json?["data"] as? [[String: Any]]) ?? []
            let songs = blocks.flatMap { scArr($0, "songs") }
            if songs.isEmpty {
                let err = [scStr(resp.json ?? [:], "error"), scStr(resp.json ?? [:], "message")]
                    .first(where: { !$0.isEmpty }) ?? "这个电台没有返回曲目"
                return .json(200, ["code": 200, "source": "kugou", "tracks": [], "error": err])
            }
            let tracks = songs.compactMap { kugouFmTrack($0) }.filter { !($0["id"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "tracks": [],
                                "error": (error as? KugouError)?.message ?? "酷狗电台失败"])
        }
    }

    private func topPlaylists(req: HttpRequest) async -> HttpResponse {
        do {
            let dateTime = String(Int(Date().timeIntervalSince1970))
            let body: [String: Any] = [
                "appid": Self.appid, "mid": device().mid, "clientver": Self.clientver,
                "platform": "android", "clienttime": dateTime, "userid": jarUserid(),
                "module_id": req.int("module_id", 1), "page": max(1, req.int("page", 1)),
                "pagesize": scClamp(req.int("limit", 12), 1, 50),
                "key": Self.signParamsKey(dateTime),
                "special_recommend": ["withtag": req.int("withtag", 1), "withsong": req.int("withsong", 1),
                                      "sort": req.int("sort", 1), "ugc": 1, "is_selected": 0,
                                      "withrecommend": 1, "area_code": 1,
                                      "categoryid": req.int("category_id", 0)] as [String: Any],
                "req_multi": 1, "retrun_min": 5, "return_special_falg": 1,
            ]
            let resp = try await kgRequest(path: "/v2/special_recommend", method: "POST", body: body,
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "specialrec.service.kugou.com"])
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            let playlists = scArr(d, "special_list").compactMap { kugouPlaylist($0) }
                .filter { !($0["id"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "playlists": playlists])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "playlists": [],
                                "error": (error as? KugouError)?.message ?? "酷狗歌单失败"])
        }
    }

    private func recommendSongs() async -> HttpResponse {
        do {
            let resp = try await kgRequest(path: "/everyday_song_recommend", method: "POST",
                                           body: ["platform": "android", "userid": jarUserid()] as [String: Any],
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "everydayrec.service.kugou.com"])
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            let tracks = scArr(d, "song_list").compactMap { kugouListTrack($0) }
                .filter { !($0["id"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "tracks": [],
                                "error": (error as? KugouError)?.message ?? "酷狗每日推荐失败"])
        }
    }

    private func personalFm(req: HttpRequest) async -> HttpResponse {
        do {
            let dateTime = Int(Date().timeIntervalSince1970 * 1000)
            var body: [String: Any] = [
                "appid": Self.appid, "clienttime": dateTime, "mid": device().mid,
                "action": req.string("action", "play"), "recommend_source_locked": 0,
                "song_pool_id": req.int("song_pool_id", 0), "callerid": 0, "m_type": 1,
                "platform": req.string("platform", "ios"), "area_code": 1,
                "remain_songcnt": req.int("remain_songcnt", 0), "clientver": Self.clientver,
                "is_overplay": req.int("is_overplay", 0) == 1 ? 1 : 0,
                "mode": req.string("mode", "normal"),
                "fakem": "ca981cfc583a4c37f28d2d49000013c16a0a",
                "key": Self.signParamsKey(String(dateTime)),
            ]
            if jarUserid() != 0 { body["userid"] = jarUserid(); body["kguid"] = jarUserid() }
            if !jarToken().isEmpty { body["token"] = jarToken() }
            if scInt(jar(), "vip_type") != 0 { body["vip_type"] = scInt(jar(), "vip_type") }
            if !req.string("hash").isEmpty { body["hash"] = req.string("hash") }
            if req.int("songid", 0) != 0 { body["songid"] = req.int("songid", 0) }
            if req.int("playtime", 0) != 0 { body["playtime"] = req.int("playtime", 0) }
            let resp = try await kgRequest(path: "/v2/personal_recommend", method: "POST", body: body,
                                           encryptType: "android",
                                           extraHeaders: ["x-router": "persnfm.service.kugou.com"])
            let d = (resp.json?["data"] as? [String: Any]) ?? [:]
            let tracks = scArr(d, "song_list").compactMap { kugouListTrack($0) }
                .filter { !($0["id"] as? String ?? "").isEmpty }
            return .json(200, ["code": 200, "source": "kugou", "tracks": tracks])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502, "source": "kugou", "tracks": [],
                                "error": (error as? KugouError)?.message ?? "酷狗私人 FM 失败"])
        }
    }

    private func playlistCreate(req: HttpRequest) async -> HttpResponse {
        guard !jarToken().isEmpty, jarUserid() != 0 else {
            return .json(200, ["code": 401, "error": "先在卡片上扫码登录酷狗"])
        }
        let name = req.string("name")
        guard !name.isEmpty else { return .json(400, ["code": 400, "error": "name required"]) }
        do {
            let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
            let resp = try await kgRequest(path: "/cloudlist.service/v5/add_list", method: "POST",
                                           params: ["last_time": Int(Date().timeIntervalSince1970),
                                                    "last_area": "gztx", "userid": jarUserid(),
                                                    "token": jarToken(), "_": stamp],
                                           body: ["userid": jarUserid(), "token": jarToken(), "total_ver": 0,
                                                  "name": name, "type": 0, "source": 1, "is_pri": 0,
                                                  "list_create_userid": jarUserid(),
                                                  "list_create_gid": "", "from_shupinmv": 0] as [String: Any],
                                           encryptType: "android", timeout: 25)
            let b = resp.json ?? [:]
            let d = (b["data"] as? [String: Any]) ?? b
            let ok = scInt(d, "error_code") == 0 && (d["status"] == nil || scInt(d, "status") == 1)
            guard ok else {
                let code = scInt(d, "error_code") == 0 ? 502 : scInt(d, "error_code")
                let err = [scStr(d, "error_msg"), scStr(d, "errmsg"), scStr(d, "message")]
                    .first(where: { !$0.isEmpty })
                    ?? "酷狗建歌单失败（status \(d["status"] != nil ? scInt(d, "status") : 200)）"
                return .json(200, ["code": code, "error": err])
            }
            var listid = [scStrOrNum(d, "listid"), scStrOrNum(d, "list_id"), scStrOrNum(d, "list_create_listid")]
                .first(where: { !$0.isEmpty }) ?? ""
            if listid.isEmpty {
                // 回读 /user/playlist 按歌单名找。
                if let found = try? await fetchUserPlaylists(pageSize: 100),
                   let p = found.first(where: { ($0["name"] as? String ?? "") == name }),
                   let pid = p["id"] as? String, !pid.isEmpty {
                    listid = pid
                }
            }
            guard !listid.isEmpty else {
                return .json(200, ["code": 502, "error": "酷狗建歌单返回成功，但回读不到 listid（请到酷狗确认是否已建出）"])
            }
            return .json(200, ["code": 200, "listid": listid,
                                "playlist": ["id": listid, "name": name]])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502,
                                "error": (error as? KugouError)?.message ?? "酷狗建歌单失败"])
        }
    }

    private func playlistTracksAdd(req: HttpRequest) async -> HttpResponse {
        guard !jarToken().isEmpty, jarUserid() != 0 else {
            return .json(200, ["code": 401, "error": "先在卡片上扫码登录酷狗"])
        }
        let listid = req.string("listid").isEmpty ? req.string("pid") : req.string("listid")
        guard !listid.isEmpty else { return .json(400, ["code": 400, "error": "listid required"]) }
        let body = req.jsonBody()
        var picks: [[String: Any]] = []
        if let arr = body["picks"] as? [[String: Any]] { picks = arr }
        else if let arr = body["songs"] as? [[String: Any]] { picks = arr }
        guard !picks.isEmpty else { return .json(400, ["code": 400, "error": "picks required"]) }
        var rows: [String] = []
        var missing = 0
        for p in picks {
            let hash = scStr(p, "hash")
            let id = scStrOrNum(p, "id")
            let isHex32 = id.count == 32 && id.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil
            guard !hash.isEmpty || isHex32 else { missing += 1; continue }
            let name = (scStr(p, "name").isEmpty ? scStr(p, "title") : scStr(p, "name"))
                .replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "|", with: " ")
            let albumId = scInt(p, "albumId") == 0 ? scInt(p, "albumIdNum") : scInt(p, "albumId")
            let mix = scInt(p, "albumAudioId")
            rows.append("\(name)|\(hash.isEmpty ? id : hash)|\(albumId)|\(mix)")
        }
        if missing > 0 {
            return .json(400, ["code": 400, "error": "有 \(missing) 首缺少酷狗 hash，无法定位歌曲（重新搜索后再写入）"])
        }
        do {
            let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
            let resp = try await kgRequest(path: "/cloudlist.service/v6/add_song", method: "POST",
                                           params: ["last_time": Int(Date().timeIntervalSince1970),
                                                    "last_area": "gztx", "userid": jarUserid(),
                                                    "token": jarToken(), "_": stamp],
                                           body: ["userid": jarUserid(), "token": jarToken(), "listid": listid,
                                                  "list_ver": 0, "type": 0, "slow_upload": 1,
                                                  "scene": "false;null", "data": rows.joined(separator: ",")] as [String: Any],
                                           encryptType: "android", timeout: 30)
            let b = resp.json ?? [:]
            let d = (b["data"] as? [String: Any]) ?? b
            let ok = scInt(d, "error_code") == 0 && (d["status"] == nil || scInt(d, "status") == 1)
            guard ok else {
                let code = scInt(d, "error_code") == 0 ? 502 : scInt(d, "error_code")
                let err = [scStr(d, "error_msg"), scStr(d, "errmsg"), scStr(d, "message")]
                    .first(where: { !$0.isEmpty }) ?? "酷狗写歌单失败"
                return .json(200, ["code": code, "error": err])
            }
            return .json(200, ["code": 200, "listid": listid, "added": rows.count])
        } catch {
            return .json(200, ["code": (error as? KugouError)?.code ?? 502,
                                "error": (error as? KugouError)?.message ?? "酷狗写歌单失败"])
        }
    }

    // MARK: - 20028 验证（get/verify/info、verify/user/info，直通上游）

    private func getVerifyInfo(req: HttpRequest) async -> HttpResponse {
        do {
            let resp = try await kgRequest(path: "/verifyservice/v3/get_verify_info", method: "POST",
                                           body: ["eventid": req.string("eventid"), "userid": jarUserid(),
                                                  "platid": req.int("platid", 2), "rtype": 1, "wasm": 1,
                                                  "i": "", "sid": "", "edt": ""] as [String: Any],
                                           encryptType: "android")
            return .json(200, resp.json ?? [:])
        } catch {
            return .json(502, ["code": 502, "error": (error as? KugouError)?.message ?? "酷狗验证失败"])
        }
    }

    private func verifyUserInfo(req: HttpRequest) async -> HttpResponse {
        do {
            let vType = req.int("v_type", 23)
            var body: [String: Any] = [
                "eventid": req.string("eventid"), "userid": jarUserid(), "platid": req.int("platid", 2),
                "v_type": vType, "wasm": 1, "i": "",
                "sid": req.string("sid").removingPercentEncoding ?? req.string("sid"),
                "edt": req.string("edt").removingPercentEncoding ?? req.string("edt"),
            ]
            if vType == 23 {
                guard let enc = Self.aesEncryptRandom([:]) else {
                    throw KugouError(code: 502, message: "酷狗验证失败", upstreamCode: nil)
                }
                body["verifycode"] = req.string("verifycode").removingPercentEncoding ?? req.string("verifycode")
                body["pk"] = Self.rsaRawEncrypt("{\"key\":\"\(enc.key)\"}") ?? ""
                body["params"] = enc.hex
            } else if vType == 32 {
                let code = req.string("verifycode")
                guard let enc = Self.aesEncryptRandom(["code": code]) else {
                    throw KugouError(code: 502, message: "酷狗验证失败", upstreamCode: nil)
                }
                body["code"] = code.removingPercentEncoding ?? code
                body["pk"] = Self.rsaRawEncrypt("{\"key\":\"\(enc.key)\"}") ?? ""
                body["params"] = enc.hex
            }
            let resp = try await kgRequest(baseURL: Self.verifyBase, path: "/v4/verify_user_info",
                                           method: "POST", params: ["clientver": 11510], body: body,
                                           encryptType: "android")
            return .json(200, resp.json ?? [:])
        } catch {
            return .json(502, ["code": 502, "error": (error as? KugouError)?.message ?? "酷狗验证失败"])
        }
    }

    // MARK: - 分发

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/kugou/".count))
        do {
            switch part {
            case "", "health":
                return .json(200, ["code": 200, "ok": true, "loggedIn": !jarToken().isEmpty])
            case "status", "login/status":
                return await status()
            case "login/qr/key":
                do {
                    let key = try await loginQrKey()
                    return .json(200, ["code": 200, "key": key])
                } catch let e as KugouError {
                    return .json(200, ["code": 502, "key": NSNull(), "error": e.message])
                }
            case "login/qr/create":
                let key = req.string("key")
                guard !key.isEmpty else { return .json(400, ["code": 400, "error": "key required"]) }
                let img = loginQrCreate(key: key)
                if img.isEmpty {
                    return .json(200, ["code": 502, "qrimg": "", "key": key, "error": "二维码生成失败（上游没给图片）"])
                }
                return .json(200, ["code": 200, "key": key, "qrimg": img])
            case "login/qr/check":
                let key = req.string("key")
                guard !key.isEmpty else { return .json(400, ["code": 400, "error": "key required"]) }
                return .json(200, try await loginQrCheck(key: key))
            case "logout":
                session.clearSidecarAuth("kugou")
                return .json(200, ["code": 200, "loggedIn": false])
            case "register/dev":
                let body = try await registerDev() ?? [:]
                return .json(200, ["code": 200, "data": body])
            case "search":
                return await search(req: req)
            case "song/url":
                return await songUrl(req: req)
            case "lyric":
                return await lyric(req: req)
            case "top/songs":
                return await topSongs(req: req)
            case "everyday/recommend":
                return await everydayRecommend(req: req)
            case "playlist/tracks":
                return await playlistTracks(req: req)
            case "user/playlists":
                return await userPlaylists(req: req)
            case "fm/class":
                return await fmClass()
            case "fm/songs":
                return await fmSongs(req: req)
            case "top/playlists":
                return await topPlaylists(req: req)
            case "recommend/songs":
                return await recommendSongs()
            case "personal/fm":
                return await personalFm(req: req)
            case "playlist/create":
                return await playlistCreate(req: req)
            case "playlist/tracks/add":
                return await playlistTracksAdd(req: req)
            case "get/verify/info":
                return await getVerifyInfo(req: req)
            case "verify/user/info":
                return await verifyUserInfo(req: req)
            default:
                return .json(404, ["code": 404, "error": "unknown kugou api: \(part)"])
            }
        } catch {
            return .json(502, ["code": 502, "error": (error as? KugouError)?.message ?? error.localizedDescription])
        }
    }
}
