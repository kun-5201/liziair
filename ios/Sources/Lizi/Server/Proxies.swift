import Foundation

/// /api/img 图片代理 + 各平台音频代理。
/// 对标 server.mjs 的 proxyImage / proxySourceAudio / proxyQQAudio。
/// 只放行 AUDIO_HOSTS 白名单里的 CDN 域名，别把口子开成任意 SSRF。

enum Proxies {
    /// 各源音频 CDN 白名单（server.mjs 的 AUDIO_HOSTS 原样搬过来）。
    static let audioHosts: [String: [String]] = [
        // 域名后缀匹配：".kugou.com" 匹配 xxx.kugou.com
        "kugou": [".kugou.com", ".kgmusic.cn", ".kglink.com", ".kugou.com.cn"],
        "qishui": [".365yg.com", ".douyinvod.com", ".byteicdn.com", ".pstatp.com", ".douyinpic.com", ".snssdk.com"],
        "bodian": [".kuwo.cn", ".kugou.com", ".bodian.com"],
        "kuwo": [".kuwo.cn", ".kuwo.com"],
        "spotify": [],
        "netease": [".music.126.net"],
        // QQ 用 proxyQQAudio 同款白名单（见下方 qqAudioHosts）。
        "qq": [],
        // 落雪：解析出的地址来自各家 CDN（server.mjs 的 AUDIO_HOSTS.lx）。
        // 自定义源时代静态白名单兜不住：脚本会返回任意 CDN（长青海棠网、
        // 环音、聚合的 IP 直连……），白名单一拦就 403、播不出声。
        // lx 代理只放行 http/https（上面已校验），不限域名：本地服务只绑
        // 127.0.0.1，只有本 App 自己能调；脚本本身走 lx.request 也能任意
        // 拉取，白名单对 lx 没有实际防护意义。其它平台的白名单保持不变。
        "lx": [],
    ]

    /// QQ 音频代理的域名白名单（server.mjs 的 proxyQQAudio：/(^|\.)qq\.com$/i，仅腾讯域名）。
    static func qqHostAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "qq.com" || h.hasSuffix(".qq.com")
    }

    static let audioReferer: [String: String] = [
        "kugou": "https://www.kugou.com/",
        "qishui": "",
        "bodian": "https://www.bodian.com/",
    ]

    private static func hostAllowed(_ host: String, suffixes: [String]) -> Bool {
        let h = host.lowercased()
        return suffixes.contains { h == $0.dropFirst() || h.hasSuffix($0) }
    }

    /// /api/img?url=：封面代理（绕开防盗链）。
    /// 白名单、上限、重定向再校验均按规格文档 §7.1。
    static func proxyImage(_ req: HttpRequest) async -> HttpResponse {
        guard let raw = req.query["url"], let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else {
            return .error(400, "bad url")
        }
        guard let host = url.host, imageHostAllowed(host) else {
            return .json(403, ["error": "host not allowed"])
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else {
                return .error(502, "no http response")
            }
            // 跟随重定向后，再校验一次最终 URL 的 host。
            if let finalURL = http.url, let finalHost = finalURL.host, !imageHostAllowed(finalHost) {
                return .json(403, ["error": "redirect host not allowed"])
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            guard contentType.hasPrefix("image/") else {
                return .json(415, ["error": "not an image"])
            }
            if data.count > 10 * 1024 * 1024 {
                return .json(413, ["error": "image too large"])
            }
            return HttpResponse(status: http.statusCode, headers: [
                "Content-Type": contentType,
                "Cache-Control": "public, max-age=86400",
            ], body: data)
        } catch {
            return .error(502, String(describing: error))
        }
    }

    private static let imageHostsExact: Set<String> = [
        "p1.music.126.net", "p2.music.126.net", "p3.music.126.net",
        "p4.music.126.net", "p5.music.126.net", "p6.music.126.net",
        "y.gtimg.cn", "music-file.y.qq.com", "qpic.y.qq.com", "i.scdn.co",
    ]
    private static let imageHostSuffixes = [
        ".kugou.com", ".douyinpic.com", ".douyincdn.com", ".huoshanimg.com",
        ".kuwo.cn", ".scdn.co", ".spotifycdn.com", ".y.qq.com", ".qlogo.cn", ".qpic.cn",
    ]

    private static func imageHostAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        if imageHostsExact.contains(h) { return true }
        return imageHostSuffixes.contains { h.hasSuffix($0) }
    }

    /// /api/<source>/audio?url=：音频代理，转发 Range，返回上游状态码原样。
    static func proxySourceAudio(_ req: HttpRequest, source: String) async -> HttpResponse {
        guard let raw = req.query["url"], let url = URL(string: raw),
              let host = url.host,
              (url.scheme == "http" || url.scheme == "https") else {
            return .error(400, "bad url")
        }
        let allow: [String]
        if source == "qq" {
            // QQ 走独立实现（proxyQQAudio）：仅腾讯域名，Referer https://y.qq.com/。
            guard qqHostAllowed(host) else {
                return .json(403, ["error": "host not allowed"])
            }
            var headers: [String: String] = ["User-Agent": "Mozilla/5.0", "Referer": "https://y.qq.com/"]
            if let range = req.headers["range"] { headers["Range"] = range }
            do {
                let (data, http) = try await Upstream.fetch(url, headers: headers, timeout: 30)
                var out: [String: String] = [
                    "Content-Type": http.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg",
                    "Cache-Control": "no-store",
                    "Accept-Ranges": "bytes",
                ]
                for k in ["content-length", "content-range"] {
                    if let v = http.value(forHTTPHeaderField: k) { out[k] = v }
                }
                return HttpResponse(status: http.statusCode, headers: out, body: data)
            } catch {
                return .error(502, String(describing: error))
            }
        }
        allow = audioHosts[source] ?? []
        if source != "lx" {
            guard !allow.isEmpty else { return .error(403, "no audio for source \(source)") }
            guard hostAllowed(host, suffixes: allow) else {
                return .error(403, "host not allowed: \(host)")
            }
        }
        var headers: [String: String] = ["User-Agent": "Mozilla/5.0"]
        if let ref = audioReferer[source], !ref.isEmpty { headers["Referer"] = ref }
        if let range = req.headers["range"] { headers["Range"] = range }
        do {
            let (data, http) = try await Upstream.fetch(url, headers: headers, timeout: 30)
            var out: [String: String] = [
                "Content-Type": http.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg",
                "Cache-Control": "no-store",
                "Accept-Ranges": "bytes",
            ]
            for k in ["content-length", "content-range"] {
                if let v = http.value(forHTTPHeaderField: k) { out[k] = v }
            }
            return HttpResponse(status: http.statusCode, headers: out, body: data)
        } catch {
            return .error(502, String(describing: error))
        }
    }
}
