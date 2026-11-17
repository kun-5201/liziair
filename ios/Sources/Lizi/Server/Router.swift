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
                              "tiers": LXScriptInstance.scriptTiers,
                              "via": "custom"])
        }
        if path == "/api/lx/audio" { return await Proxies.proxySourceAudio(req, source: "lx") }

        // ---- 自定义源管理（设置 → 自定义源管理；见 LXSources.swift）----
        // 失败一律回 200 + { code:400, error }（不回 HTTP 400），前端 api.js 的
        // call() 只在 HTTP 非 2xx 时抛错，这样错误文案能原样显示在设置页。
        if path == "/api/lx/sources" {
            return .json(200, ["code": 0,
                                "sources": LXSourceRegistry.shared.list().map { LXSourceMeta.json($0) },
                                "autoSwitch": LXSourceRegistry.shared.autoSwitchEnabled])
        }
        if path == "/api/lx/sources/import-url" && req.method == "POST" {
            let url = req.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                return .json(200, ["code": 400, "error": "请填写脚本 URL"])
            }
            do {
                let meta = try await LXSourceRegistry.shared.importFromURL(url)
                return .json(200, ["code": 0, "source": LXSourceMeta.json(meta)])
            } catch {
                return .json(200, ["code": 400, "error": error.localizedDescription])
            }
        }
        if path == "/api/lx/sources/import-file" && req.method == "POST" {
            let content = req.string("content")
            guard !content.isEmpty else {
                return .json(200, ["code": 400, "error": "文件内容为空"])
            }
            do {
                let meta = try LXSourceRegistry.shared.importFile(name: req.string("name"), content: content)
                return .json(200, ["code": 0, "source": LXSourceMeta.json(meta)])
            } catch {
                return .json(200, ["code": 400, "error": error.localizedDescription])
            }
        }
        if path == "/api/lx/sources/delete" && req.method == "POST" {
            guard LXSourceRegistry.shared.delete(id: req.string("id")) else {
                return .json(200, ["code": 404, "error": "源不存在"])
            }
            return .json(200, ["code": 0])
        }
        if path == "/api/lx/sources/toggle" && req.method == "POST" {
            let enabled = req.bool("enabled")
            guard let meta = LXSourceRegistry.shared.setEnabled(id: req.string("id"), enabled: enabled) else {
                return .json(200, ["code": 404, "error": "源不存在"])
            }
            return .json(200, ["code": 0, "source": LXSourceMeta.json(meta)])
        }
        if path == "/api/lx/sources/refresh" && req.method == "POST" {
            do {
                let r = try await LXSourceRegistry.shared.refresh(id: req.string("id"))
                return .json(200, ["code": 0, "changed": r.changed, "source": LXSourceMeta.json(r.meta)])
            } catch {
                return .json(200, ["code": 400, "error": error.localizedDescription])
            }
        }
        if path == "/api/lx/sources/bind-url" && req.method == "POST" {
            let url = req.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                return .json(200, ["code": 400, "error": "请填写脚本 URL"])
            }
            do {
                let meta = try await LXSourceRegistry.shared.bindURL(id: req.string("id"), urlString: url)
                return .json(200, ["code": 0, "source": LXSourceMeta.json(meta)])
            } catch {
                return .json(200, ["code": 400, "error": error.localizedDescription])
            }
        }
        if path == "/api/lx/sources/auto-switch" {
            if req.method == "POST" {
                LXSourceRegistry.shared.setAutoSwitch(req.bool("enabled"))
            }
            return .json(200, ["code": 0, "enabled": LXSourceRegistry.shared.autoSwitchEnabled])
        }
        if path == "/api/lx/sources/builtin" {
            return .json(200, ["code": 0, "sources": LXSourceRegistry.shared.builtinList()])
        }
        if path == "/api/lx/sources/add-builtin" && req.method == "POST" {
            do {
                let meta = try LXSourceRegistry.shared.addBuiltin(id: req.string("id"))
                return .json(200, ["code": 0, "source": LXSourceMeta.json(meta)])
            } catch {
                return .json(200, ["code": 400, "error": error.localizedDescription])
            }
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

        // ---- 本地音乐（文件 App 导入；必须在通用 /api/ 转发之前，
        // 不然 /api/local/* 会被当成网易云接口转走）----
        if path == "/api/local/list" {
            let tracks = LocalMusic.list().map { LocalMusic.trackJSON($0) }
            return .json(200, ["code": 0, "tracks": tracks])
        }
        if path == "/api/local/file" {
            return LocalMusic.serveFile(id: req.string("id"), rangeHeader: req.headers["range"])
        }
        if path == "/api/local/delete" && req.method == "POST" {
            guard LocalMusic.delete(id: req.string("id")) else {
                return .json(404, ["code": 404, "error": "本地文件不存在"])
            }
            return .json(200, ["code": 0])
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
            // 取歌链（LXSourceRegistry）：启用的自定义源（列表顺序，只试它声明覆盖
            // 的平台），每个候选 URL 校验能打开才返回；全部失败抛错，
            // 由 player.js 走平台接口备用。自动切换开关控制是否多源重试。
            let r = try await LXSourceRegistry.shared.resolveMusicUrl(
                source: lxSource, songId: songId, quality: quality,
                autoSwitch: LXSourceRegistry.shared.autoSwitchEnabled)
            return .json(200, ["code": 0, "url": r.0, "quality": r.1, "lxSource": lxSource,
                                "via": r.2])
        } catch {
            return .json(200, ["code": 2, "error": error.localizedDescription])
        }
    }
}
