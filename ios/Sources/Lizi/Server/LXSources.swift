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
///   脚本必须在独立 JSContext 里跑起来、注册 request 处理、inited 上报至少一个
///   带 musicUrl 动作的平台；不合格抛「不是有效的落雪音源脚本」，前端弹提示。

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
    /// 已是 raw 的、或其它地址，原样返回。
    static func githubRawURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return s }
        if host == "raw.githubusercontent.com" { return s }
        if host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 5 && (parts[2] == "blob" || parts[2] == "raw") {
                let rest = parts.dropFirst(3).joined(separator: "/")
                return "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(rest)"
            }
        }
        return s
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
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "脚本 URL 无效"])
        }
        let (data, resp) = try await Upstream.fetch(url, timeout: 30)
        guard resp.statusCode == 200 else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "拉取脚本失败（HTTP \(resp.statusCode)）"])
        }
        guard let script = String(data: data, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "拉取到的脚本为空"])
        }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        return try importScript(script: script, nameHint: fallbackName.isEmpty ? nil : fallbackName,
                                origin: "url", sourceUrl: raw)
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
        let (data, resp) = try await Upstream.fetch(url, timeout: 30)
        guard resp.statusCode == 200 else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "拉取脚本失败（HTTP \(resp.statusCode)）"])
        }
        guard let script = String(data: data, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "拉取到的脚本为空"])
        }
        return try ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            guard let i = manifest.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "LXSources", code: 404, userInfo: [NSLocalizedDescriptionKey: "源不存在"])
            }
            let validated = try validate(script: script)
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
        let (data, resp) = try await Upstream.fetch(url, timeout: 30)
        guard resp.statusCode == 200 else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "拉取脚本失败（HTTP \(resp.statusCode)）"])
        }
        guard let script = String(data: data, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "拉取到的脚本为空"])
        }
        let newHash = LXSourceStore.sha256Hex(script)
        if newHash == meta.sha256 {
            // 内容没变：仍校验一次能跑（脚本可能已坏），坏了就报错、不动文件。
            let validated = try validate(script: script)
            _ = validated
            return (meta, false)
        }
        return try ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            guard let i = manifest.firstIndex(where: { $0.id == id }) else {
                throw NSError(domain: "LXSources", code: 404, userInfo: [NSLocalizedDescriptionKey: "源不存在"])
            }
            let validated = try validate(script: script)
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
    func resolveMusicUrl(source: String, songId: String, quality: String, autoSwitch: Bool) async throws -> (String, String, String) {
        try await withThrowingTaskGroup(of: (String, String, String).self) { group in
            group.addTask {
                var lastError: Error?
                let candidates = self.list().filter { $0.enabled && $0.platforms.contains(source) }
                let tryList = autoSwitch ? candidates : Array(candidates.prefix(1))
                for meta in tryList {
                    do {
                        let inst = try self.instance(for: meta)
                        let (url, tier) = try await inst.resolveMusicUrl(source: source, songId: songId, quality: quality)
                        if await Self.audioURLReachable(url) {
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
    static func audioURLReachable(_ urlString: String, timeout: TimeInterval = 8) async -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return false }
        // 非 throwing task group：两个子任务都不抛错（bytes 失败自己吞掉变 false，
        // sleep 用 try?），先回来哪个算哪个，另一个取消。
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    var req = URLRequest(url: url, timeoutInterval: timeout)
                    req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { return false }
                    guard http.statusCode == 200 || http.statusCode == 206 else { return false }
                    let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    let audioCT = ct.hasPrefix("audio/") || ct.hasPrefix("video/")
                        || ct == "application/octet-stream" || ct == "binary/octet-stream"
                    if http.statusCode == 200 {
                        // 200 可能是错误页：必须有音频 Content-Type 才认。
                        guard audioCT else { return false }
                    } else {
                        // 206 是真分片：Content-Type 缺失也认，有值时必须是音频。
                        if !ct.isEmpty && !audioCT { return false }
                    }
                    var it = bytes.makeAsyncIterator()
                    return try await it.next() != nil
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - 内部

    /// 校验一个脚本：跑起来、注册 request 处理、inited 至少上报一个 musicUrl 平台。
    /// 返回解析出的元数据字段 + 已加载的实例（调用方落盘成功后再挂进注册表，
    /// 避免坏脚本占住实例槽位）。
    private func validate(script: String) throws -> (name: String, version: String, author: String, platforms: [String], instance: LXScriptInstance) {
        guard script.utf8.count <= LXSourceStore.maxScriptBytes else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "脚本过大（超过 1MB）"])
        }
        guard script.contains("musicUrl") else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "不是有效的落雪音源脚本"])
        }
        let instance = LXScriptInstance(script: script)
        do {
            try instance.load()
        } catch {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "不是有效的落雪音源脚本：\(error.localizedDescription)"])
        }
        // 有的脚本先拉远程配置再发 inited（如 juhe），load() 返回时 platforms
        // 还是空的；等一等（最多 5 秒，同步发 inited 的当场就到，不等）。
        instance.waitForInited()
        let platforms = instance.platforms
        guard !platforms.isEmpty else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "不是有效的落雪音源脚本：没有可用的 musicUrl 音源"])
        }
        let name = LXSourceStore.headerValue(script, "name")
        let version = LXSourceStore.headerValue(script, "version") ?? ""
        let author = LXSourceStore.headerValue(script, "author") ?? ""
        return (name ?? "自定义源", version, author, platforms, instance)
    }

    private func importScript(script: String, nameHint: String?, origin: String, sourceUrl: String?) throws -> LXSourceMeta {
        let validated = try validate(script: script)
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
