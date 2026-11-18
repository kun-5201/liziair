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
    /// 本地音乐导入：前端 liziNative.postMessage({type:'importLocal'}) → 文件选择器。
    private let localBridge = LocalFilesBridge()
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
        // 本地音乐导入桥：前端点「导入本地音乐」时 postMessage 到原生端弹文件选择器。
        config.userContentController.add(localBridge, name: "liziNative")
        let islandScript = WKUserScript(source: LiziIslandJS.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(islandScript)
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.scrollView.bounces = false
        super.init()
        // 导入桥要拿 webView 发导入完成事件（弱引用，不成环）。
        self.localBridge.webView = self.webView
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
        // 幂等：onAppear 可能多次触发；重复启动会建一个新端口的服务、丢掉
        // 旧服务，页面还指着旧端口，后续 /api 请求全变 Load failed。
        // 但上次启动失败过（failed）时要允许重试：先停掉旧服务再建新的。
        if failed { server?.stop(); server = nil }
        guard server == nil else { return }
        failed = false
        do {
            let server = try LocalHttpServer(router: router)
            self.server = server
            server.start()
            // 等 listener 就绪拿到端口再加载页面：冷启动时 0.5 秒未必够，
            // 每 250ms 查一次、最多 3 秒，拿不到才报失败。
            waitForPort(deadline: Date().addingTimeInterval(3))
            configureAudioSession()
            setupRemoteCommands()
            setupAudioInterruptions()
            startNowPlayingPolling()
        } catch {
            fail("启动本地服务失败：\(error.localizedDescription)")
        }
    }

    /// 轮询等端口（listener 就绪才有 port），拿到就加载页面。
    private func waitForPort(deadline: Date) {
        if let server, server.port > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.load(port: server.port)
            }
            return
        }
        guard Date() < deadline else {
            fail("本地服务没有拿到端口")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForPort(deadline: deadline)
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

    /// 第 12 轮第三件（切后台就暂停）：只配一次 session 不够——
    /// 电话/Siri/系统打断会让 session 失效，且没有任何回调把它激活回来；
    /// 回前台时 session 也可能还是非激活态，Web Audio 上下文就一直挂着。
    /// 中断结束、回到前台都重新激活一次，并让页面把 AudioContext resume
    /// 回来（window.__liziResumeWebAudio，见 player.js）；不改播放进度、
    /// 不重播。灵动岛那路不动。
    private func setupAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            self.reactivateAudioSession()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reactivateAudioSession()
        }
    }

    private func reactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 激活失败也不拦着；页面侧的 resume 仍会尝试。
        }
        webView.evaluateJavaScript("window.__liziResumeWebAudio && window.__liziResumeWebAudio()")
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
