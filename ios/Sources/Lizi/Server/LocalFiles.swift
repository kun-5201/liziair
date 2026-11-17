import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// 本地音乐：Documents/LocalMusic/ + 一份 JSON 清单（index.json）。
///
/// 文件由文件 App 导入（UIDocumentPicker，见 LocalFilesBridge.swift），
/// 只通过 /api/local/* 对外暴露；播放走 StaticFiles 的 Range 逻辑
/// （<audio> 拖进度要 Range，和 public/ 静态文件同一套代码）。
///
/// 清单里一条的 id 是 UUID（只含 [0-9a-f-]，可直接进 query，见 isSafeId）；
/// 磁盘文件名另存（原文件名可能含中文 / 空格 / 特殊字符，不宜当 id 用）。
/// 所有清单读写都在一条串行队列上做，Router 是并发 Task 调进来的。
enum LocalMusic {
    struct Entry: Codable {
        var id: String
        var fileName: String
        var title: String
        var artists: [String]
        /// 秒；API 层再换算成毫秒（和其它音源 track.duration 的单位一致）。
        var duration: Double
        var size: Int64
        var importedAt: TimeInterval
    }

    /// 允许导入的音频后缀（文件选择器已按 UTType.audio 过滤，这里是第二道闸）。
    static let allowedExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "ogg", "aac", "aiff", "aif", "opus",
    ]

    private static let ioQueue = DispatchQueue(label: "lizi.localmusic")
    private static let indexFileName = "index.json"

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("LocalMusic", isDirectory: true)
    }

    private static var indexURL: URL {
        directory.appendingPathComponent(indexFileName)
    }

    /// id 只含安全字符（UUID 的字母 / 数字 / -），防目录穿越。
    /// fileURL(id:) 里还会再按清单查文件名、校验落点，双重保险。
    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 清单（按导入时间倒序）。文件已被删的条目顺手清掉，不写回也不报错。
    static func list() -> [Entry] {
        ioQueue.sync { loadIndex().filter { fileExists($0) }.sorted { $0.importedAt > $1.importedAt } }
    }

    /// 按 id 找磁盘文件。id 非法 / 清单里没有 / 落点不在目录里都回 nil。
    static func fileURL(id: String) -> URL? {
        guard isSafeId(id) else { return nil }
        return ioQueue.sync {
            guard let entry = loadIndex().first(where: { $0.id == id }) else { return nil }
            let url = directory.appendingPathComponent(entry.fileName)
            // 文件名来自清单（不是用户输入），这里仍校验标准化后的落点在目录内。
            guard url.standardized.path.hasPrefix(directory.standardized.path + "/") else { return nil }
            return url
        }
    }

    /// GET /api/local/file：读文件后走 StaticFiles 的 Range 逻辑发出去。
    static func serveFile(id: String, rangeHeader: String?) -> HttpResponse {
        guard let url = fileURL(id: id),
              let data = try? Data(contentsOf: url) else {
            return .json(404, ["code": 404, "error": "本地文件不存在"])
        }
        return StaticFiles.serveData(
            data,
            type: StaticFiles.mimeType(forExtension: url.pathExtension),
            rangeHeader: rangeHeader
        )
    }

    /// GET /api/local/list 的 track 形状：和其它音源的 track 对齐，
    /// 前端直接进 Player.playQueue，不用再转一遍。
    static func trackJSON(_ entry: Entry) -> [String: Any] {
        [
            "id": entry.id,
            "source": "local",
            "name": entry.title,
            "artists": entry.artists,
            "duration": Int(entry.duration * 1000),
            "size": entry.size,
        ]
    }

    /// 把文件选择器给的 urls 拷进沙盒、记进清单。
    /// security-scoped URL 在这里包一层 start/stop（asCopy 来的一般不需要，
    /// 调了也无害）。调用方在后台线程调，别在主线程等元数据。
    /// 返回 (成功导入的条目, 跳过/失败的数量)。
    @discardableResult
    static func importFiles(urls: [URL]) -> (imported: [Entry], failed: Int) {
        ioQueue.sync { () -> (imported: [Entry], failed: Int) in
            var imported: [Entry] = []
            var failed = 0
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return (imported: [], failed: urls.count)
            }
            var index = loadIndex()
            for url in urls {
                // security-scoped 访问只在 iOS 上有（Linux Foundation 没有这个 API）。
#if os(iOS)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
#endif
                guard let entry = importOne(url: url, index: index) else {
                    failed += 1
                    continue
                }
                index.append(entry)
                imported.append(entry)
            }
            saveIndex(index)
            return (imported: imported, failed: failed)
        }
    }

    /// POST /api/local/delete：删文件 + 清单。找不到 id 回 false（路由回 404）。
    @discardableResult
    static func delete(id: String) -> Bool {
        guard isSafeId(id) else { return false }
        return ioQueue.sync {
            var index = loadIndex()
            guard let i = index.firstIndex(where: { $0.id == id }) else { return false }
            let entry = index.remove(at: i)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
            saveIndex(index)
            return true
        }
    }

    // MARK: - 内部（调用方已在 ioQueue 上，不再 sync，避免死锁）

    private static func fileExists(_ entry: Entry) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.fileName).path)
    }

    private static func loadIndex() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func saveIndex(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 单个文件：重名加 " 2" / " 3" 后缀（不覆盖已导入的同名文件），
    /// 标题优先用内嵌元数据，读不到就用文件名去后缀。
    private static func importOne(url: URL, index: [Entry]) -> Entry? {
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }
        let baseName = url.deletingPathExtension().lastPathComponent
        guard !baseName.isEmpty else { return nil }

        var fileName = url.lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
            fileName = "\(baseName) \(n).\(ext)"
            n += 1
        }
        let dest = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        let meta = readMetadata(url: dest)
        return Entry(
            id: UUID().uuidString.lowercased(),
            fileName: fileName,
            title: meta.title ?? baseName,
            artists: meta.artists,
            duration: meta.duration,
            size: size,
            importedAt: Date().timeIntervalSince1970
        )
    }

    /// 读内嵌标题 / 歌手 / 时长。AVFoundation 只在 iOS/macOS 有，
    /// Linux 上 canImport 为假，走 fallback（标题 = 文件名，时长 0）。
    private static func readMetadata(url: URL) -> (title: String?, artists: [String], duration: Double) {
#if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let keys = ["duration", "commonMetadata"]
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: keys) { sem.signal() }
        // 后台线程等最多 2 秒；超时 / 读失败就按无元数据处理，不卡导入。
        _ = sem.wait(timeout: .now() + 2)
        var duration: Double = 0
        if asset.statusOfValue(forKey: "duration", error: nil) == .loaded {
            let seconds = asset.duration.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
        var title: String?
        var artists: [String] = []
        if asset.statusOfValue(forKey: "commonMetadata", error: nil) == .loaded {
            for item in asset.commonMetadata {
                if item.identifier == .commonIdentifierTitle, let v = item.stringValue, !v.isEmpty {
                    title = v
                } else if item.identifier == .commonIdentifierArtist, let v = item.stringValue, !v.isEmpty {
                    artists.append(v)
                }
            }
        }
        return (title: title, artists: artists, duration: duration)
#else
        return (title: nil, artists: [], duration: 0)
#endif
    }
}
