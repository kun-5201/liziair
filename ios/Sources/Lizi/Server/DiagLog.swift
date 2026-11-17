import Foundation

/// 服务端诊断（给设置页 / 真机排障用，不含任何隐私内容）：
///  - lastSearch：最近一次网易搜索的上游端点、耗时、HTTP 状态、条数、错误；
///  - requests：最近 20 条本地请求（方法、路径、耗时、状态）。
/// 前端搜不到歌时，下一张截图只要带上 /api/diag/search 就能分清
/// 是本地服务挂了、上游挂了、还是解析挂了。
final class DiagLog {
    static let shared = DiagLog()
    private let lock = NSLock()
    private(set) var lastSearch: [String: Any] = [:]
    private var requests: [[String: Any]] = []
    private var events: [String] = []

    func recordSearch(_ d: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        lastSearch = d
    }

    func recordRequest(method: String, path: String, ms: Int, status: Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(["method": method, "path": path, "ms": ms, "status": status])
        if requests.count > 20 { requests.removeFirst(requests.count - 20) }
    }

    func recordEvent(_ e: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(e)
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    func json() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["lastSearch": lastSearch, "requests": requests, "events": events]
    }
}
