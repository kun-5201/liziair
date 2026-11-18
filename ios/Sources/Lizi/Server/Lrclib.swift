import Foundation

/// LRCLIB（https://lrclib.net）歌词兜底客户端：第 11 轮新增。
///
/// 定位：官方平台歌词优先；只有官方歌词接口回空/无候选时，各平台 lyric()
/// 才调这里。成功只回 syncedLyrics（带 [mm:ss] 时间戳的标准 LRC，可直接
/// 进现有解析器）；只有 plainLyrics 时按无词处理（plainLyrics 没有时间戳，
/// 进 parseLrcLines 会变成 0 行，塞进 lyric 字段只会让前端显示空白）。
///
/// 服务免费、无需 key，但请求头必须带 User-Agent，否则可能被限流。
/// 单次调用总预算 10 秒：/api/get（带 duration）→ 不带 duration 重试一次
/// → /api/search 取命中；预算耗尽即停，不拖住歌词请求。
enum Lrclib {
    private static let baseURL = "https://lrclib.net"
    private static let userAgent = "Lizi/1.1.0"
    private static let totalBudget: TimeInterval = 10

    /// 小内存缓存：artist+track 归一化 key，只缓存成功结果，上限 50 条。
    /// 歌词一首歌只取一次，本来就很少重复调；缓存是防同一首歌在不同
    /// 入口（切歌/重进播放页）被反复查。
    private static var cache: [String: (lyric: String, yrc: String)] = [:]
    private static let cacheLock = NSLock()

    private enum Lookup {
        case hit(String)        // syncedLyrics 非空
        case plainOnly          // 命中了，但只有 plainLyrics，没有 syncedLyrics
        case instrumental       // 纯音乐，没有歌词
        case miss               // 404 / 空结果
        case error(String)      // 网络或解析失败
    }

    /// 兜底入口。track 为空时直接回 nil，不发请求。
    /// duration 是整秒数；<= 0 时跳过带 duration 的 /api/get，直接走不带 duration 的。
    static func fetch(artist: String, track: String, album: String, duration: Int) async -> (lyric: String, yrc: String)? {
        let trackName = track.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackName.isEmpty else { return nil }
        let artistName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = album.trimmingCharacters(in: .whitespacesAndNewlines)

        let key = cacheKey(artist: artistName, track: trackName)
        if let hit = cached(key) { return hit }

        let deadline = Date().addingTimeInterval(totalBudget)

        // 1) /api/get（带 duration，duration 是最强的去重信号）。
        if duration > 0 {
            switch await get(artist: artistName, track: trackName, album: albumName, duration: duration, deadline: deadline) {
            case .hit(let lrc): return store(key, lrc)
            case .plainOnly:
                log("lrclib plain only track=\(trackName)", reason: "lrclib-plain-only")
                return nil
            case .instrumental:
                log("lrclib instrumental track=\(trackName)", reason: "lrclib-instrumental")
                return nil
            case .miss: break
            case .error(let msg):
                log("lrclib error track=\(trackName) \(msg)", reason: "lrclib-error")
                return nil
            }
        }
        // 2) /api/get（不带 duration；duration 对不上时这步能捞回来）。
        switch await get(artist: artistName, track: trackName, album: albumName, duration: nil, deadline: deadline) {
        case .hit(let lrc): return store(key, lrc)
        case .plainOnly:
            log("lrclib plain only track=\(trackName)", reason: "lrclib-plain-only")
            return nil
        case .instrumental:
            log("lrclib instrumental track=\(trackName)", reason: "lrclib-instrumental")
            return nil
        case .miss: break
        case .error(let msg):
            log("lrclib error track=\(trackName) \(msg)", reason: "lrclib-error")
            return nil
        }
        // 3) /api/search，取前 3 条命中里第一条有 syncedLyrics 的。
        switch await search(artist: artistName, track: trackName, album: albumName, deadline: deadline) {
        case .hit(let lrc): return store(key, lrc)
        case .plainOnly:
            log("lrclib plain only track=\(trackName)", reason: "lrclib-plain-only")
            return nil
        case .instrumental:
            log("lrclib instrumental track=\(trackName)", reason: "lrclib-instrumental")
            return nil
        case .miss:
            log("lrclib miss track=\(trackName)", reason: "lrclib-miss")
            return nil
        case .error(let msg):
            log("lrclib error track=\(trackName) \(msg)", reason: "lrclib-error")
            return nil
        }
    }

    // MARK: - 上游

    /// GET /api/get。duration 为 nil 时不带 duration 参数。
    private static func get(artist: String, track: String, album: String,
                            duration: Int?, deadline: Date) async -> Lookup {
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: track),
        ]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { items.append(URLQueryItem(name: "duration", value: String(duration))) }
        guard let url = url(path: "/api/get", queryItems: items) else { return .miss }
        return await lookup(url: url, deadline: deadline, isSearch: false)
    }

    /// GET /api/search，返回数组；取前 3 条里第一条有 syncedLyrics 的。
    private static func search(artist: String, track: String, album: String, deadline: Date) async -> Lookup {
        var items = [URLQueryItem(name: "track_name", value: track)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        guard let url = url(path: "/api/search", queryItems: items) else { return .miss }
        return await lookup(url: url, deadline: deadline, isSearch: true)
    }

    private static func lookup(url: URL, deadline: Date, isSearch: Bool) async -> Lookup {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return .miss }
        do {
            let (data, http) = try await Upstream.fetch(url, headers: ["User-Agent": userAgent],
                                                        timeout: max(2, remaining))
            switch http.statusCode {
            case 200: break
            case 404: return .miss
            default: return .error("http \(http.statusCode)")
            }
            if isSearch {
                guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return .error("bad search json")
                }
                var sawPlainOnly = false
                var sawInstrumental = false
                for hit in arr.prefix(3) {
                    switch classify(hit) {
                    case .hit(let lrc): return .hit(lrc)
                    case .plainOnly: sawPlainOnly = true
                    case .instrumental: sawInstrumental = true
                    case .miss: continue
                    case .error: continue
                    }
                }
                if sawPlainOnly { return .plainOnly }
                if sawInstrumental { return .instrumental }
                return .miss
            }
            guard let obj = Upstream.jsonObject(data) else { return .error("bad json") }
            return classify(obj)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// 一条 LRCLIB 记录的分类：只认 syncedLyrics；instrumental / 只有
    /// plainLyrics / 两者皆空各自有不同的返回值，调用方按此记日志。
    private static func classify(_ obj: [String: Any]) -> Lookup {
        if (obj["instrumental"] as? NSNumber)?.boolValue == true { return .instrumental }
        let synced = (obj["syncedLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !synced.isEmpty { return .hit(synced) }
        let plain = (obj["plainLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty { return .plainOnly }
        return .miss
    }

    private static func url(path: String, queryItems: [URLQueryItem]) -> URL? {
        var comps = URLComponents(string: baseURL)
        comps?.path = path
        comps?.queryItems = queryItems
        return comps?.url
    }

    // MARK: - 缓存与日志

    private static func cacheKey(artist: String, track: String) -> String {
        "\(artist.lowercased())|\(track.lowercased())"
    }

    private static func cached(_ key: String) -> (lyric: String, yrc: String)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    /// 记一条成功日志（只记行数，不记歌词正文）并进缓存。
    private static func store(_ key: String, _ lrc: String) -> (lyric: String, yrc: String) {
        let lines = lrc.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        log("lrclib ok lines=\(lines)", reason: "lrclib-ok")
        cacheLock.lock()
        if cache.count >= 50, let first = cache.keys.first { cache.removeValue(forKey: first) }
        cache[key] = (lyric: lrc, yrc: "")
        cacheLock.unlock()
        return (lyric: lrc, yrc: "")
    }

    private static func log(_ message: String, reason: String) {
        DiagLog.shared.recordLog(category: "lyric", message: message,
                                 fields: ["host": "lrclib.net", "reason": reason])
    }
}
