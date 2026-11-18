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
/// window/self（= globalThis）、lx.utils.crypto（md5/sha1/sha256 +
/// aesEncrypt，杰翔/星澜拼网易 eapi 参数要用；纯 JS 实现，见 utilsJS）、
/// lx.utils.buffer（真字节数组：utf-8/base64/hex/latin1 互转；旧版只会
/// base64，杰翔的 bufToString(buf, 'hex') 会拿到错结果）、全局 Buffer
/// （星海/星澜用 Buffer.from/isBuffer）、setTimeout/setInterval/
/// clearTimeout/clearInterval（JSC 自带没有；野花/清凉/星澜/雨凝溪等
/// 脚本加载或取歌时就要用）。
/// lx.request 回调是 (err, resp, body)：resp 带 statusCode/headers/body/
/// url；options 的 body/data（POST 体，聚合脚本要发 JSON）、timeout（毫秒）
/// 会透传；缺了这些聚合脚本发不出 POST、读不到响应头。
///
/// 线程：JSContext 只在 jsQueue 这条串行队列上碰；网络请求走 URLSession，
/// 回调跳回 jsQueue 再调 JS。JSC 里未处理的 Promise rejection 不会崩 App
/// （脚本加载时的 checkUpdate 失败就是这么走的）.

// MARK: - lx 运行时装配（自定义源共用，只有一份；内置源已删）

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

        // lx.request(url, options, cb)：cb(err, resp, body)，resp.body 已按 JSON
        // 解析过（解析失败时是原始字符串），body（第 3 参）恒为原始字符串；
        // resp.headers 是响应头（原大小写 + 小写各一份，幻音/杰翔/星海/星澜/
        // 轻量读它），resp.url 是跟随重定向后的最终地址。
        // options 透传：body/data（POST 体：字符串直接用，对象转 JSON；聚合
        // 脚本发 JSON 时必须有它，旧版直接丢弃导致服务端收到空 POST）、
        // timeout（毫秒，默认 15 秒，夹在 2~30 秒之间）。
        // ctx 只弱引用：实例被删（源被删除/刷新）后，未完成的网络回调不再往已死的
        // JSContext 里调，不留悬空引用。
        let requestBlock: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [weak ctx] urlValue, optionsValue, callbackValue in
            guard let ctx,
                  let urlString = urlValue?.toString(),
                  let url = URL(string: urlString),
                  let callback = callbackValue, !callback.isUndefined else { return }
            var method = "GET"
            var headers: [String: String] = [:]
            var httpBody: Data?
            var timeout: TimeInterval = 15
            if let options = optionsValue, !options.isUndefined {
                if let m = options.forProperty("method")?.toString(), !m.isEmpty { method = m }
                if let h = options.forProperty("headers")?.toDictionary() as? [String: String] {
                    headers = h
                } else if let h = options.forProperty("headers")?.toDictionary() {
                    for (k, v) in h { if let ks = k as? String { headers[ks] = "\(v)" } }
                }
                // POST 体：body 优先，data 是 axios 风格的别名。
                let bodyValue = options.forProperty("body")
                let dataValue = (bodyValue == nil || bodyValue!.isUndefined) ? options.forProperty("data") : bodyValue
                if let v = dataValue, !v.isUndefined {
                    if let s = v.toString(), !v.isObject || v.isString {
                        httpBody = Data(s.utf8)
                    } else if let dict = v.toDictionary(),
                              let json = try? JSONSerialization.data(withJSONObject: dict) {
                        httpBody = json
                    }
                }
                if let ms = options.forProperty("timeout")?.toNumber()?.doubleValue, ms > 0 {
                    timeout = min(30, max(2, ms / 1000))
                }
            }
            Task {
                do {
                    let (data, resp) = try await Upstream.fetch(url, headers: headers, timeout: timeout, method: method, body: httpBody)
                    let rawText = String(data: data, encoding: .utf8) ?? ""
                    LXScriptInstance.jsQueue.async { [weak ctx] in
                        guard let ctx else { return }
                        let respObj = JSValue(newObjectIn: ctx)!
                        respObj.setValue(resp.statusCode, forProperty: "statusCode")
                        if let obj = try? JSONSerialization.jsonObject(with: data),
                           JSONSerialization.isValidJSONObject(obj) {
                            respObj.setValue(JSValue(object: obj, in: ctx) as Any, forProperty: "body")
                        } else {
                            respObj.setValue(rawText, forProperty: "body")
                        }
                        var headerDict: [String: String] = [:]
                        for (k, v) in resp.allHeaderFields {
                            if let ks = k as? String, let vs = v as? String {
                                headerDict[ks] = vs
                                headerDict[ks.lowercased()] = vs
                            }
                        }
                        respObj.setValue(headerDict, forProperty: "headers")
                        if let finalURL = resp.url?.absoluteString {
                            respObj.setValue(finalURL, forProperty: "url")
                        }
                        _ = callback.call(withArguments: [JSValue(undefinedIn: ctx)!, respObj, rawText])
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
        // aesEncrypt（data, mode, key, iv）是 utilsJS 里的纯 JS 实现（AES-CBC/ECB，
        // PKCS7，返回字节 buffer；杰翔/星澜拼网易 eapi 参数要用，缺了取歌时抛
        // "utils.crypto.aesEncrypt is not a function"）。
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
        if let aesFn = ctx.globalObject?.forProperty("__lxAesEncrypt"), !aesFn.isUndefined {
            cryptoObj.setValue(aesFn, forProperty: "aesEncrypt")
        }
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
    var __lxB64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var __lxUtf8Bytes = function (str) {
      str = String(str);
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
    };
    var __lxUtf8Decode = function (bytes) {
      var out = '';
      for (var i = 0; i < bytes.length;) {
        var c = bytes[i];
        if (c < 0x80) { out += String.fromCharCode(c); i++; }
        else if ((c & 0xe0) === 0xc0 && i + 1 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80) {
          out += String.fromCharCode(((c & 0x1f) << 6) | (bytes[i + 1] & 0x3f)); i += 2;
        } else if ((c & 0xf0) === 0xe0 && i + 2 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
          out += String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f)); i += 3;
        } else if ((c & 0xf8) === 0xf0 && i + 3 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80 && (bytes[i + 3] & 0xc0) === 0x80) {
          var cp = ((c & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
          cp -= 0x10000;
          out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff)); i += 4;
        } else { out += '\\ufffd'; i++; }
      }
      return out;
    };
    var __lxBytesToBase64 = function (bytes) {
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
    var __lxBase64ToBytes = function (str) {
      var clean = String(str).replace(/[^A-Za-z0-9+/=]/g, '');
      var bytes = [];
      for (var i = 0; i < clean.length; i += 4) {
        var n = (__lxB64Chars.indexOf(clean[i]) << 18) | (__lxB64Chars.indexOf(clean[i + 1]) << 12) |
                ((clean[i + 2] === '=' ? 0 : __lxB64Chars.indexOf(clean[i + 2])) << 6) |
                (clean[i + 3] === '=' ? 0 : __lxB64Chars.indexOf(clean[i + 3]));
        bytes.push((n >> 16) & 255);
        if (clean[i + 2] !== '=') bytes.push((n >> 8) & 255);
        if (clean[i + 3] !== '=') bytes.push(n & 255);
      }
      return bytes;
    };
    var __lxBytesToHex = function (bytes) {
      var out = '';
      for (var i = 0; i < bytes.length; i++) { var h = bytes[i].toString(16); out += h.length === 1 ? '0' + h : h; }
      return out;
    };
    var __lxHexToBytes = function (str) {
      str = String(str).replace(/[^0-9a-fA-F]/g, '');
      var bytes = [];
      for (var i = 0; i + 1 < str.length; i += 2) bytes.push(parseInt(str.substr(i, 2), 16));
      return bytes;
    };
    var __lxToBytes = function (data, enc) {
      if (data && data.__lxBytes !== undefined) return data.__lxBytes.slice();
      if (data && typeof data.length === 'number' && typeof data !== 'string') {
        var arr = [];
        for (var i = 0; i < data.length; i++) arr.push(data[i] & 255);
        return arr;
      }
      var s = String(data == null ? '' : data);
      enc = (enc || 'utf-8').toLowerCase();
      if (enc === 'base64') return __lxBase64ToBytes(s);
      if (enc === 'hex') return __lxHexToBytes(s);
      if (enc === 'latin1' || enc === 'binary') {
        var l = [];
        for (var j = 0; j < s.length; j++) l.push(s.charCodeAt(j) & 255);
        return l;
      }
      return __lxUtf8Bytes(s);
    };
    var __lxMakeBuffer = function (bytes) {
      var buf = { __lxBytes: bytes, length: bytes.length };
      for (var i = 0; i < bytes.length; i++) buf[i] = bytes[i];
      buf.toString = function (enc) {
        enc = (enc || 'utf-8').toLowerCase();
        if (enc === 'base64') return __lxBytesToBase64(bytes);
        if (enc === 'hex') return __lxBytesToHex(bytes);
        if (enc === 'latin1' || enc === 'binary') {
          var s = '';
          for (var k = 0; k < bytes.length; k++) s += String.fromCharCode(bytes[k]);
          return s;
        }
        return __lxUtf8Decode(bytes);
      };
      return buf;
    };
    var __lxBuffer = {
      from: function (data, enc) { return __lxMakeBuffer(__lxToBytes(data, enc || 'utf-8')); },
      bufToString: function (buf, enc) {
        enc = (enc || 'utf-8').toLowerCase();
        var bytes = __lxToBytes(buf, 'utf-8');
        if (enc === 'base64') return __lxBytesToBase64(bytes);
        if (enc === 'hex') return __lxBytesToHex(bytes);
        if (enc === 'latin1' || enc === 'binary') {
          var s = '';
          for (var k = 0; k < bytes.length; k++) s += String.fromCharCode(bytes[k]);
          return s;
        }
        return __lxUtf8Decode(bytes);
      }
    };
    // atob/btoa：JSC 自带没有，这里用纯 JS 补（Latin-1 语义，和浏览器一致）。
    var __lxAtob = function (s) {
      var bytes = __lxBase64ToBytes(s);
      var out = '';
      for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
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
      return __lxBytesToBase64(bytes);
    };
    // Buffer：JSC 自带没有；星海/星澜等脚本用 Buffer.from/isBuffer（有 typeof
    // 守卫，缺了只会降级，但补上后行为与桌面端一致）。
    var Buffer = {
      from: function (data, enc) { return __lxMakeBuffer(__lxToBytes(data, enc || 'utf-8')); },
      isBuffer: function (v) { return !!(v && v.__lxBytes !== undefined); },
      alloc: function (size, fill) {
        var b = [];
        for (var i = 0; i < size; i++) b.push(fill || 0);
        return __lxMakeBuffer(b);
      },
      byteLength: function (s) { return __lxToBytes(s, 'utf-8').length; },
      concat: function (list) {
        var out = [];
        for (var i = 0; i < list.length; i++) { var b = __lxToBytes(list[i], 'utf-8'); for (var j = 0; j < b.length; j++) out.push(b[j]); }
        return __lxMakeBuffer(out);
      }
    };
    // AES 加密（与落雪桌面端 utils.crypto.aesEncrypt 同款签名：
    // aesEncrypt(data, mode, key, iv)，mode 如 'aes-128-ecb' / 'aes-256-cbc'；
    // 只加密，返回字节 buffer（杰翔/星澜拿它拼网易 eapi 参数，再经
    // utils.buffer.bufToString(buf, 'hex') 转十六进制）。
    var __lxAesEncrypt = (function () {
      function gfMul(a, b) {
        var p = 0;
        for (var i = 0; i < 8; i++) {
          if (b & 1) p ^= a;
          var hi = a & 0x80;
          a = (a << 1) & 0xff;
          if (hi) a ^= 0x1b;
          b >>= 1;
        }
        return p;
      }
      function gfInv(a) {
        if (a === 0) return 0;
        var r = 1;
        for (var i = 0; i < 254; i++) r = gfMul(r, a);
        return r;
      }
      var SBOX = [];
      for (var i = 0; i < 256; i++) {
        var inv = gfInv(i), s = inv;
        for (var k = 1; k <= 4; k++) s ^= ((inv << k) | (inv >> (8 - k))) & 0xff;
        SBOX.push((s ^ 0x63) & 0xff);
      }
      var RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];
      function expandKey(keyBytes) {
        var Nk = keyBytes.length / 4, Nr = Nk + 6, w = [];
        for (var n = 0; n < Nk; n++) w.push(keyBytes.slice(n * 4, n * 4 + 4));
        for (var m = Nk; m < 4 * (Nr + 1); m++) {
          var t = w[m - 1].slice();
          if (m % Nk === 0) t = [SBOX[t[1]] ^ RCON[m / Nk - 1], SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]];
          else if (Nk > 6 && m % Nk === 4) t = t.map(function (b) { return SBOX[b]; });
          w.push(w[m - Nk].map(function (b, j) { return b ^ t[j]; }));
        }
        return { w: w, Nr: Nr };
      }
      function encryptBlock(block, w, Nr) {
        function addKey(s, round) {
          for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) s[r + 4 * c] ^= w[round * 4 + c][r];
        }
        function sub(s) { for (var q = 0; q < 16; q++) s[q] = SBOX[s[q]]; }
        function shift(s) {
          var t = s.slice();
          for (var r = 0; r < 4; r++) for (var c = 0; c < 4; c++) s[r + 4 * c] = t[r + 4 * ((c + r) % 4)];
        }
        function mix(s) {
          for (var c = 0; c < 4; c++) {
            var a = [s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3]];
            s[4 * c] = gfMul(a[0], 2) ^ gfMul(a[1], 3) ^ a[2] ^ a[3];
            s[4 * c + 1] = a[0] ^ gfMul(a[1], 2) ^ gfMul(a[2], 3) ^ a[3];
            s[4 * c + 2] = a[0] ^ a[1] ^ gfMul(a[2], 2) ^ gfMul(a[3], 3);
            s[4 * c + 3] = gfMul(a[0], 3) ^ a[1] ^ a[2] ^ gfMul(a[3], 2);
          }
        }
        var s = block.slice();
        addKey(s, 0);
        for (var round = 1; round < Nr; round++) { sub(s); shift(s); mix(s); addKey(s, round); }
        sub(s); shift(s); addKey(s, Nr);
        return s;
      }
      function fit(bytes, len) {
        var out = [];
        for (var i = 0; i < len; i++) out.push(i < bytes.length ? bytes[i] & 0xff : 0);
        return out;
      }
      return function (data, mode, key, iv) {
        var m = String(mode || 'aes-128-cbc').toLowerCase();
        var bits = m.indexOf('256') >= 0 ? 256 : m.indexOf('192') >= 0 ? 192 : 128;
        var ecb = m.indexOf('ecb') >= 0;
        var kb = expandKey(fit(__lxUtf8Bytes(key || ''), bits / 8));
        var ivb = fit(__lxUtf8Bytes(iv || ''), 16);
        var plain = __lxUtf8Bytes(data);
        var pad = 16 - (plain.length % 16);
        for (var i = 0; i < pad; i++) plain.push(pad);
        var out = [], prev = ivb.slice();
        for (var off = 0; off < plain.length; off += 16) {
          var block = plain.slice(off, off + 16);
          if (!ecb) block = block.map(function (b, j) { return b ^ prev[j]; });
          var enc = encryptBlock(block, kb.w, kb.Nr);
          for (var q = 0; q < 16; q++) out.push(enc[q]);
          prev = enc;
        }
        return __lxMakeBuffer(out);
      };
    })();
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

    /// 脚本 inited 上报的全部平台（不论有没有 musicUrl 动作）：校验失败时
    /// 拿来告诉用户脚本到底上报了什么（如只上报了 [git]，那 wy/tx/kg/kw
    /// 的歌永远走不到它），而不是一句笼统的「没有可用的 musicUrl 音源」。
    var reportedPlatforms: [String] {
        sink.initedSources.map(\.key).sorted()
    }

    /// 是否已注册 request 处理（只在 jsQueue 上读，见 waitForRequestHandler）。
    private var hasRequestHandlerOnQueue: Bool { sink.requestHandler != nil }

    /// 加载脚本：装运行时 + evaluateScript + 校验注册了 request 处理。
    /// 成功后 loaded = true；失败不记 loaded，下次 resolve 会重试加载。
    /// 只能在 jsQueue 之外的线程调（内部 jsQueue.sync）。
    /// 有的脚本（如独家音源）先拉远程配置再注册 request 处理：evaluateScript
    /// 刚回来时 handler 还是空的，loadOnQueue 不在这里直接判死刑，load()
    /// 在外面等一等（最多 5 秒，见 waitForRequestHandler）；同步注册的当场
    /// 就到，不等。
    func load() throws {
        var loadError: Error?
        Self.jsQueue.sync {
            if loaded { return }
            do {
                try loadOnQueue(requireHandler: false)
            } catch { loadError = error }
        }
        if let loadError { throw loadError }
        if !hasRequestHandler() {
            waitForRequestHandler()
            if !hasRequestHandler() {
                throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "不是有效的落雪音源脚本：5 秒内没有注册 request 处理"])
            }
        }
        // 只有 handler 就绪才记 loaded；没就绪时不记，下次 resolve 会重试加载。
        Self.jsQueue.sync { loaded = true }
    }

    private func hasRequestHandler() -> Bool {
        Self.jsQueue.sync { self.hasRequestHandlerOnQueue }
    }

    /// 等 request 处理注册：跟 waitForInited 同款轮询（最多 5 秒；同步注册的
    /// 当场就到，不等）。只能在 jsQueue 之外调。
    func waitForRequestHandler(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasRequestHandler() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
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
    /// songName：酷我分支另传的真歌名（Router 酷我分支），引擎里填
    /// musicInfo.name；其余平台为空，name 回退到 songId（原行为）。
    func resolveMusicUrl(source: String, songId: String, quality: String, songName: String = "") async throws -> (String, String) {
        guard !songId.isEmpty else {
            throw NSError(domain: "LXScript", code: 6, userInfo: [NSLocalizedDescriptionKey: "缺少歌曲 ID"])
        }
        var lastError: Error?
        for tier in Self.tiersFrom(quality) {
            do {
                let url = try await callScriptMusicUrl(source: source, songId: songId, quality: tier, songName: songName)
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

    private func callScriptMusicUrl(source: String, songId: String, quality: String, songName: String = "") async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.callScriptMusicUrlOnce(source: source, songId: songId, quality: quality, songName: songName) }
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

    private func callScriptMusicUrlOnce(source: String, songId: String, quality: String, songName: String = "") async throws -> String {
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
                    // musicInfo 只给 songmid 是不够的：脚本按平台读不同字段，
                    // 缺哪个就直接抛错（溯音/落雪的 kw、mg 分支要求 musicInfo.name，
                    // 没有就 throw「需要歌曲名」——酷我每首歌都走不到源，这就是
                    // 「有的音源无法识别」的一半原因）。Router 只传了一个 songId
                    // 进来（Router.swift 只读，不能改）：按平台把这个 songId
                    // 别名到脚本要读的字段上——Router 给 kw 传的就是歌名、给 kg
                    // 传的是 hash 或「歌名 歌手」、给 tx 传 mid、给 wy 传数字 id，
                    // 正好就是各平台脚本要的东西。只补别名，不改 songmid 本身；
                    // singer/albumName 上游没传进来，留空（脚本里都是 `|| ''`）。
                    var musicInfo: [String: Any] = ["songmid": songId, "songId": songId, "source": source]
                    switch source {
                    case "kw", "mg":
                        // 歌名另传（Router 酷我分支）：songId 是 rid（新音源后端
                        // 只要 rid，传歌名回 parameter error），name 仍填真歌名，
                        // 旧脚本读 name 不受影响；没传歌名时回退到 songId（原行为）。
                        musicInfo["name"] = songName.isEmpty ? songId : songName
                    case "kg":
                        if songId.count == 32 && songId.allSatisfy({ $0.isHexDigit }) {
                            musicInfo["hash"] = songId
                        } else {
                            musicInfo["name"] = songId
                        }
                    case "tx":
                        musicInfo["mid"] = songId
                    case "wy":
                        musicInfo["id"] = songId
                        musicInfo["songid"] = songId
                    default:
                        break
                    }
                    let payload: [String: Any] = [
                        "action": "musicUrl",
                        "source": source,
                        "info": ["musicInfo": musicInfo, "type": quality],
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

    private func loadOnQueue(requireHandler: Bool = true) throws {
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
        // BOM（U+FEFF）JSC 当空白处理，本来就能跑；这里去掉只是为了让
        // header 解析和后续处理干净，行为不变。
        let text = scriptText.hasPrefix("\u{FEFF}") ? String(scriptText.dropFirst()) : scriptText
        ctx.evaluateScript(text)
        if let exc = ctx.exception {
            throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "落雪脚本加载失败：\(exc)"])
        }
        // load() 从外面等（requireHandler: false），见 load() 注释；
        // loadAssumingOnQueue 在 jsQueue 上等不了，这里直接判。
        if requireHandler {
            guard freshSink.requestHandler != nil else {
                throw NSError(domain: "LXScript", code: -1, userInfo: [NSLocalizedDescriptionKey: "不是有效的落雪音源脚本：没有注册 request 处理"])
            }
        }
    }
}
