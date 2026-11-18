import Foundation
import CryptoKit

/// 自定义落雪源管理（设置 → 自定义源管理）：导入的 LX Music 源脚本注册表。
///
/// 持久化（重启后仍在）：
///   脚本文件  Application Support/lx-sources/<id>.js
///   元数据    同目录 manifest.json（[LXSourceMeta]）
///   自动切换开关  UserDefaults "lxAutoSwitch"（默认关）
/// 内置落雪音源.js 已删（用户 2026-11-18 要求删掉「落雪音源」）：取歌链只走
/// 自定义源，没有内置解析、没有自定义 LX 服务器；拿不到就抛错，
/// 由 player.js 走平台接口备用。
///
/// 预装的 20 个 pdone 源也已删（用户 2026-11-18 04:01「把内置音源都删掉，
/// 只保留自定义音源接口」）：包里不再带 public/lx-sources 脚本，没有
/// 种子导入、没有内置源仓库；升级后手机上已导入的那批由 list() 里的
/// purgeBuiltinSources() 在启动时清掉。用户以后自己从 URL 或本地 .js
/// 导入源，管理界面（开关/删除/自动切换）照常好用。
///
/// 导入校验（import-url / import-file / 刷新 / 补绑 URL 共用）：
///   脚本必须在独立 JSContext 里跑起来、注册 request 处理（异步注册的等
///   5 秒）、inited 上报至少一个带 musicUrl 动作的平台；不合格抛带步骤的
///   具体原因（加载异常 / 5 秒没注册 / 5 秒没上报平台及实际报了什么），
///   前端原样显示，并记一条诊断日志（category probe）。不做「必须包含
///   musicUrl 字面量」的文本预检——混淆过的真源字面量不存在。

struct LXSourceMeta: Codable {
    var id: String
    var name: String
    var version: String
    var author: String
    /// inited 上报的、带 musicUrl 的平台（去掉 'local' 伪源），如 ["tx", "wy"]。
    var platforms: [String]
    /// "url" = URL 导入（有 sourceUrl，可刷新）/ "local" = 本地文件导入。
    /// 旧版预装的内置源 origin 是 "builtin"，list() 里启动时清掉（见 purgeBuiltinSources）。
    var origin: String
    /// URL 导入的源地址（已转 raw）；本地源为 nil，旧记录补绑后才有。
    var sourceUrl: String?
    var enabled: Bool
    var importedAt: TimeInterval
    var sha256: String

    static func json(_ m: LXSourceMeta) -> [String: Any] {
        var d: [String: Any] = [
            "id": m.id, "name": m.name, "version": m.version, "author": m.author,
            "platforms": m.platforms, "origin": m.origin, "enabled": m.enabled,
            "importedAt": m.importedAt, "sha256": m.sha256,
        ]
        if let u = m.sourceUrl { d["sourceUrl"] = u }
        return d
    }
}

// MARK: - 存储（文件 + 清单 + 小工具）

enum LXSourceStore {
    static let maxScriptBytes = 1_048_576

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("lx-sources", isDirectory: true)
    }

    private static var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    static func scriptURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).js")
    }

    static func sha256Hex(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// GitHub 链接转 raw：github.com/user/repo/blob/branch/path
    ///   → raw.githubusercontent.com/user/repo/branch/path；
    /// Gitee 同理：gitee.com/user/repo/blob/branch/path
    ///   → gitee.com/user/repo/raw/branch/path（直接拉 blob 页会拿到
    ///   HTML，校验必失败；raw 302 到 raw.giteeusercontent.com，
    ///   URLSession 会跟随）。jsdelivr（cdn.jsdelivr.net/gh/…、/npm/…）
    /// 和直链 .js 本来就是文件地址，原样返回。
    static func githubRawURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return s }
        if host == "raw.githubusercontent.com" || host == "raw.giteeusercontent.com" { return s }
        if host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 5 && (parts[2] == "blob" || parts[2] == "raw") {
                let rest = parts.dropFirst(3).joined(separator: "/")
                return "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(rest)"
            }
        }
        if host == "gitee.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 5 && parts[2] == "blob" {
                let rest = parts.dropFirst(3).joined(separator: "/")
                return "https://gitee.com/\(parts[0])/\(parts[1])/raw/\(rest)"
            }
        }
        return s
    }

    /// 导入失败记诊断日志（第 6 轮约定：category 只用 probe，message 以
    /// "lx-source-import: " 开头；host/reason/lane 照约定填；路由见
    /// Router.swift /api/diag/log，日志存在 DiagLog.logs 里，设置页可看）。
    /// 服务端直接调 recordLog（不走 HTTP，避免自己调自己）；前端 app.js
    /// 再按同一约定 POST 一次（用户在界面上看到的失败也会留下记录）。
    static func diagLog(sourceName: String, step: String, reason: String, host: String) {
        DiagLog.shared.recordLog(category: "probe",
            message: "lx-source-import: \(sourceName) \(step)失败：\(reason)",
            fields: ["host": host, "reason": step, "lane": "lx-source-import"])
    }

    /// 脚本下载的 UA：有的源站（如 gitee 镜像、部分私人服务器）不认
    /// URLSession 默认 UA，直接 403；浏览器 UA 能过。
    static let scriptDownloadHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"]

    /// 拉到的脚本字节 → 字符串：UTF-8 优先，失败再试 GB18030（有的作者
    /// 用 GBK 存 .js；旧版 UTF-8 解不开直接报「脚本为空」，误导用户）。
    /// 两种都解不开才返回 nil。
    static func decodeScriptData(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: String.Encoding(rawValue: 0x80000632))
    }

    /// 脚本头注释里的 @name / @version / @author（只看前 4KB）。
    static func headerValue(_ script: String, _ key: String) -> String? {
        let head = String(script.prefix(4096))
        guard let at = head.range(of: "@\(key)") else { return nil }
        let rest = head[at.upperBound...]
        let line = rest.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let v = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: 清单读写（调用方已在 ioQueue 上，不再 sync，避免死锁）

    static func loadManifest() -> [LXSourceMeta] {
        guard let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([LXSourceMeta].self, from: data) else {
            return []
        }
        return entries
    }

    static func saveManifest(_ entries: [LXSourceMeta]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

// MARK: - 注册表

/// 自定义源注册表：单例；清单读写在 ioQueue 上，运行实例在 instancesLock 后。
/// 取歌链（resolveMusicUrl）：启用的自定义源（列表顺序，只试它声明覆盖的平台）。
/// 自动切换开关：开 = 逐个试全部启用的自定义源；关 = 只试第一个可用候选。
final class LXSourceRegistry {
    static let shared = LXSourceRegistry()

    private let ioQueue = DispatchQueue(label: "com.lty5201.lizi.lxsources")
    private let instancesLock = NSLock()
    private var instances: [String: LXScriptInstance] = [:]

    private init() {}

    // MARK: - 自动切换开关（UserDefaults，默认关）

    var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "lxAutoSwitch")
    }

    func setAutoSwitch(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "lxAutoSwitch")
    }

    // MARK: - 列表

    /// 导入顺序（manifest 顺序），前端按这个顺序画、服务端按这个顺序试。
    /// 每次先清掉旧版预装的内置源（origin == "builtin"，用户 2026-11-18
    /// 要求删掉全部 20 个预装源）：升级后用户手机上已经导入的那批也在
    /// 这里清掉——manifest 记录 + 脚本文件 + 运行实例一起删；没有内置
    /// 源时这步什么都不做。只留用户自己加的自定义源。
    func list() -> [LXSourceMeta] {
        ioQueue.sync {
            purgeBuiltinSources()
            return LXSourceStore.loadManifest()
        }
    }

    /// 清掉旧版预装的内置源（只在 ioQueue 上调）。幂等：没有就直接返回。
    private func purgeBuiltinSources() {
        var manifest = LXSourceStore.loadManifest()
        let doomed = manifest.filter { $0.origin == "builtin" }
        guard !doomed.isEmpty else { return }
        for m in doomed {
            try? FileManager.default.removeItem(at: LXSourceStore.scriptURL(id: m.id))
            removeInstance(id: m.id)
        }
        manifest.removeAll(where: { $0.origin == "builtin" })
        LXSourceStore.saveManifest(manifest)
        // 旧种子标记也清掉，别留着占位。
        UserDefaults.standard.removeObject(forKey: "lxSourcesSeededV1")
    }

    // MARK: - 导入

    /// 从 URL 导入：GitHub 链接先转 raw 再拉取，校验后落盘。
    func importFromURL(_ urlString: String) async throws -> LXSourceMeta {
        let raw = LXSourceStore.githubRawURL(urlString)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            LXSourceStore.diagLog(sourceName: urlString, step: "fetch", reason: "脚本 URL 无效", host: "")
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "脚本 URL 无效"])
        }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let script = try await fetchScript(url: url, displayName: fallbackName.isEmpty ? urlString : fallbackName)
        return try importScript(script: script, nameHint: fallbackName.isEmpty ? nil : fallbackName,
                                origin: "url", sourceUrl: raw)
    }

    /// 拉取脚本（import-url / bind-url / refresh 共用）：带浏览器 UA、
    /// HTTP 状态、UTF-8/GB18030 解码；哪一步失败就报哪一步，并记诊断日志。
    /// 返回解码后的脚本；失败抛带步骤的错误，前端直接显示。
    private func fetchScript(url: URL, displayName: String) async throws -> String {
        let host = url.host ?? ""
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await Upstream.fetch(url, headers: LXSourceStore.scriptDownloadHeaders, timeout: 30)
        } catch {
            let reason = "拉取脚本失败（网络错误：\(error.localizedDescription)）"
            LXSourceStore.diagLog(sourceName: displayName, step: "fetch", reason: reason, host: host)
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard resp.statusCode == 200 else {
            let reason = "拉取脚本失败（HTTP \(resp.statusCode)）"
            LXSourceStore.diagLog(sourceName: displayName, step: "fetch", reason: reason, host: host)
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard let script = LXSourceStore.decodeScriptData(data) else {
            let reason = "拉取到的脚本无法读取（不是 UTF-8/GBK 编码）"
            LXSourceStore.diagLog(sourceName: displayName, step: "decode", reason: reason, host: host)
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let reason = "拉取到的脚本为空"
            LXSourceStore.diagLog(sourceName: displayName, step: "decode", reason: reason, host: host)
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return script
    }

    /// 本地文件导入：前端读文件内容 POST 上来（支持多选，前端逐个调）。
    func importFile(name: String, content: String) throws -> LXSourceMeta {
        try importScript(script: content, nameHint: name, origin: "local", sourceUrl: nil)
    }

    /// 旧记录补绑 URL：没有 sourceUrl 的源（旧版导入）重新拉取并绑定一次，
    /// 补绑后出现 URL 标记和刷新按钮；同时用拉到的新脚本更新文件和元数据。
    func bindURL(id: String, urlString: String) async throws -> LXSourceMeta {
        let raw = LXSourceStore.githubRawURL(urlString)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "脚本 URL 无效"])
        }
        let displayName = ioQueue.sync { LXSourceStore.loadManifest().first(where: { $0.id == id })?.name } ?? id
        let script = try await fetchScript(url: url, displayName: displayName)
        return try ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            guard let i = manifest.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "LXSources", code: 404, userInfo: [NSLocalizedDescriptionKey: "源不存在"])
            }
            let validated = try validate(script: script, displayName: displayName)
            var meta = manifest[i]
            meta.name = validated.name
            meta.version = validated.version
            meta.author = validated.author
            meta.platforms = validated.platforms
            meta.origin = "url"
            meta.sourceUrl = raw
            meta.sha256 = LXSourceStore.sha256Hex(script)
            try Data(script.utf8).write(to: LXSourceStore.scriptURL(id: id), options: .atomic)
            manifest[i] = meta
            LXSourceStore.saveManifest(manifest)
            replaceInstance(id: id, instance: validated.instance)
            return meta
        }
    }

    // MARK: - 删除 / 开关 / 刷新

    /// 删除源：脚本文件 + manifest 记录 + 运行实例一起清掉。
    @discardableResult
    func delete(id: String) -> Bool {
        ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            guard let i = manifest.firstIndex(where: { $0.id == id }) else { return false }
            manifest.remove(at: i)
            LXSourceStore.saveManifest(manifest)
            try? FileManager.default.removeItem(at: LXSourceStore.scriptURL(id: id))
            removeInstance(id: id)
            return true
        }
    }

    /// 启用开关：只改 manifest，不卸载实例（关掉的源取歌时直接跳过）。
    func setEnabled(id: String, enabled: Bool) -> LXSourceMeta? {
        ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            guard let i = manifest.firstIndex(where: { $0.id == id }) else { return nil }
            manifest[i].enabled = enabled
            LXSourceStore.saveManifest(manifest)
            return manifest[i]
        }
    }

    /// 刷新：仅 URL 源。重新拉取，版本没变返回 changed=false；
    /// 变了就更新文件和元数据（名称/版本/作者/平台/sha256），换掉运行实例。
    func refresh(id: String) async throws -> (meta: LXSourceMeta, changed: Bool) {
        let current = ioQueue.sync { LXSourceStore.loadManifest().first(where: { $0.id == id }) }
        guard let meta = current else {
            throw NSError(domain: "LXSources", code: 404, userInfo: [NSLocalizedDescriptionKey: "源不存在"])
        }
        guard let sourceUrl = meta.sourceUrl, !sourceUrl.isEmpty else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "本地导入的源没有 URL，无法刷新；点右侧链接先绑定 URL"])
        }
        guard let url = URL(string: sourceUrl) else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "绑定的 URL 无效"])
        }
        let script = try await fetchScript(url: url, displayName: meta.name)
        let newHash = LXSourceStore.sha256Hex(script)
        if newHash == meta.sha256 {
            // 内容没变：仍校验一次能跑（脚本可能已坏），坏了就报错、不动文件。
            let validated = try validate(script: script, displayName: meta.name)
            _ = validated
            return (meta, false)
        }
        return try ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            guard let i = manifest.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "LXSources", code: 404, userInfo: [NSLocalizedDescriptionKey: "源不存在"])
            }
            let validated = try validate(script: script, displayName: meta.name)
            var updated = manifest[i]
            updated.name = validated.name
            updated.version = validated.version
            updated.author = validated.author
            updated.platforms = validated.platforms
            updated.sha256 = newHash
            try Data(script.utf8).write(to: LXSourceStore.scriptURL(id: id), options: .atomic)
            manifest[i] = updated
            LXSourceStore.saveManifest(manifest)
            replaceInstance(id: id, instance: validated.instance)
            return (updated, true)
        }
    }

    // MARK: - 取歌链

    /// 取歌：只试启用的自定义源（列表顺序）。返回 (url, 实际档位, via)。
    /// via：custom:<id>。没有内置落雪音源.js、没有自定义 LX 服务器——用户
    /// 2026-11-18 要求删掉「落雪音源」，链路改成 自定义源 → 平台接口备用
    /// （平台备用在 player.js，不在这里）。
    /// 每个候选 URL 先校验（Range 取 1 字节、8 秒上限，跟随重定向）：
    /// 有的脚本只拼 URL 不验证上游（长青直接拼 PHP 地址），返回的地址
    /// 可能是死的；校验不过就试下一个候选，别把死链交给播放器。
    /// 整条链路 30 秒总期限：超时就抛错走平台备用，别吃掉前端 60 秒超时。
    func resolveMusicUrl(source: String, songId: String, quality: String, songName: String = "", autoSwitch: Bool) async throws -> (String, String, String) {
        try await withThrowingTaskGroup(of: (String, String, String).self) { group in
            group.addTask {
                var lastError: Error?
                let candidates = self.list().filter { $0.enabled && $0.platforms.contains(source) }
                let tryList = autoSwitch ? candidates : Array(candidates.prefix(1))
                for meta in tryList {
                    do {
                        let inst = try self.instance(for: meta)
                        let (url, tier) = try await inst.resolveMusicUrl(source: source, songId: songId, quality: quality, songName: songName)
                        if await Self.audioURLReachable(url, source: source) {
                            return (url, tier, "custom:\(meta.id)")
                        }
                        lastError = NSError(domain: "LXSources", code: 2, userInfo: [NSLocalizedDescriptionKey: "音源 \(meta.name) 返回的地址打不开"])
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? NSError(domain: "LXSources", code: 2, userInfo: [NSLocalizedDescriptionKey: "全部音源均失败"])
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw NSError(domain: "LXSources", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪解析超时（30 秒）"])
            }
            guard let r = try await group.next() else {
                throw NSError(domain: "LXSources", code: 2, userInfo: [NSLocalizedDescriptionKey: "落雪解析无返回"])
            }
            group.cancelAll()
            return r
        }
    }

    /// 校验音频直链是否真的能播：Range 取 1 字节，读到 1 个字节才算通。
    /// 只验 2xx 不够：有的上游对坏地址也回 200 + HTML 错误页（长青被截断的
    /// wy.php、过期的 vkey），探活放过后 LX 就“赢”了、平台备用走不到，
    /// 播放器拿到错误页只能静默失败。所以同时验状态码 + Content-Type +
    /// 至少 1 字节正文：
    ///  - 206 + ≥1 字节：Range 生效的真音频，直接算通（Content-Type 缺失也认）；
    ///  - 200 + ≥1 字节：要求 Content-Type 是音频（audio/*、video/*、
    ///    application/octet-stream——酷狗 FLAC 就回这个），text/html、
    ///    application/json 之类的错误页直接判死，换下一个候选。
    /// 用 bytes(for:) 只读 1 字节就停：data(for:) 会把整段正文下完，遇到
    /// 上游无视 Range 回 200 整包时会把整个文件（上百 MB 的 FLAC）拉下来探活。
    /// 跟随重定向（URLSession 默认）。
    /// （第 11 轮第 8/9 件改动）
    ///  - 探活头对齐播放时代理会发的头：tx（QQ 流媒体）补 Referer
    ///    https://y.qq.com/（代理一直这么发，探活裸 UA 可能被边缘节点误杀）。
    ///  - 超时 / 无响应 = 结论不明，不再判死：弱网下首字节 >8 秒很常见
    ///    （VM 上冷边缘首字节 1.5–2.3 秒），判死会把能播的歌推给演示音；
    ///    这时交回 true 让播放器自己试（播失败有 fallbackToDemo 兜底），
    ///    并留一条面包屑。只有拿到明确 HTTP 响应才判死（4xx/5xx、
    ///    200 + 非音频 Content-Type、空正文），判死时把主机 + 状态/CT
    ///    记进诊断（不记完整直链），不再只剩一句「打不开」。
    static func audioURLReachable(_ urlString: String, source: String, timeout: TimeInterval = 10) async -> Bool {
        guard let rawURL = Upstream.url(from: urlString),
              rawURL.scheme == "http" || rawURL.scheme == "https" else { return false }
        // 第 12 轮：探升级后的地址——播放器播的就是升级后的地址，探 http 原址
        // 只会探到 ATS -1022，给不出真结论；升级表见 Upstream.audioHTTPSSuffixes。
        // 超时算结论不明、放行给播放器试的逻辑不动（见函数末尾 catch）。
        let url = Upstream.upgradedAudioURL(rawURL)
        let host = url.host ?? ""
        // 非 throwing task group：两个子任务都不抛错（bytes 失败自己吞掉变
        // 结论不明，sleep 用 try?），先回来哪个算哪个，另一个取消。
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    var req = URLRequest(url: url, timeoutInterval: timeout)
                    req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    if source == "tx" {
                        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
                    }
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        DiagLog.shared.recordLog(category: "audio",
                            message: "LX 探活无 HTTP 响应：source=\(source) host=\(host)（结论不明，交给播放器试）",
                            fields: ["host": host, "reason": "lx-probe-no-response", "lane": "lx"])
                        DiagLog.shared.recordPlaybackStep("lx probe inconclusive source=\(source) host=\(host) reason=no-http-response")
                        return true
                    }
                    guard http.statusCode == 200 || http.statusCode == 206 else {
                        DiagLog.shared.recordLog(category: "audio",
                            message: "LX 探活判死：source=\(source) host=\(host) HTTP \(http.statusCode)",
                            fields: ["host": host, "reason": "lx-probe-status-\(http.statusCode)", "code": http.statusCode, "lane": "lx"])
                        return false
                    }
                    let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    let audioCT = ct.hasPrefix("audio/") || ct.hasPrefix("video/")
                        || ct == "application/octet-stream" || ct == "binary/octet-stream"
                    if http.statusCode == 200 {
                        // 200 可能是错误页：必须有音频 Content-Type 才认。
                        guard audioCT else {
                            DiagLog.shared.recordLog(category: "audio",
                                message: "LX 探活判死：source=\(source) host=\(host) HTTP 200 但 Content-Type 不是音频（\(ct.isEmpty ? "缺失" : ct)）",
                                fields: ["host": host, "reason": "lx-probe-not-audio", "lane": "lx"])
                            return false
                        }
                    } else if !ct.isEmpty && !audioCT {
                        // 206 是真分片：Content-Type 缺失也认，有值时必须是音频。
                        DiagLog.shared.recordLog(category: "audio",
                            message: "LX 探活判死：source=\(source) host=\(host) HTTP 206 但 Content-Type 不是音频（\(ct)）",
                            fields: ["host": host, "reason": "lx-probe-not-audio", "lane": "lx"])
                        return false
                    }
                    var it = bytes.makeAsyncIterator()
                    guard try await it.next() != nil else {
                        DiagLog.shared.recordLog(category: "audio",
                            message: "LX 探活判死：source=\(source) host=\(host) HTTP \(http.statusCode) 但正文为空",
                            fields: ["host": host, "reason": "lx-probe-empty", "lane": "lx"])
                        return false
                    }
                    return true
                } catch {
                    // 超时 / DNS 失败 / 连接被重置：没拿到响应，结论不明——
                    // 交给播放器试，别在弱网上误杀能播的链。
                    DiagLog.shared.recordLog(category: "audio",
                        message: "LX 探活无响应（\(error.localizedDescription)）：source=\(source) host=\(host)（结论不明，交给播放器试）",
                        fields: ["host": host, "reason": "lx-probe-inconclusive", "lane": "lx"])
                    DiagLog.shared.recordPlaybackStep("lx probe inconclusive source=\(source) host=\(host)")
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return false }
                DiagLog.shared.recordPlaybackStep("lx probe timeout source=\(source) host=\(host) (inconclusive, handing to player)")
                return true
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }

    // MARK: - 内部

    /// 校验一个脚本：跑起来、注册 request 处理、inited 至少上报一个 musicUrl 平台。
    /// 返回解析出的元数据字段 + 已加载的实例（调用方落盘成功后再挂进注册表，
    /// 避免坏脚本占住实例槽位）。
    /// 注意：这里故意不用「脚本必须包含 musicUrl 字面量」这种文本预检——
    /// 混淆过的真源（野花/野草/独家音源）把 'musicUrl' 拆成 \x 转义或远程
    /// 下发，字面量根本不存在；跑起来 + inited 上报才是真正的校验。
    /// 失败时报错写清步骤和原因（加载异常原文 / 5 秒没注册处理 / 5 秒没上报
    /// musicUrl 平台 + 实际报了什么平台），前端原样显示，不再只给一句
    /// 「不是有效的落雪音源脚本」；同时记一条诊断日志（category probe，
    /// message 以 "lx-source-import: " 开头，见 LXSourceStore.diagLog）。
    /// 平台 id 归一化：有的脚本用长名（kuwo/netease/qq/kugou/migu），取歌链
    /// 只认短名（kw/wy/tx/kg/mg），这里统一映射，免得「源在列表里、歌永远
    /// 走不到它」。
    private func validate(script: String, displayName: String? = nil) throws -> (name: String, version: String, author: String, platforms: [String], instance: LXScriptInstance) {
        let label = displayName ?? LXSourceStore.headerValue(script, "name") ?? "自定义源"
        func fail(_ step: String, _ reason: String) -> Error {
            LXSourceStore.diagLog(sourceName: label, step: step, reason: reason, host: "")
            return NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard script.utf8.count <= LXSourceStore.maxScriptBytes else {
            throw fail("validate-size", "脚本过大（超过 1MB）")
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw fail("validate-empty", "脚本内容为空")
        }
        let instance = LXScriptInstance(script: script)
        do {
            try instance.load()
        } catch {
            throw fail("validate-load", "脚本加载失败：\(error.localizedDescription)")
        }
        // 有的脚本先拉远程配置再发 inited（如 juhe），load() 返回时 platforms
        // 还是空的；等一等（最多 5 秒，同步发 inited 的当场就到，不等）。
        instance.waitForInited()
        let rawPlatforms = instance.platforms
        guard !rawPlatforms.isEmpty else {
            let reported = instance.reportedPlatforms
            let reason: String
            if reported.isEmpty {
                reason = "脚本 5 秒内没有上报任何平台（没有发 inited，或远程配置拉取失败）"
            } else {
                reason = "脚本没有可用的 musicUrl 音源（只上报了 \(reported.joined(separator: "、"))，都没有 musicUrl 动作）"
            }
            throw fail("validate-no-musicUrl", reason)
        }
        let alias: [String: String] = ["kuwo": "kw", "netease": "wy", "qq": "tx", "kugou": "kg", "migu": "mg"]
        let platforms = Array(Set(rawPlatforms.map { alias[$0] ?? $0 })).sorted()
        let name = LXSourceStore.headerValue(script, "name")
        let version = LXSourceStore.headerValue(script, "version") ?? ""
        let author = LXSourceStore.headerValue(script, "author") ?? ""
        return (name ?? "自定义源", version, author, platforms, instance)
    }

    private func importScript(script: String, nameHint: String?, origin: String, sourceUrl: String?) throws -> LXSourceMeta {
        let validated = try validate(script: script, displayName: nameHint)
        let id = UUID().uuidString.lowercased()
        let meta = LXSourceMeta(
            id: id,
            name: validated.name == "自定义源" ? (nameHint ?? "自定义源") : validated.name,
            version: validated.version,
            author: validated.author,
            platforms: validated.platforms,
            origin: origin,
            sourceUrl: sourceUrl,
            enabled: true,
            importedAt: Date().timeIntervalSince1970,
            sha256: LXSourceStore.sha256Hex(script)
        )
        try ioQueue.sync {
            try FileManager.default.createDirectory(at: LXSourceStore.directory, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: LXSourceStore.scriptURL(id: id), options: .atomic)
            var manifest = LXSourceStore.loadManifest()
            manifest.append(meta)
            LXSourceStore.saveManifest(manifest)
        }
        replaceInstance(id: id, instance: validated.instance)
        return meta
    }

    /// 取实例：有就用，没有就从磁盘读脚本、加载（重启后第一次取歌走这里）。
    /// 加载失败抛错，取歌链会跳到下一个候选。
    private func instance(for meta: LXSourceMeta) throws -> LXScriptInstance {
        instancesLock.lock()
        if let inst = instances[meta.id] {
            instancesLock.unlock()
            return inst
        }
        instancesLock.unlock()
        guard let script = try? String(contentsOf: LXSourceStore.scriptURL(id: meta.id), encoding: .utf8) else {
            throw NSError(domain: "LXSources", code: 404, userInfo: [NSLocalizedDescriptionKey: "源脚本文件不存在"])
        }
        let inst = LXScriptInstance(script: script)
        try inst.load()
        replaceInstance(id: meta.id, instance: inst)
        return inst
    }

    private func replaceInstance(id: String, instance: LXScriptInstance) {
        instancesLock.lock()
        instances[id] = instance
        instancesLock.unlock()
    }

    private func removeInstance(id: String) {
        instancesLock.lock()
        instances.removeValue(forKey: id)
        instancesLock.unlock()
    }
}
