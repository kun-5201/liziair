import Foundation

/// 登录态持久化：对标 server.mjs 的 .session.json（网易云 cookie）与各边车的 .auth-* 文件。
/// 存在 App 沙盒 Application Support/lizi/ 下；cookie 值绝不明文打进日志。

final class SessionStore {
    static let shared = SessionStore()

    private let dir: URL
    private var cookies: [String: String] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("lizi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        loadDevice()
    }

    private var sessionFile: URL { dir.appendingPathComponent("session.json") }

    private func load() {
        guard let data = try? Data(contentsOf: sessionFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        cookies = obj
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: cookies) else { return }
        try? data.write(to: sessionFile, options: .atomic)
    }

    var musicU: String? { cookies["MUSIC_U"] }
    var hasMusicU: Bool { musicU?.isEmpty == false }
    var cookieKeys: [String] { Array(cookies.keys) }
    var csrf: String { cookies["__csrf"] ?? "" }

    /// 全部 cookie 拼成请求头（weapi/eapi 发请求时用）。
    /// 对标 server.mjs 的 cookieHeader()：先拼 .session.json 的全部键值对，
    /// 再补设备信息里尚未在 jar 中的键。
    var cookieHeader: String {
        var jar = cookies.map { "\($0.key)=\($0.value)" }
        for (k, v) in deviceInfo where cookies[k] == nil {
            jar.append("\(k)=\(v)")
        }
        return jar.joined(separator: "; ")
    }

    /// 设备指纹（对标 .netease-device.json）：首次运行生成并持久化。
    /// appver 3.1.17.204416，与 eapi header 一致。
    private(set) var deviceInfo: [String: String] = [:]

    private var deviceFile: URL { dir.appendingPathComponent("device.json") }

    private func loadDevice() {
        if let data = try? Data(contentsOf: deviceFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           !obj.isEmpty {
            deviceInfo = obj
        } else {
            deviceInfo = [
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
        let nuid = deviceInfo["_ntes_nuid"] ?? Self.randomHex(32)
        deviceInfo["_ntes_nuid"] = nuid
        if deviceInfo["_ntes_nnid"] == nil {
            deviceInfo["_ntes_nnid"] = "\(nuid),\(Int(Date().timeIntervalSince1970 * 1000))"
        }
        if deviceInfo["WNMCID"] == nil {
            deviceInfo["WNMCID"] = "\(Self.randomLetters(6)).\(Int(Date().timeIntervalSince1970 * 1000)).01.0"
        }
        if deviceInfo["WEVNSM"] == nil { deviceInfo["WEVNSM"] = "1.0.0" }
        if deviceInfo["__remember_me"] == nil { deviceInfo["__remember_me"] = "true" }
        if deviceInfo["ntes_kaola_ad"] == nil { deviceInfo["ntes_kaola_ad"] = "1" }
        if let data = try? JSONSerialization.data(withJSONObject: deviceInfo) {
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
        for (k, v) in new { cookies[k] = v }
        save()
    }

    /// 整份替换（harvest / session/import 用：新会话覆盖旧会话，不留旧账号的残 cookie）。
    func replaceCookies(_ new: [String: String]) {
        cookies = new
        save()
    }

    func removeCookies(_ keys: [String]) {
        for k in keys { cookies.removeValue(forKey: k) }
        save()
    }

    func clear() {
        cookies.removeAll()
        save()
    }

    /// 会话快照 / 回滚（harvest 与 session/import 校验失败时恢复现场）。
    func snapshot() -> [String: String] { cookies }
    func restore(_ snap: [String: String]) {
        cookies = snap
        save()
    }

    /// 保存上游 Set-Cookie：每条只取第一个 ';' 之前的 K=V；值为空或 '""' 时删键。
    /// 输入可能是多条 Set-Cookie 合并成的字符串（URLSession 会把重复头拼起来），
    /// 按「逗号 + 含 = 的 token」切分（Expires 里的逗号不在切分点上）。
    func saveCookies(_ setCookieValues: [String]) {
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
        save()
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
        let url = dir.appendingPathComponent(".auth-\(name).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    func saveSidecarAuth(_ name: String, _ obj: [String: Any]) {
        let url = dir.appendingPathComponent(".auth-\(name).json")
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clearSidecarAuth(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".auth-\(name).json"))
    }
}
