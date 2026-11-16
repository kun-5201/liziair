import SwiftUI
import UIKit
import WebKit
import AVFoundation
import MediaPlayer

/// WKWebView 壳：启动 Swift 本地服务，加载 http://127.0.0.1:<port>/（1:1 的 liziair 前端）。
/// 后台播放：AVAudioSession .playback + audio 后台模式；锁屏/控制中心用
/// MPNowPlayingInfoCenter 显示当前曲目（读 document.title + #btn-play 状态）。

struct ContentView: View {
    @StateObject private var host = WebHost()

    var body: some View {
        ZStack {
            WebViewRepresentable(host: host)
                .ignoresSafeArea()
            if host.failed {
                VStack(spacing: 12) {
                    Text("本地服务启动失败")
                        .font(.headline)
                    Text(host.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("重试") { host.start() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .onAppear { host.start() }
    }
}

// MARK: - WebView 宿主

final class WebHost: NSObject, ObservableObject, WKUIDelegate {
    private var server: LocalHttpServer?
    private var router = LiziRouter()
    let webView: WKWebView
    /// 歌词灵动岛：网页播放状态 → Live Activity。
    private let islandCoordinator = LiziIslandCoordinator()
    @Published var failed = false
    @Published var errorMessage = ""

    private var nowPlayingTimer: Timer?
    private var lastTitle = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 播放由用户手势触发；页面内 <audio> 走本机代理，同源没有 CORS 问题。
        config.mediaTypesRequiringUserActionForPlayback = []
        // 歌词灵动岛桥：注入 JS 每秒把播放状态 postMessage 到原生端。
        config.userContentController.add(islandCoordinator.bridge, name: "liziBridge")
        let islandScript = WKUserScript(source: LiziIslandJS.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(islandScript)
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.scrollView.bounces = false
        super.init()
        // window.open（设置页 QQ 群 / 赞助行）交给系统浏览器/对应 App 打开；
        // 不设 uiDelegate 时 WKWebView 会直接丢弃新窗口请求，按钮点了没反应。
        self.webView.uiDelegate = self
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return nil
    }

    func start() {
        failed = false
        do {
            // 外部 LX 服务地址（设置页「落雪音源」里填，存 UserDefaults；默认内置解析）。
            if let lxURL = UserDefaults.standard.string(forKey: "lxApiUrl"), !lxURL.isEmpty {
                LXResolver.externalApiURL = lxURL
            }
            if let lxKey = UserDefaults.standard.string(forKey: "lxApiKey") {
                LXResolver.externalApiKey = lxKey
            }
            let server = try LocalHttpServer(router: router)
            self.server = server
            server.start()
            // 等 listener 就绪拿到端口再加载页面。
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let server = self.server, server.port > 0 else {
                    DispatchQueue.main.async { self?.fail("本地服务没有拿到端口") }
                    return
                }
                DispatchQueue.main.async { self.load(port: server.port) }
            }
            configureAudioSession()
            setupRemoteCommands()
            startNowPlayingPolling()
        } catch {
            fail("启动本地服务失败：\(error.localizedDescription)")
        }
    }

    private func fail(_ msg: String) {
        errorMessage = msg
        failed = true
    }

    private func load(port: Int) {
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
    }

    // MARK: - 后台播放

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 音频会话配不上也不拦着进页面；后台播放会受影响。
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-play"); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-play"); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-next"); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-prev"); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-play"); return .success
        }
    }

    private func clickButton(_ id: String) {
        webView.evaluateJavaScript("document.getElementById('\(id)')?.click()")
    }

    /// 每 2 秒读一次 document.title（app.js 切歌时会写成“歌名 · 歌手”），
    /// 以及 #btn-play 的状态，更新锁屏 Now Playing。不做歌词岛。
    private func startNowPlayingPolling() {
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollNowPlaying()
        }
    }

    private func pollNowPlaying() {
        let js = """
        (() => {
          const title = document.title || '';
          const btn = document.getElementById('btn-play');
          const cls = btn ? btn.className : '';
          const label = btn ? (btn.getAttribute('aria-label') || '') : '';
          return JSON.stringify({ title, cls, label });
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let title = obj["title"], !title.isEmpty,
                  title != "LIZI · 粒子播放器" else { return }
            // 歌名 · 歌手（app.js 切歌时写的格式）
            let parts = title.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let track = parts.first ?? title
            let artist = parts.count > 1 ? parts[1] : ""
            let cls = obj["cls"] ?? ""
            let label = obj["label"] ?? ""
            // 按钮上是“暂停”含义时正在播放；认不出时默认按播放中显示。
            let playing = label.contains("暂停") || cls.contains("playing") || cls.contains("pause")
                || (!label.contains("播放") && !cls.contains("paused"))
            if title != self.lastTitle || playing != (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0) {
                self.lastTitle = title
                var info: [String: Any] = [
                    MPMediaItemPropertyTitle: track,
                    MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
                ]
                if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let host: WebHost

    func makeUIView(context: Context) -> WKWebView {
        host.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
