import Foundation
import CryptoKit

/// 自定义落雪源管理（设置 → 自定义源管理）：导入的 LX Music 源脚本注册表。
///
/// 持久化（重启后仍在）：
///   脚本文件  Application Support/lx-sources/<id>.js
///   元数据    同目录 manifest.json（[LXSourceMeta]）
///   自动切换开关  UserDefaults "lxAutoSwitch"（默认关，和 lxApiUrl 同一模式）
/// 内置 public/落雪音源.js 不在这里管，仍走 LXScriptEngine.shared。
///
/// 内置源仓库（pdone/lx-music-source，20 个，含 suyin 溯音音源——用户
/// 2026-11-17 21:00 明确说「都加」，推翻了之前「溯音不打包」的规矩，按最新
/// 指令 20 个全打包）：脚本在 public/lx-sources/<目录>.js，随包发布；首次
/// 访问时种子导入进 manifest（id 就是目录名，稳定不变），每个都能单独开关、
/// 删除；删掉的从仓库列表一键重新添加。种子只跑一次（UserDefaults
/// lxSourcesSeededV1），删掉的不会自己长回来；种子时个别脚本校验失败
/// （它的服务器没响应、初始化没完成）就跳过它、记下原因，其余照常导入，
/// 失败的在仓库里显示原因、可点重试。
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
    /// "url" = URL 导入（有 sourceUrl，可刷新）/ "local" = 本地文件导入 /
    /// "builtin" = 内置源仓库（pdone/lx-music-source，随包发布，无 sourceUrl，不刷新）。
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
/// 取歌链（resolveMusicUrl）：启用的自定义源（列表顺序，只试它声明覆盖的平台）
///   → 内置落雪音源.js → 自定义 LX 服务器（LXResolver.externalApiURL）
///   → 全部失败抛错，由 player.js 走平台接口备用。
/// 自动切换开关：开 = 逐个试全部启用的自定义源；关 = 只试第一个可用候选
///   （其余自定义源跳过，内置源和自定义服务器这两级既有兜底照常走）。
final class LXSourceRegistry {
    static let shared = LXSourceRegistry()

    private let ioQueue = DispatchQueue(label: "com.lty5201.lizi.lxsources")
    private let instancesLock = NSLock()
    private var instances: [String: LXScriptInstance] = [:]

    private init() {}

    // MARK: - 内置源仓库（pdone/lx-music-source，20 个）

    /// 内置源 id（= 仓库目录名 = public/lx-sources/<id>.js，也是 manifest 里的固定 id）。
    static let builtinIds = [
        "changqing", "feichangdao", "fish", "flower", "grass", "helloworld",
        "huanyin", "huibq", "hyw", "ikun", "jiexiang", "juhe", "lx", "qdy",
        "qingliang", "sixyin", "suyin", "xinghai", "xinglan", "yuningxi",
    ]
    /// 种子只跑一次的标记；包内脚本有变化时升版本号（V1 → V2…）再种一遍。
    static let builtinSeedFlag = "lxSourcesSeededV1"

    static func builtinRawURL(id: String) -> String {
        "https://raw.githubusercontent.com/pdone/lx-music-source/main/\(id)/latest.js"
    }

    /// 包里自带的脚本（public/lx-sources/<id>.js，随 public/ 一起进包）。
    static func bundledScript(id: String) -> String? {
        Bundle.main.resourceURL.flatMap {
            try? String(contentsOf: $0.appendingPathComponent("public/lx-sources/\(id).js"), encoding: .utf8)
        }
    }

    /// 校验通过的内置脚本缓存（ioQueue 上访问）：addBuiltin 直接复用，不用重跑。
    private var builtinChecked: [String: BuiltinChecked] = [:]
    /// 校验失败的内置源（id → 原因，ioQueue 上访问）：种子跳过它，仓库里显示原因、可重试。
    private var builtinFailures: [String: String] = [:]

    private struct BuiltinChecked {
        var name: String
        var version: String
        var author: String
        var platforms: [String]
        var script: String
        var instance: LXScriptInstance
    }

    /// 批量校验内置脚本：先全部加载起来，再用一个共用的 5 秒期限等 inited，
    /// 免得每个坏脚本各等 5 秒、一次校验拖半分钟。成功的缓存进 builtinChecked，
    /// 失败的原因记进 builtinFailures。只在 ioQueue 上调。
    private func checkBuiltin(ids: [String]) -> [String: BuiltinChecked] {
        var loaded: [(id: String, script: String, instance: LXScriptInstance)] = []
        for id in ids {
            if builtinChecked[id] != nil || builtinFailures[id] != nil { continue }
            guard let script = Self.bundledScript(id: id), !script.isEmpty else {
                builtinFailures[id] = "包里没有这个脚本文件"; continue
            }
            guard script.contains("musicUrl") else {
                builtinFailures[id] = "不是有效的落雪音源脚本"; continue
            }
            let inst = LXScriptInstance(script: script)
            do { try inst.load() } catch {
                builtinFailures[id] = "不是有效的落雪音源脚本：\(error.localizedDescription)"; continue
            }
            loaded.append((id, script, inst))
        }
        if !loaded.isEmpty {
            let deadline = Date().addingTimeInterval(5)
            for item in loaded { item.instance.waitForInited(deadline: deadline) }
            for item in loaded {
                let platforms = item.instance.platforms
                guard !platforms.isEmpty else {
                    builtinFailures[item.id] = "没有可用的 musicUrl 音源（初始化未完成，可能是它的服务器没响应）"
                    continue
                }
                let name = LXSourceStore.headerValue(item.script, "name") ?? item.id
                builtinChecked[item.id] = BuiltinChecked(
                    name: name,
                    version: LXSourceStore.headerValue(item.script, "version") ?? "",
                    author: LXSourceStore.headerValue(item.script, "author") ?? "",
                    platforms: platforms, script: item.script, instance: item.instance)
            }
        }
        var out: [String: BuiltinChecked] = [:]
        for id in ids { if let c = builtinChecked[id] { out[id] = c } }
        return out
    }

    /// 种子：首次访问时把 20 个内置源导进 manifest（只跑一次；删掉的不再种回来）。
    /// 只在 ioQueue 上调（list()/builtinList() 里调）。个别失败不拦着其余的。
    /// 标记最后才置位：中途崩了下次还能重种（已导入的会跳过，幂等）。
    private func seedBuiltinIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.builtinSeedFlag) else { return }
        var manifest = LXSourceStore.loadManifest()
        let pending = Self.builtinIds.filter { id in !manifest.contains(where: { $0.id == id }) }
        if !pending.isEmpty {
            let checked = checkBuiltin(ids: pending)
            try? FileManager.default.createDirectory(at: LXSourceStore.directory, withIntermediateDirectories: true)
            for id in pending {
                guard let c = checked[id] else { continue }
                let meta = LXSourceMeta(
                    id: id, name: c.name, version: c.version, author: c.author,
                    platforms: c.platforms, origin: "builtin", sourceUrl: nil,
                    enabled: true, importedAt: Date().timeIntervalSince1970,
                    sha256: LXSourceStore.sha256Hex(c.script))
                try? Data(c.script.utf8).write(to: LXSourceStore.scriptURL(id: id), options: .atomic)
                manifest.append(meta)
                replaceInstance(id: id, instance: c.instance)
            }
            LXSourceStore.saveManifest(manifest)
        }
        UserDefaults.standard.set(true, forKey: Self.builtinSeedFlag)
    }

    /// 仓库列表：20 个内置源各一行的元数据（名称/版本/作者/平台/raw 地址、
    /// 是否已导入、是否启用、失败原因）。只在 ioQueue 上调。
    func builtinList() -> [[String: Any]] {
        ioQueue.sync {
            seedBuiltinIfNeeded()
            let manifest = LXSourceStore.loadManifest()
            let unknown = Self.builtinIds.filter { id in
                !manifest.contains(where: { $0.id == id })
                    && builtinChecked[id] == nil && builtinFailures[id] == nil
            }
            if !unknown.isEmpty { _ = checkBuiltin(ids: unknown) }
            return Self.builtinIds.map { id in
                let m = manifest.first(where: { $0.id == id })
                let c = builtinChecked[id]
                let script = Self.bundledScript(id: id) ?? ""
                var d: [String: Any] = [
                    "id": id,
                    "name": m?.name ?? c?.name ?? LXSourceStore.headerValue(script, "name") ?? id,
                    "version": m?.version ?? c?.version ?? LXSourceStore.headerValue(script, "version") ?? "",
                    "author": m?.author ?? c?.author ?? LXSourceStore.headerValue(script, "author") ?? "",
                    "platforms": m?.platforms ?? c?.platforms ?? [],
                    "imported": m != nil,
                    "enabled": m?.enabled ?? false,
                    "rawUrl": Self.builtinRawURL(id: id),
                ]
                if let f = builtinFailures[id] { d["error"] = f }
                return d
            }
        }
    }

    /// 从仓库重新添加一个内置源（删掉后点「重新添加」走这里）：完整校验一次，
    /// 过了才落盘 + 进 manifest；已经导入的直接返回现有记录。
    func addBuiltin(id: String) throws -> LXSourceMeta {
        guard Self.builtinIds.contains(id) else {
            throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "不是内置源"])
        }
        return try ioQueue.sync {
            var manifest = LXSourceStore.loadManifest()
            if let existing = manifest.first(where: { $0.id == id }) { return existing }
            if let c = builtinChecked[id] {
                let meta = LXSourceMeta(
                    id: id, name: c.name, version: c.version, author: c.author,
                    platforms: c.platforms, origin: "builtin", sourceUrl: nil,
                    enabled: true, importedAt: Date().timeIntervalSince1970,
                    sha256: LXSourceStore.sha256Hex(c.script))
                try FileManager.default.createDirectory(at: LXSourceStore.directory, withIntermediateDirectories: true)
                try Data(c.script.utf8).write(to: LXSourceStore.scriptURL(id: id), options: .atomic)
                manifest.append(meta)
                LXSourceStore.saveManifest(manifest)
                replaceInstance(id: id, instance: c.instance)
                builtinFailures.removeValue(forKey: id)
                return meta
            }
            guard let script = Self.bundledScript(id: id), !script.isEmpty else {
                throw NSError(domain: "LXSources", code: 400, userInfo: [NSLocalizedDescriptionKey: "包里没有这个脚本文件"])
            }
            let validated = try validate(script: script)
            let meta = LXSourceMeta(
                id: id,
                name: validated.name == "自定义源" ? id : validated.name,
                version: validated.version, author: validated.author,
                platforms: validated.platforms, origin: "builtin", sourceUrl: nil,
                enabled: true, importedAt: Date().timeIntervalSince1970,
                sha256: LXSourceStore.sha256Hex(script))
            try FileManager.default.createDirectory(at: LXSourceStore.directory, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: LXSourceStore.scriptURL(id: id), options: .atomic)
            manifest.append(meta)
            LXSourceStore.saveManifest(manifest)
            replaceInstance(id: id, instance: validated.instance)
            builtinFailures.removeValue(forKey: id)
            return meta
        }
    }

    // MARK: - 自动切换开关（UserDefaults，默认关）

    var autoSwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "lxAutoSwitch")
    }

    func setAutoSwitch(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "lxAutoSwitch")
    }

    // MARK: - 列表

    /// 导入顺序（manifest 顺序），前端按这个顺序画、服务端按这个顺序试。
    /// 首次调用时先把内置源仓库种子导入（只跑一次，见 seedBuiltinIfNeeded）。
    func list() -> [LXSourceMeta] {
        ioQueue.sync {
            seedBuiltinIfNeeded()
            return LXSourceStore.loadManifest()
        }
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

    /// 取歌：自定义源（列表顺序）→ 内置落雪音源.js → 自定义 LX 服务器 → 抛错。
    /// 返回 (url, 实际档位, via)。via：custom:<id> / lx-script / external。
    func resolveMusicUrl(source: String, songId: String, quality: String, autoSwitch: Bool) async throws -> (String, String, String) {
        var lastError: Error?
        let candidates = list().filter { $0.enabled && $0.platforms.contains(source) }
        let tryList = autoSwitch ? candidates : Array(candidates.prefix(1))
        for meta in tryList {
            do {
                let inst = try instance(for: meta)
                let (url, tier) = try await inst.resolveMusicUrl(source: source, songId: songId, quality: quality)
                return (url, tier, "custom:\(meta.id)")
            } catch {
                lastError = error
            }
        }
        do {
            let r = try await LXScriptEngine.shared.resolveMusicUrl(source: source, songId: songId, quality: quality)
            return (r.0, r.1, "lx-script")
        } catch {
            lastError = error
        }
        if !LXResolver.externalApiURL.isEmpty {
            do {
                let r = try await LXResolver.resolveViaExternalServer(source: source, songId: songId, quality: quality)
                return (r.0, r.1, "external")
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "LXSources", code: 2, userInfo: [NSLocalizedDescriptionKey: "全部音源均失败"])
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
