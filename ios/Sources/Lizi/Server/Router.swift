import Foundation

/// 路由分发：分发顺序与 server.mjs 的 createServer 一致。
/// 具体 handler 在 NetEase.swift / Sidecars.swift 里实现。

final class LiziRouter {
    let netease = NetEaseService()
    let sidecars = SidecarService()
    private let session = SessionStore.shared

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let path = req.path

        // ---- 静态图片代理 ----
        if path == "/api/img" { return await Proxies.proxyImage(req) }

        // ---- Wallpaper Engine 壁纸（wallpaper-api.mjs）----
        // 主播放器界面不依赖它（只给 658 形态 iframe 用）；v1 先返回 404，见规格文档。
        if path == "/api/wallpaper" || path.hasPrefix("/api/wallpaper/") {
            return .json(404, ["error": "wallpaper api not available in iOS build"])
        }

        // ---- QQ 音乐（必须在通用 /api/ 分支之前）----
        if path == "/api/qq/audio" { return await Proxies.proxySourceAudio(req, source: "qq") }
        if path == "/api/qq" || path.hasPrefix("/api/qq/") {
            return await sidecars.handleQQ(req)
        }

        // ---- 落雪（LX）：按 server.mjs 的顺序排在 QQ 之后、其他边车之前 ----
        if path == "/api/lx/song/url" { return await handleLxSongUrl(req) }
        if path == "/api/lx/health" {
            return .json(200, ["code": 0, "sources": ["wy", "tx", "kg", "kw", "mg"],
                              "tiers": LXResolver.tiers,
                              "via": LXResolver.externalApiURL.isEmpty ? "builtin" : "external"])
        }
        if path == "/api/lx/audio" { return await Proxies.proxySourceAudio(req, source: "lx") }

        // ---- 落雪设置：自定义服务器地址（设置页用；存 UserDefaults，重启仍生效；留空 = 内置解析）----
        if path == "/api/settings/lx" {
            if req.method == "POST" {
                let url = req.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
                        return .json(400, ["code": 400, "error": "地址须以 http:// 或 https:// 开头"])
                    }
                    UserDefaults.standard.set(url, forKey: "lxApiUrl")
                    LXResolver.externalApiURL = url
                } else {
                    UserDefaults.standard.removeObject(forKey: "lxApiUrl")
                    LXResolver.externalApiURL = ""
                }
            }
            return .json(200, ["code": 200, "url": LXResolver.externalApiURL,
                                "via": LXResolver.externalApiURL.isEmpty ? "builtin" : "external"])
        }

        // ---- 其它边车：音频代理 + handler ----
        for name in ["kugou", "qishui", "bodian", "spotify", "kuwo"] {
            if path == "/api/\(name)/audio" { return await Proxies.proxySourceAudio(req, source: name) }
            if path == "/api/\(name)" || path.hasPrefix("/api/\(name)/") {
                return await sidecars.handle(req, source: name)
            }
        }

        // ---- 网易云音频代理（必须在 handleNetease 兜底之前）----
        if path == "/api/netease/audio" { return await Proxies.proxySourceAudio(req, source: "netease") }

        // ---- 网易云边车 ----
        if path == "/api/netease" || path.hasPrefix("/api/netease/") {
            return await netease.handleNetease(req)
        }

        // ---- 登录收尾 ----
        if path == "/api/login/harvest" && req.method == "POST" {
            return await netease.handleLoginHarvest(req)
        }
        if path == "/api/session/import" && req.method == "POST" {
            return await netease.handleSessionImport(req)
        }

        // ---- 会话状态 ----
        if path == "/api/session" {
            guard session.hasMusicU else { return .json(200, ["loggedIn": false]) }
            do {
                if let v = try await netease.sessionVerify() { return .json(200, v) }
                return .json(200, ["loggedIn": false])
            } catch {
                return .json(200, ["loggedIn": false])
            }
        }

        // ---- 扫码诊断 ----
        if path == "/api/login/qr/last" {
            return .json(200, netease.lastQrCheckPayload())
        }

        // ---- 网易云接口转发 ----
        if path.hasPrefix("/api/") {
            return await netease.handleApi(req)
        }

        // ---- 静态文件 ----
        return StaticFiles.serve(path: path, rangeHeader: req.headers["range"])
    }

    // MARK: - LX

    private func handleLxSongUrl(_ req: HttpRequest) async -> HttpResponse {
        let source = req.string("source", "netease")
        guard let lxSource = LXResolver.sourceMap[source], !lxSource.isEmpty else {
            return .json(200, ["code": 6, "error": "该音源没有 LX 解析: \(source)"])
        }
        var songId = ""
        switch source {
        case "qq":
            songId = req.string("mid").isEmpty ? req.string("id") : req.string("mid")
        case "kugou":
            songId = req.string("hash").isEmpty ? req.string("id") : req.string("hash")
            if !(songId.count == 32 && songId.allSatisfy({ $0.isHexDigit })) {
                songId = [req.string("name"), req.string("artists")].filter({ !$0.isEmpty }).joined(separator: " ")
            }
        case "kuwo":
            songId = req.string("name").isEmpty ? req.string("id") : req.string("name")
        default:
            songId = req.string("id")
        }
        guard !songId.isEmpty else { return .json(400, ["code": 6, "error": "缺少歌曲 id"]) }
        let quality = req.string("quality", "master")
        do {
            let r: (String, String)
            if !LXResolver.externalApiURL.isEmpty {
                r = try await LXResolver.resolveViaExternalServer(source: lxSource, songId: songId, quality: quality)
            } else {
                r = try await LXResolver.resolveMusicUrl(source: lxSource, songId: songId, quality: quality)
            }
            return .json(200, ["code": 0, "url": r.0, "quality": r.1, "lxSource": lxSource,
                                "via": LXResolver.externalApiURL.isEmpty ? "builtin" : "external"])
        } catch {
            return .json(200, ["code": 2, "error": error.localizedDescription])
        }
    }
}
