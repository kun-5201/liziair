import Foundation
import WebKit

/// 歌词灵动岛桥接：网页播放器 → 原生 Live Activity。
///
/// 网页端（liziair 前端）自己已经有歌词（多源 LRC，含逐字），并渲染在
/// #lyrics 里（每行 `.ly`，当前行 `.ly.is-active`，正文在 `.ly__main` 里）。
/// 原生端不重新取词，只读 DOM 里已经算好的当前行 / 上一行 / 下一行 +
/// 播放进度，推灵动岛。这样歌词来源、断句、逐字高亮都和页面上显示的
/// 完全一致，也不用再走一遍网易接口。
///
/// 桥：注入一段 JS（WKUserScript，document end），每 1 秒把当前状态
/// postMessage 到 `liziBridge`；原生端 WKScriptMessageHandler 收到后
/// 交给 LiziIslandCoordinator，按行变 / 切歌 / 播放暂停切换立刻推，
/// 进度最多 5 秒推一次（Apple 的 Live Activity 更新预算）。

// MARK: - 注入的 JS

enum LiziIslandJS {
    /// 每 1 秒收集一次播放状态并 postMessage 到原生。
    /// 全部防御式写法：元素不存在 / Player 未加载时返回 null 字段，不抛错。
    static let script = """
    (function () {
      if (window.__liziIslandBridgeInstalled) return;
      window.__liziIslandBridgeInstalled = true;

      function getAudio() {
        try {
          if (typeof Player !== 'undefined' && Player && Player.audio) return Player.audio;
        } catch (e) {}
        var audios = document.querySelectorAll('audio');
        for (var i = 0; i < audios.length; i++) {
          if (!audios[i].paused) return audios[i];
        }
        for (var j = 0; j < audios.length; j++) {
          if (audios[j].src) return audios[j];
        }
        return audios[0] || null;
      }

      function lineText(el) {
        if (!el) return null;
        var main = el.querySelector('.ly__main');
        var t = (main ? main.textContent : el.textContent || '').trim();
        return t ? t : null;
      }

      function collect() {
        var title = (document.title || '').trim();
        var audio = getAudio();
        var cur = 0, total = 0, playing = false;
        if (audio) {
          cur = audio.currentTime || 0;
          total = audio.duration || 0;
          playing = !audio.paused;
        } else {
          var btn = document.getElementById('btn-play');
          var label = btn ? (btn.getAttribute('aria-label') || '') : '';
          var cls = btn ? btn.className : '';
          playing = label.indexOf('暂停') >= 0 || cls.indexOf('playing') >= 0 || cls.indexOf('pause') >= 0;
        }
        var box = document.getElementById('lyrics');
        var current = null, prev = null, next = null;
        if (box) {
          var active = box.querySelector('.ly.is-active');
          if (active) {
            current = lineText(active);
            var idx = parseInt(active.getAttribute('data-i') || '-1', 10);
            if (idx > 0) prev = lineText(box.querySelector('.ly[data-i="' + (idx - 1) + '"]'));
            next = lineText(box.querySelector('.ly[data-i="' + (idx + 1) + '"]'));
          }
        }
        return {
          title: title,
          playing: playing,
          currentTime: cur,
          duration: total,
          currentLyric: current,
          prevLyric: prev,
          nextLyric: next
        };
      }

      function post() {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liziBridge;
          if (h) h.postMessage(collect());
        } catch (e) {}
      }

      setInterval(post, 1000);
    })();
    """
}

// MARK: - 原生端：收消息

/// 网页状态的一次快照。
struct LiziPlaybackSnapshot {
    let title: String
    let artist: String
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let currentLyric: String?
    let prevLyric: String?
    let nextLyric: String?
}

/// WKScriptMessageHandler：收 JS 每秒 post 过来的播放状态，转交给 coordinator。
final class LyricsBridge: NSObject, WKScriptMessageHandler {
    weak var coordinator: LiziIslandCoordinator?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "liziBridge",
              let body = message.body as? [String: Any] else { return }
        let titleRaw = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !titleRaw.isEmpty, titleRaw != "LIZI · 粒子播放器" else { return }
        // document.title 是 "歌名 · 歌手"（app.js 切歌时写的格式）
        let parts = titleRaw.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let title = parts.first ?? titleRaw
        let artist = parts.count > 1 ? parts[1] : ""
        let snap = LiziPlaybackSnapshot(
            title: title,
            artist: artist,
            isPlaying: (body["playing"] as? Bool) ?? false,
            currentTime: (body["currentTime"] as? Double) ?? 0,
            duration: (body["duration"] as? Double) ?? 0,
            currentLyric: body["currentLyric"] as? String,
            prevLyric: body["prevLyric"] as? String,
            nextLyric: body["nextLyric"] as? String
        )
        // WKScriptMessageHandler 回调在主线程；coordinator 不是 @MainActor，
        // 直接同步调用即可。
        coordinator?.receive(snapshot: snap)
    }
}

// MARK: - 协调器：快照 → Live Activity

/// 把网页快照翻译成 Live Activity 状态。节流规则与岛上歌词一致：
/// 行变 / 切歌 / 播放暂停切换时立刻推；进度最多 5 秒推一次。
/// 注意：不是 @MainActor（WebHost 不是 MainActor，要同步创建它）。
final class LiziIslandCoordinator {
    let liveActivity = LiveActivityManager()
    let bridge = LyricsBridge()

    private(set) var currentLine: String = "♪"

    private var lastTitle = ""
    private var lastArtist = ""
    private var lastLine: String?
    private var lastPlaying: Bool?
    private var lastProgressUpdate: Date = .distantPast
    private let progressRefreshInterval: TimeInterval = 5

    init() {
        bridge.coordinator = self
    }

    func receive(snapshot: LiziPlaybackSnapshot) {
        let trackChanged = snapshot.title != lastTitle || snapshot.artist != lastArtist
        let lineChanged = snapshot.currentLyric != lastLine
        let playChanged = snapshot.isPlaying != lastPlaying
        let now = Date()
        let progressDue = snapshot.isPlaying
            && now.timeIntervalSince(lastProgressUpdate) >= progressRefreshInterval
        guard trackChanged || lineChanged || playChanged || progressDue else { return }

        lastTitle = snapshot.title
        lastArtist = snapshot.artist
        lastLine = snapshot.currentLyric
        lastPlaying = snapshot.isPlaying
        lastProgressUpdate = now

        let current = snapshot.currentLyric ?? "♪"
        currentLine = current
        let progress: Double
        if snapshot.duration > 0 {
            progress = min(max(snapshot.currentTime / snapshot.duration, 0), 1)
        } else {
            progress = 0
        }
        let state = LiziLyricsAttributes.ContentState(
            currentLyric: current,
            prevLyric: snapshot.prevLyric,
            nextLyric: snapshot.nextLyric,
            progress: progress,
            isPlaying: snapshot.isPlaying
        )
        if trackChanged || !liveActivity.isRunning {
            liveActivity.startActivity(title: snapshot.title, artist: snapshot.artist, state: state)
        } else {
            liveActivity.updateActivity(state: state)
        }
    }

    /// 歌停了时收掉岛。平时靠 staleDate 15s 自动消失，这里是显式收尾。
    func endIsland() {
        liveActivity.endActivity()
        lastTitle = ""
        lastArtist = ""
        lastLine = nil
        lastPlaying = nil
    }
}
