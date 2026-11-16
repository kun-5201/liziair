import Foundation
import CommonCrypto
import Security

/// 网易云 weapi / eapi 加密。对标 server.mjs 顶部的加密段。
/// 常量值直接从 server.mjs 抄：PRESET_KEY / IV / PUB_KEY / MODULUS / EAPI_KEY / EAPI_SEP。
/// 各边车共用 md5Hex / hexToData，故另起别名 Crypto。
typealias Crypto = NetEaseCrypto

enum NetEaseCrypto {
    static let presetKey = "0CoJUm6Qyw8W8jud"
    static let iv = "0102030405060708"
    static let pubKey = "010001"
    static let modulus = "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
    static let eapiKey = "e82ckenh8dichen8"
    static let eapiSep = "-36cd479b6b5-"

    private static let base62 = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func randomKey() -> String {
        (0..<16).map { _ in String(base62[Int.random(in: 0..<62)]) }.joined()
    }

    // MARK: - AES

    private static func aesEncrypt(_ data: Data, key: Data, iv: Data?, mode: CCOptions) -> Data? {
        var outLen = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        // 先把容量取出来：out 被 withUnsafeMutableBytes 独占借用期间，
        // 里面再读 out.count 会触发独占性冲突。
        let outCapacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    if let iv {
                        return iv.withUnsafeBytes { ivPtr in
                            CCCrypt(
                                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), mode,
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLen
                            )
                        }
                    }
                    return CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), mode,
                        keyPtr.baseAddress, key.count,
                        nil,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress, outCapacity, &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return out
    }

    /// AES-128-CBC + PKCS7（weapi 用）。
    static func aesCBC(_ text: String, key: String) -> String? {
        guard let data = text.data(using: .utf8),
              let keyData = key.data(using: .utf8),
              let ivData = iv.data(using: .utf8),
              let enc = aesEncrypt(data, key: keyData, iv: ivData, mode: CCOptions(kCCOptionPKCS7Padding)) else { return nil }
        return enc.base64EncodedString()
    }

    /// AES-128-ECB + PKCS7（eapi 用），返回大写 hex。
    static func aesECBHex(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let keyData = eapiKey.data(using: .utf8),
              let enc = aesEncrypt(data, key: keyData, iv: nil, mode: CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding)) else { return nil }
        return enc.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - RSA（原始 RSA：m^e mod n，SecKey kSecKeyAlgorithmRSAEncryptionRaw）

    // 本地服务多线程并发调 weapiRequest 都会碰这个缓存，NSLock 保护。
    private static var cachedPublicKey: SecKey?
    private static let publicKeyLock = NSLock()

    /// 用 modulus/exponent 拼 DER SubjectPublicKeyInfo，建 SecKey。
    static func rsaPublicKey() -> SecKey? {
        publicKeyLock.lock()
        defer { publicKeyLock.unlock() }
        if let k = cachedPublicKey { return k }
        let modulusBytes = hexToData(modulus)
        let exponentBytes = hexToData(pubKey)
        // DER: SEQUENCE { SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }, BIT STRING { SEQUENCE { INTEGER modulus, INTEGER exponent } } }
        var inner = Data()
        inner.append(derInteger(modulusBytes))
        inner.append(derInteger(exponentBytes))
        let rsaSeq = derSequence(inner)
        var algId = Data()
        algId.append(derOID([1, 2, 840, 113549, 1, 1, 1]))
        algId.append(derNull())
        let algSeq = derSequence(algId)
        var bitStringContent = Data([0x00])
        bitStringContent.append(rsaSeq)
        var spki = Data()
        spki.append(algSeq)
        spki.append(derBitString(bitStringContent))
        let spkiSeq = derSequence(spki)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(spkiSeq as CFData, attrs as CFDictionary, nil) else { return nil }
        cachedPublicKey = key
        return key
    }

    private static func derLength(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }
    private static func derInteger(_ data: Data) -> Data {
        // 去前导 0（至少留 1 字节）；最高位为 1 时前面补 0x00（保证正数）。
        // 全程在 [UInt8] 上算、最后拼新 Data：不要在同一个 Data 上
        // removeFirst/insert——崩溃日志证实 Data.insert(0x00, at: 0) 在此
        // 路径会 trap（EXC_BREAKPOINT，modulus 首字节 0x00 去掉后剩 0xe0）。
        let bytes = [UInt8](data)
        var start = 0
        while start + 1 < bytes.count && bytes[start] == 0x00 { start += 1 }
        var body: [UInt8] = bytes.isEmpty ? [0x00] : Array(bytes[start...])
        if body[0] & 0x80 != 0 { body = [0x00] + body }
        return Data([0x02]) + derLength(body.count) + Data(body)
    }
    private static func derSequence(_ body: Data) -> Data {
        Data([0x30]) + derLength(body.count) + body
    }
    private static func derBitString(_ body: Data) -> Data {
        Data([0x03]) + derLength(body.count) + body
    }
    private static func derNull() -> Data { Data([0x05, 0x00]) }
    private static func derOID(_ arcs: [Int]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var stack: [UInt8] = [UInt8(arc & 0x7f)]
            var v = arc >> 7
            while v > 0 { stack.insert(UInt8((v & 0x7f) | 0x80), at: 0); v >>= 7 }
            body.append(contentsOf: stack)
        }
        return Data([0x06]) + derLength(body.count) + body
    }

    static func hexToData(_ hex: String) -> Data {
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) { data.append(b) }
            idx = next
        }
        return data
    }

    /// weapi 的 encSecKey：密钥倒序 -> hex -> 模幂 -> 256 位 hex。
    /// SecKey 原始 RSA 不做 padding，等价于 m^e mod n。
    static func rsaEncrypt(_ text: String) -> String? {
        let reversed = String(text.reversed())
        guard let reversedData = reversed.data(using: .utf8),
              let key = rsaPublicKey() else { return nil }
        // 密钥是 16 字节 ASCII；倒序后转 hex 再当大整数加密——和 Node 版的
        // BigInt('0x' + reversedHex) 完全等价：加密输入就是倒序文本的 UTF-8 字节。
        let modulusLen = 128
        var plain = Data(count: modulusLen)
        // 右对齐：前面补 0。
        if reversedData.count > modulusLen { return nil }
        plain.replaceSubrange(modulusLen - reversedData.count..<modulusLen, with: reversedData)
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            key, .rsaEncryptionRaw, plain as CFData, &error) as Data? else { return nil }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MD5（eapi 摘要用）

    static func md5Hex(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - weapi / eapi 入口

    /// weapi：{ params, encSecKey }，和 server.mjs 的 weapi() 一致。
    static func weapi(_ object: [String: Any]) -> (params: String, encSecKey: String)? {
        guard let json = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: json, encoding: .utf8) else { return nil }
        let key = randomKey()
        guard let step1 = aesCBC(text, key: presetKey),
              let params = aesCBC(step1, key: key),
              let encSecKey = rsaEncrypt(key) else { return nil }
        return (params, encSecKey)
    }

    /// eapi header：上游按它判断客户端。deviceId 进程内随机生成一次并复用；
    /// buildver / requestId 每次调用都重新生成，不可缓存。
    private static let eapiDeviceId: String = {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }()

    static func eapiHeader(csrf: String = "") -> [String: Any] {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return [
            "osver": "Microsoft-Windows-10-Professional-build-19045-64bit",
            "deviceId": eapiDeviceId,
            "appver": "3.1.17.204416",
            "versioncode": "140",
            "mobilename": "",
            "buildver": String(nowMs / 1000).prefix(10).description,
            "resolution": "1920x1080",
            "__csrf": csrf,
            "os": "pc",
            "channel": "netease",
            "requestId": "\(nowMs)_\(String(format: "%04d", Int.random(in: 0..<1000)))",
        ]
    }

    /// eapi（server.mjs 的 eapi() 原样）：
    /// text = JSON({ ...object, header })；digest = md5("nobody" + apiPath + "use" + text + "md5forencrypt")；
    /// 明文 = apiPath + sep + text + sep + digest；AES-128-ECB 加密后转大写 hex。
    /// apiPath 用 /api/... 形式（如 /api/login/qrcode/unikey）。
    static func eapi(apiPath: String, object: [String: Any], csrf: String = "") -> String? {
        var merged = object
        merged["header"] = eapiHeader(csrf: csrf)
        guard let json = try? JSONSerialization.data(withJSONObject: merged),
              let text = String(data: json, encoding: .utf8) else { return nil }
        let digest = md5Hex("nobody" + apiPath + "use" + text + "md5forencrypt")
        let plain = apiPath + eapiSep + text + eapiSep + digest
        return aesECBHex(plain)
    }
}
