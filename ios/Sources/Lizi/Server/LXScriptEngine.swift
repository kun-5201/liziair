import Foundation
import JavaScriptCore

/// 落雪音源脚本引擎：用 JavaScriptCore 跑 KMusic 的 落雪音源.js v1.0.3，
/// 取歌走脚本的 musicUrl，替代 LX.swift 的内置 tx/wy 解析。
/// 脚本文件在 Bundle 里 public/落雪音源.js（原样，未改动），以后换源就是换文件。
///
/// lx 运行时（request / on / send / utils / EVENT_NAMES）照 KMusic 二进制里的桥来：
///   exp.musicUrl(source, musicInfo, quality)、exp.sources、actions；
///   env = "mobile"，version = "2.12.0"（和 KMusic 的 lx-music-mobile/2.12.0 UA 一致）。
/// 自定义服务器（LX_API_URL）仍走 LXResolver.resolveViaExternalServer，不经过这里。
/// kg/kw/mg 脚本里没有，仍走 LXResolver 内置解析；脚本全部档位失败时也回退到内置解析，
/// 别让一次上游故障直接断播。
///
/// 线程：JSContext 只在 jsQueue 这条串行队列上碰；网络请求走 URLSession，
/// 回调跳回 jsQueue 再调 JS。JSC 里未处理的 Promise rejection 不会崩 App
/// （脚本加载时的 checkUpdate 失败就是这么走的）。

final class LXScriptEngine {
    static let shared = LXScriptEngine()

    /// 脚本支持的档位（按从高到低回退；脚本没有 flac，flac 按 flac24bit 算）。
    static let scriptTiers = ["master", "atmos", "hires", "flac24bit", "320k", "128k"]
    static let scriptSources = ["wy", "tx"]

    private let jsQueue = DispatchQueue(label: "com.lty5201.lizi.lxscript")
    private var context: JSContext?
    private var requestHandler: JSValue?
    private var loaded = false

    private init() {}

    // MARK: - 对外入口

    /// 按档位从高到低回退，返回 (url, 实际档位)。
    func resolveMusicUrl(source: String, songId: String, quality: String) async throws -> (String, String) {
        guard !songId.isEmpty else {
            throw NSError(domain: "LXScript", code: 6, userInfo: [NSLocalizedDescriptionKey: "缺少歌曲 ID"])
        }
        // 脚本只支持 tx/wy；kg/kw/mg 直接走内置解析。
        guard Self.scriptSources.contains(source) else {
            return try await LXResolver.resolveMusicUrl(source: source, songId: songId, quality: quality)
        }
        let tiers = Self.tiersFrom(quality)
        var lastError: Error?
        for tier in tiers {
            do {
                let url = try await callScriptMusicUrl(source: source, songId: songId, quality: tier)
                return (url, tier)
            } catch {
                lastError = error
            }
        }
        // 脚本全部档位失败，回退内置解析（oiapi 备用）。
        do {
            return try await LXResolver.resolveMusicUrl(source: source, songId: songId, quality: quality)
        } catch {
            throw lastError ?? error
        }
    }

    private static func tiersFrom(_ quality: String) -> [String] {
        var q = LXResolver.normalizeQuality(quality)
        if q == "flac" { q = "flac24bit" }
        let idx = scriptTiers.firstIndex(of: q) ?? 0
        return Array(scriptTiers[idx...])
    }

    // MARK: - 调脚本（带单档位 20 秒上限）

    private func callScriptMusicUrl(source: String, songId: String, quality: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.callScriptMusicUrlOnce(source: source, songId: songId, quality: quality) }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本超时（\(source)/\(quality)）"])
            }
            guard let url = try await group.next() else {
                throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本无返回"])
            }
            group.cancelAll()
            return url
        }
    }

    private func callScriptMusicUrlOnce(source: String, songId: String, quality: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            jsQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "引擎已释放"]))
                    return
                }
                do {
                    try self.ensureLoaded()
                    guard let ctx = self.context, let handler = self.requestHandler else {
                        throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本未就绪"])
                    }
                    let payload: [String: Any] = [
                        "action": "musicUrl",
                        "source": source,
                        "info": ["musicInfo": ["songmid": songId], "type": quality],
                    ]
                    guard let payloadValue = JSValue(object: payload, in: ctx) else {
                        throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "请求构造失败"])
                    }
                    guard let promise = handler.call(withArguments: [payloadValue]), !promise.isUndefined else {
                        throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本异常：\(ctx.exception?.toString() ?? "未知")"])
                    }
                    guard promise.hasProperty("then") else {
                        throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本未返回 Promise"])
                    }
                    let fulfilled: @convention(block) (JSValue?) -> Void = { value in
                        let url = value?.toString() ?? ""
                        if url.hasPrefix("http://") || url.hasPrefix("https://") {
                            cont.resume(returning: url)
                        } else {
                            cont.resume(throwing: NSError(domain: "LXScript", code: 2, userInfo: [NSLocalizedDescriptionKey: "落雪脚本未返回音频链接"]))
                        }
                    }
                    let rejected: @convention(block) (JSValue?) -> Void = { value in
                        cont.resume(throwing: NSError(domain: "LXScript", code: 2, userInfo: [NSLocalizedDescriptionKey: value?.toString() ?? "落雪脚本取歌失败"]))
                    }
                    guard let f = JSValue(object: fulfilled, in: ctx),
                          let r = JSValue(object: rejected, in: ctx) else {
                        throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "回调构造失败"])
                    }
                    _ = promise.invokeMethod("then", withArguments: [f, r])
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 加载脚本（只在 jsQueue 上跑）

    private func ensureLoaded() throws {
        if loaded { return }
        let ctx = JSContext()
        ctx.exceptionHandler = { _, exc in
            if let exc { print("[lx] JS exception: \(exc)") }
        }
        self.context = ctx

        // console：JSC 自带没有；日志截断，免得脚本每次请求都把整个响应打出来。
        let logBlock: @convention(block) (String, String) -> Void = { level, message in
            print("[lx] [\(level)] \(message.prefix(2000))")
        }
        ctx.setObject(JSValue(object: logBlock, in: ctx)!, forKeyedSubscript: "__lxNativeLog" as NSString)
        ctx.evaluateScript("""
        var console = {
          log: function () { __lxNativeLog('log', Array.prototype.slice.call(arguments).map(function (a) { try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch (e) { return String(a); } }).join(' ')); },
          error: function () { __lxNativeLog('error', Array.prototype.slice.call(arguments).map(function (a) { try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch (e) { return String(a); } }).join(' ')); },
          group: function () {}, groupEnd: function () {}
        };
        """)

        // lx 运行时对象。
        let lx = JSValue(newObjectIn: ctx)!
        let eventNames = JSValue(newObjectIn: ctx)!
        eventNames.setValue("request", forProperty: "request")
        eventNames.setValue("inited", forProperty: "inited")
        eventNames.setValue("updateAlert", forProperty: "updateAlert")
        lx.setValue(eventNames, forProperty: "EVENT_NAMES")
        lx.setValue("mobile", forProperty: "env")
        lx.setValue("2.12.0", forProperty: "version")

        // lx.request(url, options, cb)：cb(err, resp)，resp.body 已按 JSON 解析过。
        let requestBlock: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak self] urlValue, optionsValue, callbackValue in
            guard let self,
                  let urlString = urlValue?.toString(),
                  let url = URL(string: urlString),
                  let callback = callbackValue, !callback.isUndefined else { return }
            var method = "GET"
            var headers: [String: String] = [:]
            if let options = optionsValue, !options.isUndefined {
                if let m = options.forProperty("method")?.toString(), !m.isEmpty { method = m }
                if let h = options.forProperty("headers")?.toDictionary() as? [String: String] {
                    headers = h
                } else if let h = options.forProperty("headers")?.toDictionary() {
                    for (k, v) in h { if let ks = k as? String { headers[ks] = "\(v)" } }
                }
            }
            Task {
                do {
                    let (data, resp) = try await Upstream.fetch(url, headers: headers, timeout: 15, method: method)
                    self.jsQueue.async {
                        guard let ctx = self.context else { return }
                        let respObj = JSValue(newObjectIn: ctx)!
                        respObj.setValue(resp.statusCode, forProperty: "statusCode")
                        if let obj = try? JSONSerialization.jsonObject(with: data),
                           JSONSerialization.isValidJSONObject(obj) {
                            respObj.setValue(JSValue(object: obj, in: ctx) as Any, forProperty: "body")
                        } else {
                            respObj.setValue(String(data: data, encoding: .utf8) ?? "", forProperty: "body")
                        }
                        _ = callback.call(withArguments: [JSValue(undefinedIn: ctx)!, respObj])
                    }
                } catch {
                    let message = error.localizedDescription
                    self.jsQueue.async {
                        guard let ctx = self.context else { return }
                        _ = callback.call(withArguments: [message, JSValue(undefinedIn: ctx)!])
                    }
                }
            }
        }
        lx.setValue(JSValue(object: requestBlock, in: ctx)!, forProperty: "request")

        // lx.on(event, handler)：只接 request 事件。
        let onBlock: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] eventValue, handlerValue in
            guard let self, eventValue?.toString() == "request",
                  let handler = handlerValue, !handler.isUndefined else { return }
            self.requestHandler = handler
        }
        lx.setValue(JSValue(object: onBlock, in: ctx)!, forProperty: "on")

        // lx.send(event, data)：inited 带 sources；updateAlert 只记日志。
        let sendBlock: @convention(block) (JSValue?, JSValue?) -> Void = { eventValue, _ in
            if eventValue?.toString() == "updateAlert" {
                print("[lx] updateAlert（脚本有更新，不自动处理）")
            }
        }
        lx.setValue(JSValue(object: sendBlock, in: ctx)!, forProperty: "send")

        ctx.setObject(lx, forKeyedSubscript: "lx" as NSString)

        // utils.buffer（纯 JS，和 Node 验证用的同一份代码；只给 local 源的 base64 用）。
        ctx.evaluateScript(LXScriptEngine.utilsJS)
        ctx.evaluateScript("lx.utils = { buffer: __lxBuffer };")
        if let exc = ctx.exception {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "运行时安装失败：\(exc)"])
        }

        guard let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("public/落雪音源.js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到 public/落雪音源.js"])
        }
        ctx.evaluateScript(script)
        if let exc = ctx.exception {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本加载失败：\(exc)"])
        }
        guard requestHandler != nil else {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本没有注册 request 处理"])
        }
        loaded = true
    }

    /// utils.buffer 的 JS 实现（和 /tmp/lx-test/lx-utils.js 同一份逻辑）。
    private static let utilsJS = """
    var __lxB64 = (function () {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      function utf8Bytes(str) {
        var bytes = [];
        for (var i = 0; i < str.length; i++) {
          var c = str.charCodeAt(i);
          if (c < 0x80) bytes.push(c);
          else if (c < 0x800) { bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
          else if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) {
            var c2 = str.charCodeAt(i + 1);
            if (c2 >= 0xdc00 && c2 < 0xe000) {
              var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
              bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
              i++;
            } else { bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
          } else { bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
        }
        return bytes;
      }
      function encode(str) {
        var bytes = utf8Bytes(String(str));
        var out = '';
        for (var i = 0; i < bytes.length; i += 3) {
          var b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
          var n = (b0 << 16) | ((b1 || 0) << 8) | (b2 || 0);
          out += chars[(n >> 18) & 63] + chars[(n >> 12) & 63];
          out += (b1 === undefined) ? '=' : chars[(n >> 6) & 63];
          out += (b2 === undefined) ? '=' : chars[n & 63];
        }
        return out;
      }
      return { encode: encode };
    })();
    var __lxBuffer = {
      from: function (data, enc) { return { __lxBuf: String(data), __enc: enc || 'utf-8' }; },
      bufToString: function (buf, enc) {
        var s = (buf && buf.__lxBuf !== undefined) ? buf.__lxBuf : String(buf);
        if (enc === 'base64') return __lxB64.encode(s);
        return s;
      }
    };
    """
}
