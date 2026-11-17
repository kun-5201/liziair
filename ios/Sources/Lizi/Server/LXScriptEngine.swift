import Foundation
import JavaScriptCore
import CryptoKit

/// 落雪音源脚本引擎：用 JavaScriptCore 跑用户在「自定义源管理」里导入的
/// LX Music 源脚本，取歌走脚本的 musicUrl。
///
/// 一个脚本 = 一个独立 JSContext（LXScriptInstance），互不串台；所有 JSContext
/// 只在同一条串行队列 jsQueue 上碰。lx 运行时（request / on / send / utils /
/// EVENT_NAMES / console）的装配只有一份（LXScriptRuntime.install）。
///
/// lx 运行时照 KMusic 二进制里的桥来：
///   exp.musicUrl(source, musicInfo, quality)、exp.sources、actions；
///   env = "mobile"，version = "2.12.0"（和 KMusic 的 lx-music-mobile/2.12.0 UA 一致）。
/// 另外补了真实落雪宿主会给、但 KMusic 桥没有的几样（pdone 仓库的源脚本要用，
/// 没有就加载即崩）：lx.currentScriptInfo（脚本头注释）、atob/btoa、
/// window/self（= globalThis）、lx.utils.crypto（md5/sha1/sha256）、
/// setTimeout/setInterval/clearTimeout/clearInterval（JSC 自带没有；
/// 野花/清凉/星澜/雨凝溪等脚本加载或取歌时就要用）。
///
/// 线程：JSContext 只在 jsQueue 这条串行队列上碰；网络请求走 URLSession，
/// 回调跳回 jsQueue 再调 JS。JSC 里未处理的 Promise rejection 不会崩 App
/// （脚本加载时的 checkUpdate 失败就是这么走的）.

// MARK: - lx 运行时装配（内置源 / 自定义源共用，只有一份）

/// lx.send('inited') 带回来的 sources、lx.on('request') 注册的处理函数。
/// 引用类型：装配时挂进 JS 的 block 直接写它，实例从它读。
final class LXScriptSink {
    var requestHandler: JSValue?
    /// source -> actions（inited 事件上报的 musicSources）。
    var initedSources: [String: [String]] = [:]
}

enum LXScriptRuntime {
    /// 往一个全新的 JSContext 里装 console + globalThis.lx（request/on/send/
    /// utils/EVENT_NAMES/env/version）。装完调用方再 evaluateScript(脚本)。
    /// sink 由调用方持有：request 处理函数和 inited sources 都写进它。
    /// scriptInfo：脚本头注释解析出的 name/version/author/description，
    /// 装成 lx.currentScriptInfo（真实落雪宿主会给；野花/野草拿它拼请求头，
    /// 没有就读 undefined.version 直接崩）。缺字段就传 ""，不缺整个对象。
    static func install(into ctx: JSContext, sink: LXScriptSink, scriptInfo: [String: String] = [:]) {
        ctx.exceptionHandler = { _, exc in
            if let exc { print("[lx] JS exception: \(exc)") }
        }

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
        // ctx 只弱引用：实例被删（源被删除/刷新）后，未完成的网络回调不再往已死的
        // JSContext 里调，不留悬空引用。
        let requestBlock: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak ctx] urlValue, optionsValue, callbackValue in
            guard let ctx,
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
                    LXScriptInstance.jsQueue.async { [weak ctx] in
                        guard let ctx else { return }
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
                    LXScriptInstance.jsQueue.async { [weak ctx] in
                        guard let ctx else { return }
                        _ = callback.call(withArguments: [message, JSValue(undefinedIn: ctx)!])
                    }
                }
            }
        }
        lx.setValue(JSValue(object: requestBlock, in: ctx)!, forProperty: "request")

        // lx.on(event, handler)：只接 request 事件。
        let onBlock: @convention(block) (JSValue?, JSValue?) -> Void = { eventValue, handlerValue in
            guard eventValue?.toString() == "request",
                  let handler = handlerValue, !handler.isUndefined else { return }
            sink.requestHandler = handler
        }
        lx.setValue(JSValue(object: onBlock, in: ctx)!, forProperty: "on")

        // lx.send(event, data)：inited 带 sources（记下来当覆盖平台）；
        // updateAlert 只记日志。
        let sendBlock: @convention(block) (JSValue?, JSValue?) -> Void = { eventValue, dataValue in
            switch eventValue?.toString() {
            case "inited":
                if let sources = dataValue?.forProperty("sources")?.toDictionary() {
                    var parsed: [String: [String]] = [:]
                    for (key, value) in sources {
                        guard let name = key as? String,
                              let entry = value as? [String: Any] else { continue }
                        if let actions = entry["actions"] as? [String] {
                            parsed[name] = actions
                        } else if let actions = entry["actions"] as? [Any] {
                            parsed[name] = actions.map { "\($0)" }
                        }
                    }
                    sink.initedSources = parsed
                }
            case "updateAlert":
                print("[lx] updateAlert（脚本有更新，不自动处理）")
            default:
                break
            }
        }
        lx.setValue(JSValue(object: sendBlock, in: ctx)!, forProperty: "send")

        // lx.currentScriptInfo：脚本自己的头注释（见 install 注释）。
        let info = JSValue(newObjectIn: ctx)!
        for (k, v) in scriptInfo { info.setValue(v, forProperty: k) }
        lx.setValue(info, forProperty: "currentScriptInfo")

        ctx.setObject(lx, forKeyedSubscript: "lx" as NSString)

        // utils.buffer（纯 JS，和 Node 验证用的同一份代码；只给 local 源的 base64 用）。
        ctx.evaluateScript(LXScriptRuntime.utilsJS)
        ctx.evaluateScript("lx.utils = { buffer: __lxBuffer };")

        // lx.utils.crypto：md5/sha1/sha256（独家音源这类脚本签名请求要用）。
        // 复用现成的 Native 实现，不在 JS 里重写一遍。
        let md5Block: @convention(block) (String) -> String = { NetEaseCrypto.md5Hex($0) }
        let sha1Block: @convention(block) (String) -> String = { s in
            Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let sha256Block: @convention(block) (String) -> String = { s in
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let cryptoObj = JSValue(newObjectIn: ctx)!
        cryptoObj.setValue(JSValue(object: md5Block, in: ctx)!, forProperty: "md5")
        cryptoObj.setValue(JSValue(object: sha1Block, in: ctx)!, forProperty: "sha1")
        cryptoObj.setValue(JSValue(object: sha256Block, in: ctx)!, forProperty: "sha256")
        if let utils = lx.forProperty("utils") { utils.setValue(cryptoObj, forProperty: "crypto") }

        // atob/btoa（JSC 自带没有；独家音源加载时就要用）与 window/self
        //（六音读 window.console；都指向 globalThis）。
        ctx.evaluateScript("var atob = __lxAtob; var btoa = __lxBtoa; var window = globalThis; var self = globalThis;")

        // setTimeout/setInterval/clearTimeout/clearInterval（JSC 自带没有；
        // 野花/清凉/星澜/雨凝溪等脚本加载或取歌时就要用）。回调一律跳回 jsQueue
        // 再调 JS；取消后不再触发；fn 弱引用，上下文释放后自动停。
        let timers = LXTimerState()
        let setTimeoutBlock: @convention(block) (JSValue?, Double) -> Double = { [weak ctx] fn, ms in
            guard let ctx, let fn, !fn.isUndefined else { return 0 }
            return timers.schedule(ctx: ctx, fn: fn, ms: ms, repeats: false)
        }
        let setIntervalBlock: @convention(block) (JSValue?, Double) -> Double = { [weak ctx] fn, ms in
            guard let ctx, let fn, !fn.isUndefined else { return 0 }
            return timers.schedule(ctx: ctx, fn: fn, ms: ms, repeats: true)
        }
        let clearTimeoutBlock: @convention(block) (Double) -> Void = { id in timers.cancel(id: id) }
        ctx.setObject(JSValue(object: setTimeoutBlock, in: ctx)!, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject(JSValue(object: setIntervalBlock, in: ctx)!, forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject(JSValue(object: clearTimeoutBlock, in: ctx)!, forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject(JSValue(object: clearTimeoutBlock, in: ctx)!, forKeyedSubscript: "clearInterval" as NSString)
    }

    /// utils.buffer 的 JS 实现（和 /tmp/lx-test/lx-utils.js 同一份逻辑）。
    static let utilsJS = """
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
    // atob/btoa：JSC 自带没有，这里用纯 JS 补（Latin-1 语义，和浏览器一致）。
    var __lxB64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var __lxAtob = function (s) {
      var str = String(s).replace(/[^A-Za-z0-9+/=]/g, '');
      var out = '';
      for (var i = 0; i < str.length; i += 4) {
        var n = (__lxB64Chars.indexOf(str[i]) << 18) | (__lxB64Chars.indexOf(str[i + 1]) << 12) |
                ((str[i + 2] === '=' ? 0 : __lxB64Chars.indexOf(str[i + 2])) << 6) |
                (str[i + 3] === '=' ? 0 : __lxB64Chars.indexOf(str[i + 3]));
        out += String.fromCharCode((n >> 16) & 255);
        if (str[i + 2] !== '=') out += String.fromCharCode((n >> 8) & 255);
        if (str[i + 3] !== '=') out += String.fromCharCode(n & 255);
      }
      return out;
    };
    var __lxBtoa = function (s) {
      var str = String(s);
      var bytes = [];
      for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c > 0xff) throw new Error('btoa: The string to be encoded contains characters outside of the Latin1 range.');
        bytes.push(c);
      }
      var out = '';
      for (var i = 0; i < bytes.length; i += 3) {
        var b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
        var n = (b0 << 16) | ((b1 || 0) << 8) | (b2 || 0);
        out += __lxB64Chars[(n >> 18) & 63] + __lxB64Chars[(n >> 12) & 63];
        out += (b1 === undefined) ? '=' : __lxB64Chars[(n >> 6) & 63];
        out += (b2 === undefined) ? '=' : __lxB64Chars[n & 63];
      }
      return out;
    };
    """
}

// MARK: - 定时器（setTimeout/setInterval，JSC 自带没有）

/// 每个 JSContext 一份（install() 里创建，block 捕获它）：回调跳回 jsQueue 再调 JS。
final class LXTimerState {
    private let lock = NSLock()
    private var nextId: Double = 1
    private var cancelled: Set<Double> = []

    func schedule(ctx: JSContext, fn: JSValue, ms: Double, repeats: Bool) -> Double {
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        fire(ctx: ctx, fn: fn, ms: ms, repeats: repeats, id: id)
        return id
    }

    private func fire(ctx: JSContext, fn: JSValue, ms: Double, repeats: Bool, id: Double) {
        let delay = max(0, ms) / 1000.0
        LXScriptInstance.jsQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak ctx, weak fn] in
            guard let self, let ctx, let fn else { return }
            self.lock.lock()
            let dead = self.cancelled.contains(id)
            self.lock.unlock()
            guard !dead else { return }
            _ = fn.call(withArguments: [])
            if repeats { self.fire(ctx: ctx, fn: fn, ms: ms, repeats: repeats, id: id) }
        }
    }

    func cancel(id: Double) {
        lock.lock()
        cancelled.insert(id)
        lock.unlock()
    }
}

// MARK: - 单脚本实例（一个源脚本 = 一个独立 JSContext）

/// 一个落雪源脚本的运行实例：独立 JSContext + 独立 request 处理。
/// load() 必须在 jsQueue 之外的线程调（内部 jsQueue.sync；Router 的 Task 里调没问题）。
/// load() 成功后才能调 resolveMusicUrl；load() 失败抛错，调用方按「无效脚本」处理。
final class LXScriptInstance {
    /// 所有实例共用一条串行队列：JSContext 不是线程安全的，跨实例也串行。
    static let jsQueue = DispatchQueue(label: "com.lty5201.lizi.lxscript")

    /// 脚本支持的档位（按从高到低回退；脚本没有 flac，flac 按 flac24bit 算）。
    static let scriptTiers = ["master", "atmos", "hires", "flac24bit", "320k", "128k"]

    let scriptText: String

    private var context: JSContext?
    private var sink = LXScriptSink()
    /// 只在 jsQueue 上读/写（load() 的检查在 jsQueue.sync 里做，
    /// loadAssumingOnQueue 本来就在 jsQueue 上），不需要额外的锁。
    private var loaded = false

    init(script: String) {
        self.scriptText = script
    }

    /// 脚本 inited 上报的、带 musicUrl 动作的平台（去掉 'local' 伪源）。
    /// 只能在 load() 成功后读。
    var platforms: [String] {
        sink.initedSources
            .filter { $0.key != "local" && $0.value.contains("musicUrl") }
            .map(\.key).sorted()
    }

    /// 加载脚本：装运行时 + evaluateScript + 校验注册了 request 处理。
    /// 成功后 loaded = true；失败不记 loaded，下次 resolve 会重试加载。
    /// 只能在 jsQueue 之外的线程调（内部 jsQueue.sync）。
    func load() throws {
        var loadError: Error?
        Self.jsQueue.sync {
            if loaded { return }
            do {
                try loadOnQueue()
                loaded = true
            } catch { loadError = error }
        }
        if let loadError { throw loadError }
    }

    /// 已在 jsQueue 上时用：直接加载，不再 sync（load() 从 jsQueue 里调会死锁）。
    func loadAssumingOnQueue() throws {
        if loaded { return }
        try loadOnQueue()
        loaded = true
    }

    /// 等 inited：有的脚本（如 juhe）先拉远程配置再发 inited，load() 返回时
    /// platforms 还是空的。导入校验在读 platforms 前调这个等一等（最多 5 秒；
    /// 同步发 inited 的脚本当场就到，不等）。只能在 jsQueue 之外调
    /// （内部用 jsQueue.sync 读，sleep 的间隙 jsQueue 是空的，不会死锁）。
    /// deadline 版：批量校验多个脚本时共用一个期限，免得每个坏脚本各等 5 秒。
    func waitForInited(timeout: TimeInterval = 5) {
        waitForInited(deadline: Date().addingTimeInterval(timeout))
    }

    func waitForInited(deadline: Date) {
        while Date() < deadline {
            let has = Self.jsQueue.sync { !self.platforms.isEmpty }
            if has { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// 按档位从高到低回退，返回 (url, 实际档位)。只跑脚本，不回退内置解析。
    func resolveMusicUrl(source: String, songId: String, quality: String) async throws -> (String, String) {
        guard !songId.isEmpty else {
            throw NSError(domain: "LXScript", code: 6, userInfo: [NSLocalizedDescriptionKey: "缺少歌曲 ID"])
        }
        var lastError: Error?
        for tier in Self.tiersFrom(quality) {
            do {
                let url = try await callScriptMusicUrl(source: source, songId: songId, quality: tier)
                return (url, tier)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "LXScript", code: 2, userInfo: [NSLocalizedDescriptionKey: "落雪脚本未返回音频链接"])
    }

    static func tiersFrom(_ quality: String) -> [String] {
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
            Self.jsQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "引擎已释放"]))
                    return
                }
                do {
                    try self.loadAssumingOnQueue()
                    guard let ctx = self.context, let handler = self.sink.requestHandler else {
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

    private func loadOnQueue() throws {
        guard let ctx = JSContext() else {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "JSContext 创建失败"])
        }
        // 换一个全新的 sink + context：刷新/重载后旧的 request 处理不再生效。
        let freshSink = LXScriptSink()
        self.context = ctx
        self.sink = freshSink
        let scriptInfo: [String: String] = [
            "name": LXSourceStore.headerValue(scriptText, "name") ?? "",
            "version": LXSourceStore.headerValue(scriptText, "version") ?? "",
            "author": LXSourceStore.headerValue(scriptText, "author") ?? "",
            "description": LXSourceStore.headerValue(scriptText, "description") ?? "",
        ]
        LXScriptRuntime.install(into: ctx, sink: freshSink, scriptInfo: scriptInfo)
        if let exc = ctx.exception {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "运行时安装失败：\(exc)"])
        }
        ctx.evaluateScript(scriptText)
        if let exc = ctx.exception {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本加载失败：\(exc)"])
        }
        guard freshSink.requestHandler != nil else {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "不是有效的落雪音源脚本：没有注册 request 处理"])
        }
    }
}
