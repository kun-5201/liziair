import Foundation

/// 落雪（LX）音源解析 —— Swift 版。
/// 1:1 翻译 services/lx-api/lx-resolver.mjs（已在 fork 里）。
/// 协议兼容 lx-music-api-server v3；内置解析，不需要再起独立 LX 服务。
/// 私有 LX 音源脚本（Ciallo / 溯音 / upload.js）不在这里、不打进包。
/// LX_API_URL 设了就代理外部自建 lx-music-api-server（自定义音源脚本跑在那台服务上）。

enum LXResolver {
    static let oiapiKey = "oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575"

    /// 外部 LX 服务地址（App 设置里可填，默认空 = 内置解析）。
    /// 注意：iOS App 没有环境变量，ContentView 启动时从 UserDefaults 读 "lxApiUrl" 写入这里。
    static var externalApiURL: String = ""
    static var externalApiKey: String = ""

    /// liziair 的 source 名 -> LX 的 source 名。汽水 / 波点 / Spotify 没有 LX 解析。
    static let sourceMap: [String: String] = [
        "netease": "wy", "qq": "tx", "kugou": "kg", "kuwo": "kw",
        "qishui": "", "bodian": "", "spotify": "",
    ]

    static let tiers = ["master", "atmos", "hires", "flac24bit", "flac", "320k", "128k"]

    static let tierNames: [String: String] = [
        "master": "超清母带 Master", "atmos": "杜比全景声 Dolby Atmos",
        "hires": "Hi-Res", "flac24bit": "Hi-Res / FLAC 24-bit",
        "flac": "无损 FLAC", "320k": "极高 320 kbps", "128k": "标准 128 kbps",
    ]

    static func normalizeQuality(_ q: String?) -> String {
        guard let q, !q.isEmpty else { return "master" }
        let s = q.lowercased().replacingOccurrences(of: "[\\s_-]", with: "", options: .regularExpression)
        let map: [String: String] = [
            "jymaster": "master", "master": "master",
            "atmos": "atmos", "dolbyatmos": "atmos", "spatial": "atmos", "surround": "atmos",
            "jyeffect": "atmos", "hires": "hires", "flac24bit": "flac24bit", "24bit": "flac24bit",
            "flac": "flac", "lossless": "flac", "320k": "320k", "320": "320k", "exhigh": "320k",
            "128k": "128k", "128": "128k", "standard": "128k", "higher": "320k",
        ]
        return map[s] ?? "master"
    }

    private static func tiersFrom(_ quality: String) -> [String] {
        let idx = tiers.firstIndex(of: normalizeQuality(quality)) ?? 0
        return Array(tiers[idx...])
    }

    private static func isHttpUrl(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    // MARK: - 各平台解析（返回地址字符串，或带实际档位的 (url, quality)）

    private static let qqBR: [String: Int] = ["master": 1, "atmos": 2, "hires": 3, "flac24bit": 3, "flac": 4, "320k": 5, "128k": 7]

    static func resolveTx(_ songId: String, tier: String) async throws -> String {
        let br = qqBR[tier] ?? 7
        var comps = URLComponents(string: "https://oiapi.net/api/QQ_Music")!
        var items = [
            URLQueryItem(name: "key", value: oiapiKey),
            URLQueryItem(name: "type", value: "json"),
            URLQueryItem(name: "br", value: String(br)),
            URLQueryItem(name: "n", value: "1"),
        ]
        if songId.allSatisfy({ $0.isNumber }) { items.append(URLQueryItem(name: "songid", value: songId)) }
        else { items.append(URLQueryItem(name: "mid", value: songId)) }
        comps.queryItems = items
        let data = try await Upstream.fetchJSON(comps.url!) as? [String: Any]
        if let url = data?["music"] as? String, isHttpUrl(url) { return url }
        if let url = data?["url"] as? String, isHttpUrl(url) { return url }
        if let msg = data?["message"] as? String,
           let range = msg.range(of: "音频链接：") {
            let rest = msg[range.upperBound...]
            let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
            let candidate = String(rest[..<lineEnd]).trimmingCharacters(in: .whitespaces)
            if isHttpUrl(candidate) { return candidate }
        }
        throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "QQ 未返回音频链接"])
    }

    private static let wyYZ: [String: String] = ["128k": "1", "320k": "2", "flac": "3", "flac24bit": "4", "hires": "5", "atmos": "6", "master": "7"]

    /// 网易云：主接口 s0o1（按档位），备用 oiapi（不分档位，给 mp3，如实报 128k）。
    /// 返回 (url, quality?)：quality 有值时以它为准，否则用正在试的档位。
    static func resolveWy(_ songId: String, tier: String) async throws -> (String, String?) {
        do {
            let yz = wyYZ[tier] ?? "1"
            var comps = URLComponents(string: "https://www.s0o1.com/API/wyy_music")!
            comps.queryItems = [URLQueryItem(name: "id", value: songId), URLQueryItem(name: "yz", value: yz)]
            let data = try await Upstream.fetchJSON(comps.url!, headers: ["User-Agent": "Mozilla/5.0"]) as? [String: Any]
            if (data?["status"] as? Int) == 200, (data?["success"] as? Bool) == true,
               let d = data?["data"] as? [String: Any], let url = d["url"] as? String, isHttpUrl(url) {
                return (url, nil)
            }
            throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: (data?["message"] as? String) ?? "s0o1 未返回音频链接"])
        } catch {
            var backupErr = "备用接口未返回音频链接"
            do {
                var comps = URLComponents(string: "https://oiapi.net/api/Music_163")!
                comps.queryItems = [URLQueryItem(name: "id", value: songId)]
                let data = try await Upstream.fetchJSON(comps.url!) as? [String: Any]
                if (data?["code"] as? Int) == 0, let d = data?["data"] {
                    // oiapi 的 data 有三种形状：数组、单个对象、{ items:[...] }。
                    let song: [String: Any]?
                    if let arr = d as? [[String: Any]] { song = arr.first }
                    else if let obj = d as? [String: Any] {
                        if let items = obj["items"] as? [[String: Any]] { song = items.first }
                        else { song = obj }
                    } else { song = nil }
                    if let url = song?["url"] as? String, isHttpUrl(url) {
                        return (url, "128k")
                    }
                }
            } catch let be {
                backupErr = "备用接口请求失败: \(be.localizedDescription)"
            }
            throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "网易解析失败: 主接口 \(error.localizedDescription)；\(backupErr)"])
        }
    }

    private static let kwBR: [String: Int] = ["master": 1, "atmos": 1, "hires": 1, "flac24bit": 1, "flac": 1, "320k": 2, "128k": 3]

    static func resolveKw(_ songId: String, tier: String) async throws -> String {
        let br = kwBR[tier] ?? 3
        var comps = URLComponents(string: "https://oiapi.net/api/Kuwo")!
        comps.queryItems = [
            URLQueryItem(name: "msg", value: songId),
            URLQueryItem(name: "n", value: "1"),
            URLQueryItem(name: "br", value: String(br)),
        ]
        let data = try await Upstream.fetchJSON(comps.url!) as? [String: Any]
        if let d = data?["data"] as? [String: Any], let url = d["url"] as? String, isHttpUrl(url) { return url }
        if let msg = data?["message"] as? String,
           let range = msg.range(of: "音乐链接：") {
            let rest = String(msg[range.upperBound...])
            let candidate = rest.split(separator: " ").first.map(String.init) ?? rest
            if isHttpUrl(candidate) { return candidate }
        }
        throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "酷我未返回音频链接"])
    }

    static func resolveMg(_ songId: String) async throws -> String {
        var comps = URLComponents(string: "https://api.xcvts.cn/api/music/migu")!
        comps.queryItems = [
            URLQueryItem(name: "gm", value: songId),
            URLQueryItem(name: "n", value: "1"),
            URLQueryItem(name: "num", value: "1"),
            URLQueryItem(name: "type", value: "json"),
        ]
        let data = try await Upstream.fetchJSON(comps.url!) as? [String: Any]
        if (data?["code"] as? Int) == 200, let url = data?["music_url"] as? String, isHttpUrl(url) { return url }
        throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "咪咕未返回音频链接"])
    }

    static func resolveKg(_ songId: String, tier: String) async throws -> String {
        var hash: String?
        if songId.count == 32 && songId.allSatisfy({ $0.isHexDigit }) { hash = songId }
        if hash == nil {
            var comps = URLComponents(string: "http://mobilecdn.kugou.com/api/v3/search/song")!
            comps.queryItems = [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "keyword", value: songId),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pagesize", value: "1"),
                URLQueryItem(name: "showtype", value: "1"),
            ]
            let data = try await Upstream.fetchJSON(comps.url!) as? [String: Any]
            if let d = data?["data"] as? [String: Any],
               let info = d["info"] as? [[String: Any]],
               let h = info.first?["hash"] as? String { hash = h }
            guard hash != nil else {
                throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "酷狗未搜到歌曲"])
            }
        }
        var comps = URLComponents(string: "http://m.kugou.com/app/i/getSongInfo.php")!
        comps.queryItems = [
            URLQueryItem(name: "cmd", value: "playInfo"),
            URLQueryItem(name: "hash", value: hash!),
            URLQueryItem(name: "from", value: "mkugou"),
        ]
        let info = try await Upstream.fetchJSON(comps.url!) as? [String: Any]
        if let url = info?["url"] as? String, isHttpUrl(url) { return url }
        if let d = info?["data"] as? [String: Any], let url = d["url"] as? String, isHttpUrl(url) { return url }
        throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "酷狗未返回音频链接"])
    }

    // MARK: - 统一入口

    /// 按档位从高到低回退，返回 (url, 实际档位)。
    static func resolveMusicUrl(source: String, songId: String, quality: String) async throws -> (String, String) {
        guard !songId.isEmpty else {
            throw NSError(domain: "LX", code: 6, userInfo: [NSLocalizedDescriptionKey: "缺少歌曲 ID"])
        }
        var errors: [String] = []
        for tier in tiersFrom(quality) {
            do {
                switch source {
                case "tx":
                    return (try await resolveTx(songId, tier: tier), tier)
                case "wy":
                    let (url, actual) = try await resolveWy(songId, tier: tier)
                    return (url, actual ?? tier)
                case "kw":
                    return (try await resolveKw(songId, tier: tier), tier)
                case "mg":
                    return (try await resolveMg(songId), tier)
                case "kg":
                    return (try await resolveKg(songId, tier: tier), tier)
                default:
                    throw NSError(domain: "LX", code: 6, userInfo: [NSLocalizedDescriptionKey: "不支持的音源: \(source)"])
                }
            } catch {
                errors.append("\(tierNames[tier] ?? tier): \(error.localizedDescription)")
            }
        }
        throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: "全部档位均失败（\(errors.joined(separator: "；"))）"])
    }

    /// 走外部自建 LX 服务：GET {LX_API_URL}/lxmusicv3/url/:source/:songId/:quality。
    static func resolveViaExternalServer(source: String, songId: String, quality: String) async throws -> (String, String) {
        let q = normalizeQuality(quality)
        var headers: [String: String] = [:]
        if !externalApiKey.isEmpty { headers["X-Request-Key"] = externalApiKey }
        let base = externalApiURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        let url = URL(string: "\(base)/lxmusicv3/url/\(source)/\(songId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? songId)/\(q)")!
        let data = try await Upstream.fetchJSON(url, headers: headers, timeout: 15) as? [String: Any]
        if (data?["code"] as? Int) == 0, let u = data?["data"] as? String, isHttpUrl(u) {
            return (u, (data?["quality"] as? String) ?? q)
        }
        throw NSError(domain: "LX", code: 2, userInfo: [NSLocalizedDescriptionKey: (data?["msg"] as? String) ?? "外部 LX 服务未返回音频链接"])
    }
}
