import Foundation

/// 静态文件：把 public/ 全量当静态目录发出去（对标 server.mjs 的静态托管）。
/// public/ 以 folder reference 打进包，Bundle 里路径就是 <App>.app/public/...。

enum StaticFiles {
    static var publicRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("public")
    }

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "mp3": "audio/mpeg",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "bin": "application/octet-stream",
        "txt": "text/plain; charset=utf-8",
        "map": "application/json; charset=utf-8",
    ]

    static func mimeType(forExtension ext: String) -> String {
        mime[ext.lowercased()] ?? "application/octet-stream"
    }

    /// 把一段已读入内存的数据按 HTTP Range 发出去。
    /// serve(path:) 和 /api/local/file 共用同一套 Range 代码，不各写一套。
    static func serveData(_ data: Data, type: String, rangeHeader: String?) -> HttpResponse {
        // Range: bytes=start-end（单段即可，<audio> 拖进度只发单段）。
        if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2, let start = Int(parts[0]) {
                let end = Int(parts[1]) ?? (data.count - 1)
                let s = max(0, start), e = min(data.count - 1, end)
                if s <= e {
                    let slice = data.subdata(in: s..<(e + 1))
                    return HttpResponse(status: 206, headers: [
                        "Content-Type": type,
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(s)-\(e)/\(data.count)",
                    ], body: slice)
                }
            }
            return HttpResponse(status: 416, headers: ["Content-Range": "bytes */\(data.count)"], body: Data())
        }
        return HttpResponse(status: 200, headers: [
            "Content-Type": type,
            "Accept-Ranges": "bytes",
        ], body: data)
    }

    /// GET / 或 /xxx.html 等。支持 Range（音频/大文件拖进度用）。
    /// `..` 越界回 403；目录补 index.html；缺文件回 404 纯文本（与 server.mjs 一致）。
    static func serve(path: String, rangeHeader: String?) -> HttpResponse {
        guard let root = publicRoot else {
            return .text(404, "404")
        }
        var rel = path
        if rel == "/" || rel.isEmpty { rel = "/index.html" }
        let segments = rel.split(separator: "/").map(String.init)
        if segments.contains("..") {
            return .text(403, "403")
        }
        var fileURL = root
        for seg in segments where seg != "." {
            fileURL.appendPathComponent(seg)
        }
        // 目录尾斜杠补 index.html。
        if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true {
            fileURL.appendPathComponent("index.html")
        }
        guard fileURL.path.hasPrefix(root.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: fileURL) else {
            return .text(404, "404")
        }
        let ext = fileURL.pathExtension.lowercased()
        return serveData(data, type: mimeType(forExtension: ext), rangeHeader: rangeHeader)
    }
}

/// 上游请求小工具（URLSession，带超时；对标 server.mjs 的 fetch 行为）。
enum Upstream {
    static func fetch(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20,
                      method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "LiziUpstream", code: -1, userInfo: [NSLocalizedDescriptionKey: "no http response"])
        }
        return (data, http)
    }

    static func fetchJSON(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20,
                          method: String = "GET", body: Data? = nil) async throws -> Any {
        let (data, _) = try await fetch(url, headers: headers, timeout: timeout, method: method, body: body)
        return try JSONSerialization.jsonObject(with: data)
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
