import Foundation

/// 登录态持久化：对标 server.mjs 的 .session.json（网易云 cookie）与各边车的 .auth-* 文件。
/// 存在 App 沙盒 Application Support/lizi/ 下；cookie 值绝不明文打进日志。
///
/// 并发：Router 是并发 Task 调进来的，各边车同时读写 cookies/deviceInfo 和
/// session.json/device.json 会互相覆盖（诊断实锤的竞争）。这里一把 NSLock
/// 管全部读写和文件读写（不改成 actor，改动面太大）。
/// 锁纪律：公开方法只在入口拿一次锁，内部只调带 Locked 后缀、不自己拿锁的
/// 私有方法；init 里构造期间拿锁调 load/loadDevice（对象还没共享出去）。

final class SessionStore {
    static let shared = SessionStore()

    private let lock = NSLock()
    private let dir: URL
    private var cookies: [String: String] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("lizi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        loadDeviceLocked()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private var sessionFile: URL { dir.appendingPathComponent("session.json") }

    /// 调用方已持有锁（init / 公开方法入口），内部不再拿锁，防 NSLock 重入死锁。
    private func loadLocked() {
        guard let data = try? Data(contentsOf: sessionFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        cookies = obj
    }

    /// 调用方已持有锁。
    private func saveLocked() {
        guard let data = try? JSONSerialization.data(withJSONObject: cookies) else { return }
        try? data.write(to: sessionFile, options: .atomic)
    }

    var musicU: String? { withLock { cookies["MUSIC_U"] } }
    var hasMusicU: Bool { withLock { cookies["MUSIC_U"]?.isEmpty == false } }
    var cookieKeys: [String] { withLock { Array(cookies.keys) } }
    var csrf: String { withLock { cookies["__csrf"] ?? "" } }

    /// 全部 cookie 拼成请求头（weapi/eapi 发请求时用）。
    /// 对标 server.mjs 的 cookieHeader()：先拼 .session.json 的全部键值对，
    /// 再补设备信息里尚未在 jar 中的键。一次锁里取快照，不拼出一半旧一半新的头。
    var cookieHeader: String {
        withLock {
            var jar = cookies.map { "\($0.key)=\($0.value)" }
            for (k, v) in _deviceInfo where cookies[k] == nil {
                jar.append("\(k)=\(v)")
            }
            return jar.joined(separator: "; ")
        }
    }

    /// 设备指纹（对标 .netease-device.json）：首次运行生成并持久化。
    /// appver 3.1.17.204416，与 eapi header 一致。
    private var _deviceInfo: [String: String] = [:]
    var deviceInfo: [String: String] { withLock { _deviceInfo } }

    private var deviceFile: URL { dir.appendingPathComponent("device.json") }

    /// 调用方已持有锁。
    private func loadDeviceLocked() {
        if let data = try? Data(contentsOf: deviceFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           !obj.isEmpty {
            _deviceInfo = obj
        } else {
            _deviceInfo = [
                "os": "pc",
                "osver": "Microsoft-Windows-10-Professional-build-19045-64bit",
                "appver": "3.1.17.204416",
                "versioncode": "140",
                "mobilename": "",
                "resolution": "1920x1080",
                "channel": "netease",
                "deviceId": UUID().uuidString.uppercased(),
            ]
        }
        // 匿名身份 cookie（对标边车 processCookieObject）：扫码登录的上游风控按它认匿名会话。
        // 首次运行生成并持久化进 device.json；已生成的沿用，不随请求变化。
        // cookieHeader 会把 deviceInfo 里尚未在 jar 中的键补进请求头，所以这里一加就全量生效。
        let nuid = _deviceInfo["_ntes_nuid"] ?? Self.randomHex(32)
        _deviceInfo["_ntes_nuid"] = nuid
        if _deviceInfo["_ntes_nnid"] == nil {
            _deviceInfo["_ntes_nnid"] = "\(nuid),\(Int(Date().timeIntervalSince1970 * 1000))"
        }
        if _deviceInfo["WNMCID"] == nil {
            _deviceInfo["WNMCID"] = "\(Self.randomLetters(6)).\(Int(Date().timeIntervalSince1970 * 1000)).01.0"
        }
        if _deviceInfo["WEVNSM"] == nil { _deviceInfo["WEVNSM"] = "1.0.0" }
        if _deviceInfo["__remember_me"] == nil { _deviceInfo["__remember_me"] = "true" }
        if _deviceInfo["ntes_kaola_ad"] == nil { _deviceInfo["ntes_kaola_ad"] = "1" }
        if let data = try? JSONSerialization.data(withJSONObject: _deviceInfo) {
            try? data.write(to: deviceFile, options: .atomic)
        }
    }

    private static func randomHex(_ n: Int) -> String {
        String((0..<n).map { _ in "0123456789abcdef".randomElement()! })
    }
    private static func randomLetters(_ n: Int) -> String {
        String((0..<n).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }

    /// 合并写入（增量更新）。
    func setCookies(_ new: [String: String]) {
        withLock {
            for (k, v) in new { cookies[k] = v }
            saveLocked()
        }
    }

    /// 整份替换（harvest / session/import 用：新会话覆盖旧会话，不留旧账号的残 cookie）。
    func replaceCookies(_ new: [String: String]) {
        withLock {
            cookies = new
            saveLocked()
        }
    }

    func removeCookies(_ keys: [String]) {
        withLock {
            for k in keys { cookies.removeValue(forKey: k) }
            saveLocked()
        }
    }

    func clear() {
        withLock {
            cookies.removeAll()
            saveLocked()
        }
    }

    /// 会话快照 / 回滚（harvest 与 session/import 校验失败时恢复现场）。
    func snapshot() -> [String: String] { withLock { cookies } }
    func restore(_ snap: [String: String]) {
        withLock {
            cookies = snap
            saveLocked()
        }
    }

    /// 保存上游 Set-Cookie：每条只取第一个 ';' 之前的 K=V；值为空或 '""' 时删键。
    /// 输入可能是多条 Set-Cookie 合并成的字符串（URLSession 会把重复头拼起来），
    /// 按「逗号 + 含 = 的 token」切分（Expires 里的逗号不在切分点上）。
    func saveCookies(_ setCookieValues: [String]) {
        withLock {
            for raw in setCookieValues {
                for part in Self.splitSetCookie(raw) {
                    let kv = part.split(separator: ";", maxSplits: 1).first ?? ""
                    let pair = kv.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    let k = pair[0].trimmingCharacters(in: .whitespaces)
                    let v = pair[1].trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { continue }
                    if v.isEmpty || v == "\"\"" { cookies.removeValue(forKey: k) }
                    else { cookies[k] = v }
                }
            }
            saveLocked()
        }
    }

    /// 解析 Set-Cookie 头值（纯函数，不碰共享状态）：URLSession 会把多条
    /// Set-Cookie 拼成一条（", " 连接），直接按 ';' 切会把非首位 cookie 的键
    /// 解析成 ", MUSIC_U" 这类带前导逗号的键。复用 splitSetCookie 的逗号感知
    /// 切分，再取每段第一个 ';' 之前的 K=V。供 NetEase.extractCookie 的
    /// set-cookie 分支用；body.cookie / 用户粘贴的串是 ';' 分隔，不走这里。
    static func parseSetCookieStrings(_ values: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for raw in values {
            for part in splitSetCookie(raw) {
                let kv = part.split(separator: ";", maxSplits: 1).first ?? ""
                let pair = kv.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let k = pair[0].trimmingCharacters(in: .whitespaces)
                let v = pair[1].trimmingCharacters(in: .whitespaces)
                guard !k.isEmpty, !v.isEmpty else { continue }
                out[k] = v
            }
        }
        return out
    }

    private static func splitSetCookie(_ s: String) -> [String] {
        // 在 ", " 后跟 token= 的位置切分；Expires=Thu, 01 Jan ... 里的逗号后面跟的是日期，不含 =，不会被切。
        var out: [String] = []
        var cur = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "," {
                let rest = s[s.index(after: i)...]
                let trimmed = rest.drop(while: { $0 == " " })
                // 找下一个 ';' 之前有没有 '='（即这是新 cookie 的开头）
                let segEnd = trimmed.firstIndex(of: ";") ?? trimmed.endIndex
                let head = trimmed[..<segEnd]
                if head.contains("=") {
                    out.append(cur)
                    cur = ""
                    i = s.index(after: i)
                    while i < s.endIndex && s[i] == " " { i = s.index(after: i) }
                    continue
                }
            }
            cur.append(s[i])
            i = s.index(after: i)
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 边车登录态文件（对标 services/*/.auth-*）：按边车名存 JSON。
    func sidecarAuth(_ name: String) -> [String: Any]? {
        withLock {
            let url = dir.appendingPathComponent(".auth-\(name).json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
    }

    func saveSidecarAuth(_ name: String, _ obj: [String: Any]) {
        withLock {
            let url = dir.appendingPathComponent(".auth-\(name).json")
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func clearSidecarAuth(_ name: String) {
        withLock {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(".auth-\(name).json"))
        }
    }
}
