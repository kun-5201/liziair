import Foundation
import Network

/// LIZI 本地 HTTP 服务：WKWebView 壳 + Swift 实现的 server.mjs。
/// 监听 127.0.0.1 动态端口，前端只跟同源 /api 说话，所以 public/ 的 API 层不用改。
/// 行为对标 server.mjs 的 createServer 分发顺序（见 Server/Router.swift）。

struct HttpRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// POST 的 JSON body；GET 时用 query。
    func jsonBody() -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    /// 合并 query + JSON body 后的参数（GET 只有 query，POST 以 body 为准）。
    var params: [String: Any] {
        var out: [String: Any] = query as [String: Any]
        for (k, v) in jsonBody() { out[k] = v }
        return out
    }

    func string(_ key: String, _ def: String = "") -> String {
        if let v = params[key] as? String { return v }
        if let v = params[key] as? NSNumber { return v.stringValue }
        return def
    }
    func int(_ key: String, _ def: Int = 0) -> Int {
        if let v = params[key] as? Int { return v }
        if let v = params[key] as? String, let n = Int(v) { return n }
        if let v = params[key] as? NSNumber { return v.intValue }
        return def
    }
    func bool(_ key: String, _ def: Bool = false) -> Bool {
        if let v = params[key] as? Bool { return v }
        if let v = params[key] as? String { return v == "true" || v == "1" }
        if let v = params[key] as? NSNumber { return v.boolValue }
        return def
    }
}

struct HttpResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, _ obj: Any) -> HttpResponse {
        // 先清洗：把 Optional.none 之类的非 JSON 值换成 null，避免整包失败。
        let data = (try? JSONSerialization.data(withJSONObject: sanitize(obj))) ?? Data("{}".utf8)
        return HttpResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
    }

    private static func sanitize(_ v: Any) -> Any {
        if v is NSNull || v is String || v is NSNumber { return v }
        if let d = v as? [String: Any] { return d.mapValues { sanitize($0) } }
        if let a = v as? [Any] { return a.map { sanitize($0) } }
        return NSNull()
    }

    static func text(_ status: Int, _ s: String, contentType: String = "text/plain; charset=utf-8") -> HttpResponse {
        HttpResponse(status: status, headers: ["Content-Type": contentType], body: Data(s.utf8))
    }

    static func error(_ status: Int, _ message: String) -> HttpResponse {
        .json(status, ["code": status, "error": message])
    }
}

final class LocalHttpServer {
    private var listener: NWListener?
    private let router: LiziRouter
    private(set) var port: Int = 0

    /// 优先固定端口：监听死掉重建时仍是同一个端口，页面 URL 不会失效。
    /// 固定端口被占时退回动态端口（首次就绪前失败才退，见 restartListener）。
    private static let preferredPort: UInt16 = 18791
    private var boundPort: NWEndpoint.Port?
    private var readyOnce = false
    private var restarts = 0
    private var stopped = false

    init(router: LiziRouter) throws {
        self.router = router
        self.listener = try makeListener(port: NWEndpoint.Port(rawValue: Self.preferredPort) ?? .any)
    }

    private func makeListener(port: NWEndpoint.Port) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑本机回环：和 server.mjs 的 127.0.0.1 一致，不对外暴露。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let l = try NWListener(using: params)
        boundPort = port
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = Int(l?.port?.rawValue ?? 0)
                self.readyOnce = true
                self.restarts = 0
            case .failed(let err):
                // 监听死掉（端口被占 / 运行中异常）：页面还指着旧端口，
                // 所有 /api 请求会立刻变 Load failed，必须自己重建。
                DiagLog.shared.recordEvent("listener failed: \(err.localizedDescription)")
                self.restartListener()
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.handleConnection(conn)
        }
        return l
    }

    func start() {
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
    }

    /// 监听失败后重建：已就绪过就用原来那个端口（页面 URL 不变）；
    /// 从没就绪过说明固定端口被占，改走动态端口。最多重试 3 次。
    private func restartListener() {
        guard !stopped, restarts < 3 else { return }
        restarts += 1
        listener?.cancel()
        listener = nil
        let port: NWEndpoint.Port = readyOnce ? (boundPort ?? .any) : .any
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                let l = try self.makeListener(port: port)
                self.listener = l
                l.start(queue: .global(qos: .userInitiated))
            } catch {
                DiagLog.shared.recordEvent("listener restart failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 连接处理（HTTP/1.1，每次响应后关闭连接；WKWebView 能正常工作）

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        Task {
            let t0 = Date()
            do {
                let req = try await readRequest(conn)
                let resp = await router.handle(req)
                try await writeResponse(conn, resp)
                DiagLog.shared.recordRequest(method: req.method, path: req.path,
                                             ms: Int(Date().timeIntervalSince(t0) * 1000), status: resp.status)
            } catch {
                // 读失败也尽量回一个 400：静默关连接会让前端 fetch 直接报
                // "Load failed"，除了一行文案什么信息都没有。
                let resp = HttpResponse.error(400, "bad request: \(error.localizedDescription)")
                try? await writeResponse(conn, resp)
                DiagLog.shared.recordRequest(method: "?", path: "(read-error)",
                                             ms: Int(Date().timeIntervalSince(t0) * 1000), status: 400)
            }
            conn.cancel()
        }
    }

    private func readRequest(_ conn: NWConnection) async throws -> HttpRequest {
        // 读到 header 结束符 \r\n\r\n
        var buf = Data()
        while true {
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<range.upperBound)
                var rest = buf.subdata(in: range.upperBound..<buf.endIndex)
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    throw NSError(domain: "LiziServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad header"])
                }
                let lines = headerText.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else {
                    throw NSError(domain: "LiziServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad request line"])
                }
                let method = String(parts[0])
                let rawTarget = String(parts[1])
                var headers: [String: String] = [:]
                for line in lines.dropFirst() where !line.isEmpty {
                    if let idx = line.firstIndex(of: ":") {
                        let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                while rest.count < contentLength {
                    let chunk = try await receive(conn, min(65536, max(1, contentLength - rest.count)))
                    // 对端提前关连接时 receive 会回空 Data：不抛错就会在这里
                    // 无限空转，这个连接永远不回包，前端一直等到 60 秒超时。
                    guard !chunk.isEmpty else {
                        throw NSError(domain: "LiziServer", code: 5, userInfo: [NSLocalizedDescriptionKey: "eof in body"])
                    }
                    rest.append(chunk)
                }
                let body = rest.prefix(contentLength)
                // 解析 path + query
                let target = rawTarget.removingPercentEncoding ?? rawTarget
                var path = target
                var query: [String: String] = [:]
                if let qIdx = target.firstIndex(of: "?") {
                    path = String(target[..<qIdx])
                    let qs = String(target[target.index(after: qIdx)...])
                    for pair in qs.split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 {
                            // query 里 + 代表空格（表单编码习惯，URLSearchParams
                            // 把空格编成 +）：先把 + 还原成空格再解 %XX。
                            // 注意顺序：%2B 在整条解码那步已变成 +，分不清是空格
                            // 还是字面 +（见 217 行），字面 + 极少见，接受这个 trade-off；
                            // 双编码的音频直链值里没有字面 +（原 + 是 %2B 形态），不受影响。
                            let kd = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                            let vd = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                            let k = kd.removingPercentEncoding ?? kd
                            let v = vd.removingPercentEncoding ?? vd
                            query[k] = v
                        } else if kv.count == 1 {
                            let kd = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                            query[kd.removingPercentEncoding ?? kd] = ""
                        }
                    }
                }
                // query 里的 + 已在上面按对解码前还原成空格（表单编码习惯）。
                return HttpRequest(method: method, path: path, query: query, headers: headers, body: Data(body))
            }
            let chunk = try await receive(conn, 65536)
            if chunk.isEmpty {
                throw NSError(domain: "LiziServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "eof before header"])
            }
            buf.append(chunk)
            if buf.count > 1_048_576 {
                throw NSError(domain: "LiziServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "header too large"])
            }
        }
    }

    private func receive(_ conn: NWConnection, _ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: length) { data, _, _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: data ?? Data()) }
            }
        }
    }

    private func writeResponse(_ conn: NWConnection, _ resp: HttpResponse) async throws {
        var head = "HTTP/1.1 \(resp.status) \(statusText(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = "\(resp.body.count)"
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: out, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
