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
    private let listener: NWListener
    private let router: LiziRouter
    private(set) var port: Int = 0

    init(router: LiziRouter) throws {
        self.router = router
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑本机回环：和 server.mjs 的 127.0.0.1 一致，不对外暴露。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: params)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = Int(self?.listener.port?.rawValue ?? 0)
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.handleConnection(conn)
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() { listener.cancel() }

    // MARK: - 连接处理（HTTP/1.1，每次响应后关闭连接；WKWebView 能正常工作）

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        Task {
            do {
                let req = try await readRequest(conn)
                let resp = await router.handle(req)
                try await writeResponse(conn, resp)
            } catch {
                // 读失败就直接关连接，不回包。
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
                            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                            let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                            query[k] = v
                        } else if kv.count == 1 {
                            query[String(kv[0])] = ""
                        }
                    }
                }
                // 相对路径里的 + 号在 query 里代表空格（表单编码习惯）
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
