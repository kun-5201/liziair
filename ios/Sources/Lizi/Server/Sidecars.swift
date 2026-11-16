import Foundation

/// 六个边车服务：qq / kugou / kuwo / qishui / bodian / spotify。
/// 实现细节见 specs/sidecars.md；QQ/酷狗的上游在 npm 包内（见各源文件头的说明），
/// 汽水/波点的 guard 签名在协议库内；酷我与 Spotify 已按源码 1:1 移植。
/// 其余路由按 Node 版的空态/错误原样返回，绝不编假数据。

final class SidecarService {
    let kuwo = KuwoService()
    let spotify = SpotifyService()
    let qq = QQService()
    let kugou = KugouService()
    let qishui = QishuiService()
    let bodian = BodianService()

    func handleQQ(_ req: HttpRequest) async -> HttpResponse {
        await handle(req, source: "qq")
    }

    func handle(_ req: HttpRequest, source: String) async -> HttpResponse {
        switch source {
        case "qq": return await qq.handle(req)
        case "kugou": return await kugou.handle(req)
        case "kuwo": return await kuwo.handle(req)
        case "qishui": return await qishui.handle(req)
        case "bodian": return await bodian.handle(req)
        case "spotify": return await spotify.handle(req)
        default:
            return .json(404, ["code": 404, "error": "unknown source: \(source)"])
        }
    }
}

// MARK: - 通用小工具（边车各源共用）

func scStr(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
func scNum(_ v: Any?) -> Int {
    if let n = v as? Int { return n }
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String, let n = Int(s) { return n }
    if let f = v as? Double { return Int(f) }
    return 0
}
func scInt(_ d: [String: Any], _ k: String) -> Int { scNum(d[k]) }
func scArr(_ d: [String: Any], _ k: String) -> [[String: Any]] { d[k] as? [[String: Any]] ?? [] }
func scDict(_ d: [String: Any], _ k: String) -> [String: Any] { d[k] as? [String: Any] ?? [:] }
func scClamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }
func scStrOrNum(_ d: [String: Any], _ k: String) -> String {
    if let s = d[k] as? String { return s }
    if let n = d[k] as? NSNumber { return n.stringValue }
    return ""
}
/// 带单引号剥离的 JSON 解析（对标 kuwo 边车的 parseJson）。
func scParseJSON(_ text: String) -> Any? {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("'") { t = String(t.dropFirst()) }
    if t.hasSuffix("'") { t = String(t.dropLast()) }
    guard let data = t.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}
func scParseJSONObject(_ text: String) -> [String: Any] {
    scParseJSON(text) as? [String: Any] ?? [:]
}
func scURLEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}
/// 从 Set-Cookie 合并串里按名字取值（URLSession 会把多条拼成一条）。
func scCookieValue(_ setCookie: String?, _ name: String) -> String? {
    guard let setCookie else { return nil }
    for part in setCookie.components(separatedBy: ",") {
        let kv = part.split(separator: ";", maxSplits: 1).first ?? ""
        let pair = kv.split(separator: "=", maxSplits: 1)
        if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name {
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

// MARK: - KRC → LRC / YRC（酷狗与汽水共用，server.mjs 的 krcToLrc / krcToYrc）

/// KRC 行格式 [起始ms,时长ms]<字偏移,字时长,0>字…，字偏移为相对行首毫秒。
func krcToLrc(_ krc: String) -> String {
    var out: [String] = []
    for line in krc.components(separatedBy: "\n") {
        guard let m = krcLineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
        let start = Int(line[Range(m.range(at: 1), in: line)!]) ?? 0
        let content = String(line[Range(m.range(at: 3), in: line)!])
        let text = content.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let mm = start / 60000
        let ss = Double(start % 60000) / 1000.0
        out.append("[\(String(format: "%02d:%05.2f", mm, ss))]\(text)")
    }
    return out.joined(separator: "\n")
}

private let krcLineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
private let krcCharRegex = try! NSRegularExpression(pattern: #"<(\d+),(\d+),-?\d+>([^<]*)"#)

/// 逐字 YRC：[行起点,行时长](字绝对起点,字时长,0)字…；任一步对不上回 ""（调用方退回整行 LRC）。
func krcToYrc(_ krc: String) -> String {
    var out: [String] = []
    for line in krc.components(separatedBy: "\n") {
        guard let m = krcLineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
        let start = Int(line[Range(m.range(at: 1), in: line)!]) ?? 0
        let dur = Int(line[Range(m.range(at: 2), in: line)!]) ?? 0
        let content = String(line[Range(m.range(at: 3), in: line)!])
        let ns = NSRange(content.startIndex..., in: content)
        var chars: [(Int, Int, String)] = []
        for cm in krcCharRegex.matches(in: content, range: ns) {
            let off = Int(content[Range(cm.range(at: 1), in: content)!]) ?? 0
            let d = Int(content[Range(cm.range(at: 2), in: content)!]) ?? 0
            let t = String(content[Range(cm.range(at: 3), in: content)!])
            if !t.isEmpty { chars.append((off, d, t)) }
        }
        if chars.isEmpty { continue }
        let lineDur = dur > 0 ? dur : chars.map { $0.0 + $0.1 }.max() ?? 0
        let body = chars.map { "(\(start + $0.0),\($0.1),0)\($0.2)" }.joined()
        out.append("[\(start),\(lineDur)]\(body)")
    }
    return out.joined(separator: "\n")
}

// MARK: - AWLRC → YRC（波点逐字，server.mjs 的 awlrcToYrc）

private let awlrcLineRegex = try! NSRegularExpression(pattern: #"^\[(\d{2}):(\d{2})[.:](\d{1,3})\](.*)$"#)
private let awlrcCharRegex = try! NSRegularExpression(pattern: #"<(\d+),(\d+)>([^<]*)"#)

/// AWLRC 行格式 [mm:ss.xxx]<相对行首ms,字时长ms>字…；行时长取最后一个字结束，
/// 无字时长时取下一行起点差。
func awlrcToYrc(_ awlrc: String) -> String {
    struct Line { var start: Int; var text: String; var chars: [(Int, Int, String)] }
    var lines: [Line] = []
    for raw in awlrc.components(separatedBy: "\n") {
        guard let m = awlrcLineRegex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { continue }
        let mm = Int(raw[Range(m.range(at: 1), in: raw)!]) ?? 0
        let ss = Int(raw[Range(m.range(at: 2), in: raw)!]) ?? 0
        var frac = String(raw[Range(m.range(at: 3), in: raw)!])
        while frac.count < 3 { frac += "0" }
        let start = mm * 60000 + ss * 1000 + (Int(frac) ?? 0)
        let content = String(raw[Range(m.range(at: 4), in: raw)!])
        let ns = NSRange(content.startIndex..., in: content)
        var chars: [(Int, Int, String)] = []
        for cm in awlrcCharRegex.matches(in: content, range: ns) {
            let off = Int(content[Range(cm.range(at: 1), in: content)!]) ?? 0
            let d = Int(content[Range(cm.range(at: 2), in: content)!]) ?? 0
            let t = String(content[Range(cm.range(at: 3), in: content)!])
            if !t.isEmpty { chars.append((off, d, t)) }
        }
        if !chars.isEmpty { lines.append(Line(start: start, text: content, chars: chars)) }
    }
    var out: [String] = []
    for (idx, line) in lines.enumerated() {
        let end = line.chars.map { $0.0 + $0.1 }.max() ?? 0
        let dur: Int
        if end > 0 { dur = end }
        else if idx + 1 < lines.count { dur = lines[idx + 1].start - line.start }
        else { dur = 0 }
        let body = line.chars.map { "(\(line.start + $0.0),\($0.1),0)\($0.2)" }.joined()
        out.append("[\(line.start),\(dur)]\(body)")
    }
    return out.joined(separator: "\n")
}
