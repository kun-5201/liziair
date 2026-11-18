/**
 * 前端 API 层：只跟本机服务端说话，服务端再转发网易云。
 * 图片统一走 /api/img 代理（网易云封面有防盗链，直接 <img src> 会被拒）。
 */
const API = (() => {
  /* 请求超时：服务端连上了却不回包（上游卡死）时，fetch 默认会一直等，
     界面就永远停在“正在载入”。给每个请求一个上限，超时按普通错误处理。 */
  const timeout = (ms) => {
    try { return AbortSignal.timeout(ms); } catch { return undefined; }
  };

  /* 音频代理地址：直链里的 url 参数必须编两次码。
     原因见 2026-11-18 播放断点实测：服务端 HttpServer.readRequest 会先对
     整条 target 做一次 removingPercentEncoding，再按 & 切 query——单次编码
     的 %26（直链里 ?a=1&b=2 的 &）会被提前解码成真的 &，url 参数在第一个
     & 处被截断（QQ vkey 丢 vkey → 403，长青丢 id → 522），播放器静默无声。
     编两次后：整条解码一次还剩 %26，切 query 不会误切；服务端再对值解一次，
     还原成原始直链。只动音频代理这四处，不动 /api/img 等其它路由。 */
  const proxyAudioUrl = (prefix, u) => (u ? `/${prefix}?url=${encodeURIComponent(encodeURIComponent(u))}` : '');

  async function call(path, params, method = 'POST', extraSignal) {
    const url = new URL('/api/' + path, location.origin);
    let body;
    if (method === 'POST') {
      body = JSON.stringify(params || {});
    } else {
      for (const [k, v] of Object.entries(params || {})) url.searchParams.set(k, v);
    }
    const headers = method === 'POST' ? { 'Content-Type': 'application/json' } : undefined;
    /* 外部 abort（例如关掉 QQ 登录面板时停掉在飞的拿码请求）与 60 秒超时二选一：
       AbortSignal.any 能同时要两个时就都要，老 WebKit 没有它时以外层信号为准
       （服务端拿码本身约 43 秒封顶，不会无限挂起）。 */
    const t = timeout(60000);
    const signal = extraSignal
      ? (t && typeof AbortSignal.any === 'function' ? AbortSignal.any([t, extraSignal]) : extraSignal)
      : t;
    const opts = { method, headers, body, signal };
    try {
      const res = await fetch(url, opts);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    } catch (e) {
      /* 只有网络层失败（本机服务掉了个连接，如 WKWebView 的 "Load failed"）
         才重试一次：换一条新连接往往就通了。HTTP 错误和 60 秒超时 abort
         不重试——前者重试也没用，后者重试只会再等 60 秒。 */
      const msg = String((e && e.message) || e);
      const isNet = e && e.name === 'TypeError'
        && /Load failed|Failed to fetch|NetworkError|Network request failed/i.test(msg);
      if (!isNet) throw e;
      await new Promise((r) => setTimeout(r, 300));
      try {
        const res2 = await fetch(url, { method, headers, body, signal });
        if (!res2.ok) throw new Error(`HTTP ${res2.status}`);
        return res2.json();
      } catch (e2) {
        if (e2 && e2.name === 'AbortError') throw e2;
        throw new Error(`本地服务连接失败（${String((e2 && e2.message) || e2)}），请重启 App 后重试`);
      }
    }
  }

  /**
   * 和 call() 一样，但**不因 HTTP 500/502 抛异常** —— 直接把响应体还回来。
   * 边车起不来时服务端会回 502 + { code, error, reason }（例如「本机 node 版本不足」），
   * 界面要能显示这个原因，而不是一句 "HTTP 502"。
   */
  async function callSoft(path, params) {
    const url = new URL('/api/' + path, location.origin);
    for (const [k, v] of Object.entries(params || {})) if (v !== undefined && v !== null) url.searchParams.set(k, v);
    let res;
    try {
      res = await fetch(url, { signal: timeout(60000) });
    } catch (e) {
      return { code: 0, ok: false, error: String(e.message) };
    }
    try {
      const body = await res.json();
      if (res.ok) return body;
      return { code: res.status, ok: false, ...body };
    } catch {
      return { code: res.status, ok: false, error: `HTTP ${res.status}` };
    }
  }

  /**
   * POST 但**不因 HTTP 400 抛异常**：扫码收尾（/api/login/harvest）和粘贴 cookie
   * （/api/session/import）失败时服务端会回 400 + { ok:false, reason, message }，
   * 界面要显示那句 message（例如「cookie 无效或已过期」），而不是 "HTTP 400"。
   */
  async function postSoft(path, params) {
    let res;
    try {
      res = await fetch(new URL('/api/' + path, location.origin), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(params || {}),
        signal: timeout(60000),
      });
    } catch (e) {
      return { code: 0, ok: false, message: String(e.message) };
    }
    let body;
    try { body = await res.json(); } catch { body = {}; }
    return res.ok ? body : { code: res.status, ok: false, ...body };
  }

  /** 网易云封面多数是 http://，页面是 http:// 本机，混用没问题；统一转为代理地址 */
  const img = (u, size = 200) => {
    if (!u) return '';
    // 网易云支持 ?param=w×h 直接让服务端缩图，省流量
    const withSize = u.includes('?') ? u : `${u}?param=${size}y${size}`;
    return `/api/img?url=${encodeURIComponent(withSize)}`;
  };

  return {
    img,
    session: () => call('session', {}, 'GET'),

    /* 扫码：走网易云边车（services/netease-api/，和 Folia 同一个 API 服务），
       不再用我们手写的那条 weapi/eapi 通道（上游稳定回 8821）。
       服务端已经把边车的形状对齐成 { code, key, qrimg } / { code, message }。 */
    qrKey: () => call('netease/login/qr/key', {}, 'GET'),
    qrCheck: (key) => call('netease/login/qr/check', { key }, 'GET'),
    /** 803 之后收 cookie：服务端只取 MUSIC_U / __csrf 写进 .session.json，响应里没有值 */
    harvest: (key) => postSoft('login/harvest', { key }),
    /** 粘贴 cookie 登录（备用，也是最稳的一条）。成功 { ok:true, profile }，失败 { ok:false, message } */
    importCookie: (cookie) => postSoft('session/import', { cookie }),
    /** 边车存活探测（验收 / 排查用）：{ ok, port } */
    neteaseHealth: () => callSoft('netease/health'),
    logout: () => call('logout'),

    userPlaylists: (uid) => call('user/playlist', { uid }),
    /** 网易「我的云盘」（用户自己上传的歌）：取链第二档用。{ code, songs:[{songId,name,artists,album,fileSize,fileName}], count, hasMore }。
       未登录时上游回 301，调用方（player.js 云盘腿）直接跳过这一档，不弹登录。 */
    neteaseCloud: (limit = 200, offset = 0) => call('user/cloud', { limit, offset }, 'GET'),
    /** 个人主页：头像/背景图/签名/等级/听歌量/关注粉丝。匿名可读公开信息 */
    userDetail: (uid) => call('user/detail', { uid }),
    playlistDetail: (id) => call('playlist/detail', { id }),
    /** 收藏的专辑（铺色态「我的专辑」层）：{ data:[{id,name,picUrl,size,artists:[{name}]}], count, hasMore } */
    neteaseAlbumSublist: (limit = 100, offset = 0) => call('netease/album/sublist', { limit, offset }, 'GET'),
    /* 音质档位由 window.LIZI_QUALITY 决定（public/audio/eq-engine.js 维护、可持久化）。
       调 player.js 那一行 `API.songUrl(track.id)` 因此不用改就能用上新音质。 */
    songUrl: (ids, level) => call('song/url', {
      ids: Array.isArray(ids) ? ids.join(',') : ids,
      level: level || (typeof window !== 'undefined' && window.LIZI_QUALITY) || 'exhigh',
    }),
    /** 批量取曲目详情（含封面）：搜索先返回曲目、封面后补就走这条（见 app.js renderTracks） */
    songDetail: (ids) => call('song/detail', { ids: Array.isArray(ids) ? ids.join(',') : ids }),
    songWiki: (id) => call('song/wiki', { id }),
    /* 直链要走本机代理：网易云 CDN 不回 ACAO，而 <audio> 带着 crossOrigin='anonymous'
       （Web Audio 取频谱用），直接挂 CDN 地址会被 CORS 拦成 net::ERR_FAILED。 */
    neteaseAudio: (u) => proxyAudioUrl('api/netease/audio', u),
    lyric: (id) => call('lyric', { id }),
    /** 网易每日签到（第 11 轮 kun 对齐：后端 /api/daily/signin，weapi /point/dailyTask type 0+1；未登录回 {code:301, loggedIn:false}）。暂无界面入口，先把调用接好。 */
    dailySignin: () => call('daily/signin', {}),
    search: (s, limit = 30) => call('search', { s, limit }),
    personalized: () => call('personalized'),
    /** 网易云「每日推荐」歌曲（和桌面大厅同一条路）；未登录时上游回空，调用方自己降级 */
    neteaseDaily: () => call('netease/recommend/songs', {}, 'GET'),
    /** 推荐歌单（大厅下滑那一屏）。返回 { playlists:[{id,name,cover,count,creator,tracks}] } */
    topPlaylists: (limit = 12, cat = '全部', order = 'hot') =>
      call('top/playlist', { limit, cat, order }),

    /* ------------------------------------------------------------------
       QQ 音乐（独立边车，第一次请求时由 server.mjs 自动拉起）
       形状和上面网易云那套保持一致：都回 { code, ... }。
       注意 QQ 的曲目 id 是 songmid（字符串），不是数字。
       ------------------------------------------------------------------ */
    qqHealth: () => call('qq/health', {}, 'GET'),
    qqStatus: () => call('qq/status', {}, 'GET'),
    /** 登录已失效时，本地旧凭据里还能读到的公开身份（uid / nickname / avatar），不是登录态 */
    qqCachedProfile: () => callSoft('qq/cached-profile'),
    /** 拿二维码：一次就回 { key, qrimg }，qrimg 是 data:image/png;base64,... */
    qqQrKey: (channel = 'qqmusic', signal) => call('qq/login/qr/key', { channel }, 'GET', signal),
    /** 801 等待 / 802 待确认 / 803 成功 / 800 过期 */
    qqQrCheck: (key) => call('qq/login/qr/check', { key }, 'GET'),
    /** 取消旧的扫码会话（关掉它的 MQTT 驱动）：换一张/关面板时调，别留着旧驱动空跑 */
    qqQrCancel: (key) => call('qq/login/qr/cancel', { key }, 'GET'),
    qqLogout: () => call('qq/logout', {}, 'GET'),
    qqSearch: (s, limit = 20) => call('qq/search', { s, limit }, 'GET'),
    qqSongUrl: (mid, quality = '128') => call('qq/song/url', { mid, quality }, 'GET'),
    qqLyric: (mid) => call('qq/lyric', { mid }, 'GET'),
    /* 铺色态的内容（2026-11-06）：推荐歌单 / 新歌 / 歌单详情 / 我的 都是同一个翻译层 */
    qqRecommendPlaylists: (limit = 9) => call('qq/recommend/playlists', { limit }, 'GET'),
    qqNewSongs: (limit = 30) => call('qq/recommend/new-songs', { limit }, 'GET'),
    qqPlaylistDetail: (id) => call('qq/playlist/detail', { id }, 'GET'),
    qqLikedSongs: (limit = 100) => call('qq/user/liked-songs', { limit }, 'GET'),
    qqUserPlaylists: () => call('qq/user/playlists', {}, 'GET'),
    qqDailySongs: () => call('qq/user/daily-songs', {}, 'GET'),
    /** 雷达推荐：匿名可用，未登录时当「每日推荐」的兜底 */
    qqRecommendRadar: (page = 1) => call('qq/recommend/radar', { page }, 'GET'),
    /** 电台频道目录（匿名）；点开频道听歌要登录，见 qqRadioTracks */
    qqRadioCategories: () => call('qq/radio/categories', {}, 'GET'),
    qqRadioTracks: (id) => call('qq/radio/tracks', { id }, 'GET'),
    /** 音频直链要走本机代理：vkey 会过期、CDN 有 referer 策略，也不该把凭证写进 DOM */
    qqAudio: (u) => proxyAudioUrl('api/qq/audio', u),

    /* ------------------------------------------------------------------
       其它音源（酷狗 / 汽水 / 波点 / Spotify）
       每个平台一个边车，形状统一是 { code, ... }，所以前端这边也做成一套：
       用 track.source 决定打哪个前缀，调用方（player.js / 搜索）不用 if/else。
       ------------------------------------------------------------------ */
    srcHealth: (src) => callSoft(`${src}/health`),
    srcStatus: (src) => callSoft(`${src}/status`),
    srcQrKey: (src) => callSoft(`${src}/login/qr/key`),
    srcQrCreate: (src, key) => callSoft(`${src}/login/qr/create`, { key }),
    srcQrCheck: (src, key) => callSoft(`${src}/login/qr/check`, { key }),
    srcLogout: (src) => callSoft(`${src}/logout`),
    /** Spotify 骨架：PKCE 授权地址（没有 client_id 时服务端会回 { code:400, error } ） */
    srcLoginUrl: (src) => callSoft(`${src}/login/url`),

    /* 搜索只走平台接口：落雪（LX）不参与搜索。LX 只作播放兜底（见 lxSongUrl）。
       搜索入口（app.js searchOne / m.js searchTracks）只传 SEARCH_SOURCES /
       PLATS 里的 5 个平台 id；这里再拦一道，免得将来有人把 'lx' 传进来。 */
    srcSearch: (src, s, limit = 20) => {
      if (src === 'lx') return Promise.reject(new Error('落雪不参与搜索'));
      return call(`${src}/search`, { s, limit }, 'GET');
    },

    /* 铺色态的内容（2026-11-06）：各平台能给的推荐 / 歌单都收在这里。
       形状和网易云那套对齐：tracks 是 { id,source,name,artists,... }，playlists 是 { id,name,cover,... } */
    qishuiFeed: (limit = 20, mode = '') => call('qishui/feed', mode ? { limit, mode } : { limit }, 'GET'),
    qishuiFeedModes: () => call('qishui/feed/modes', {}, 'GET'),
    qishuiUserPlaylists: (limit = 100) => call('qishui/user/playlists', { limit }, 'GET'),
    qishuiLikedIds: () => call('qishui/liked_songs', {}, 'GET'),
    qishuiPlaylistTracks: (id, limit = 50) => call('qishui/playlist/tracks', { id, limit }, 'GET'),
    /* 波点用 callSoft：边车起不来 / 老主服务还没重启时，服务端会回 502/404 +
       真实原因；这里不抛 HTTP 错，界面才能把 reason 原样显示出来。 */
    bodianPlaylistTracks: (id, limit = 50, source = 0) => callSoft('bodian/playlist/tracks',
      source ? { id, limit, source } : { id, limit }),
    /** 波点：推荐歌单 / 潮趣日推 / 私人 FM（匿名可用） */
    bodianRecommendations: () => callSoft('bodian/recommendations'),
    bodianDaily: (index = 0) => callSoft('bodian/ai/playlist', { index }),
    bodianPersonalFm: () => callSoft('bodian/personal/fm'),
    bodianUserPlaylists: () => callSoft('bodian/user/playlists'),
    bodianLikedSongs: () => callSoft('bodian/liked_songs'),
    kugouTopSongs: (type = 1) => call('kugou/top/songs', { type }, 'GET'),
    kugouDaily: () => call('kugou/everyday/recommend', {}, 'GET'),
    kugouTopPlaylists: (limit = 12) => call('kugou/top/playlists', { limit }, 'GET'),
    kugouPersonalFm: () => call('kugou/personal/fm', {}, 'GET'),
    /** 酷狗电台：频道目录匿名可读，按 fmid 取歌也匿名 */
    kugouRadioStations: () => call('kugou/fm/class', {}, 'GET'),
    kugouRadioTracks: (fmid, limit = 30) => call('kugou/fm/songs', { fmid, limit }, 'GET'),
    kugouPlaylistTracks: (id, limit = 100) => call('kugou/playlist/tracks', { id, limit }, 'GET'),
    kugouUserPlaylists: () => call('kugou/user/playlists', {}, 'GET'),

    /* 酷我（services/kuwo-api/）：内容接口用 callSoft，边车没起来 / 主服务没重启时
       能把 { code:404|502, error } 原样显示出来，而不是一句 "HTTP 502"。 */
    kuwoRanks: () => callSoft('kuwo/rank/list'),
    kuwoRankTracks: (id, limit = 50) => callSoft('kuwo/rank/tracks', { id, limit }),
    kuwoRecommendPlaylists: (limit = 12) => callSoft('kuwo/recommend/playlists', { limit }),
    kuwoPlaylistTracks: (id, limit = 100) => callSoft('kuwo/playlist/tracks', { id, limit }),
    kuwoDaily: () => callSoft('kuwo/daily'),
    /** 酷我只有 Cookie 登录（没有扫码）：整段 Cookie 走 POST body */
    kuwoCookieLogin: (cookie) => postSoft('kuwo/login/cookie', { cookie }),

    /* 网易云电台：透明转发已有路由，不需要改主服务 */
    neteaseDjRecommend: (limit = 8) => call('netease/dj/recommend', { limit }, 'GET'),
    neteaseDjPrograms: (rid, limit = 50) => call('netease/dj/program', { rid, limit }, 'GET'),

    /**
     * 播放直链。每个平台的必填参数不一样，差异只留在这里：
     *   酷狗认 hash + album_id + album_audio_id；汽水/波点是数字 id；Spotify 本期没有音频。
     * 统一返回 { url, preview, reason, error, clipStartMs?, previewRange? }
     */
    srcSongUrl: (track) => {
      const src = track.source;
      if (src === 'kugou') {
        return call('kugou/song/url', {
          hash: track.hash || track.id,
          albumId: track.albumIdNum || track.albumId || 0,
          albumAudioId: track.albumAudioId || 0,
        }, 'GET');
      }
      if (src === 'spotify') return call('spotify/song/url', { id: track.id }, 'GET');
      return call(`${src}/song/url`, { id: track.id }, 'GET');
    },

    srcLyric: (track) => {
      const src = track.source;
      /* LRCLIB 兜底要的元数据（第 11 轮）：服务端官方歌词回空时用这些查。
         artists 可能是数组（[{name}] 或 ['a','b']）也可能是拼好的字符串，
         照 lxSongUrl 的写法两边都接。duration 各平台归一化后都是毫秒，
         LRCLIB 要整秒。酷狗原来只传 hash + s，duration 一直是 0，
         现在顺带补上，它的歌词搜索也能用上。 */
      const meta = {
        s: track.name || '',
        artist: Array.isArray(track.artists)
          ? track.artists.map((a) => a.name || a).join(' / ')
          : (track.artists || ''),
        album: track.album || '',
        duration: Math.round((track.duration || 0) / 1000),
      };
      if (src === 'kugou') return call('kugou/lyric', { hash: track.hash || track.id, ...meta }, 'GET');
      if (src === 'spotify') return call('spotify/lyric', { id: track.id, ...meta }, 'GET');
      return call(`${src}/lyric`, { id: track.id, ...meta }, 'GET');
    },

    /**
     * 落雪（LX）兜底：平台、云盘都拿不到地址时才走 /api/lx/song/url（用户自加的自定义源），
     * quality 不传时服务端默认从 master 向下回退，返回的 quality 是实际档位。
     * undefined 的字段不进查询串，别让服务端收到 mid=undefined。
     */
    lxSongUrl: (track, quality) => {
      const params = { source: track.source || 'netease', quality: quality || 'master' };
      if (track.id != null) params.id = track.id;
      if (track.mid) params.mid = track.mid;
      if (track.hash) params.hash = track.hash;
      if (track.name) params.name = track.name;
      if (track.artists && track.artists.length) {
        // artists 可能是数组（[{name}] 或 ['a','b']），也可能是 app.js 拼好的
        // 字符串（'a / b'）：字符串没有 .map，直接调用会抛异常导致整个 LX 腿跳过。
        params.artists = Array.isArray(track.artists)
          ? track.artists.map((a) => a.name || a).join('/')
          : String(track.artists);
      }
      return call('lx/song/url', params, 'GET');
    },

    /** LX 解析出的音频直链走 /api/lx/audio 代理（白名单见服务端 AUDIO_HOSTS.lx） */
    lxAudio: (u) => proxyAudioUrl('api/lx/audio', u),

    /* ------------------------------------------------------------------
       自定义源管理（设置 → 自定义源管理；服务端见 LXSources.swift）
       列表 / URL 导入（GitHub 链接服务端自动转 raw）/ 本地文件导入 /
       删除 / 启用开关 / 刷新（仅 URL 源）/ 旧源补绑 URL / 自动切换开关。
       导入失败服务端回 200 + { code:400, error }（如「不是有效的落雪音源脚本」），
       调用方读 error 显示，不要只看 HTTP 状态。
       ------------------------------------------------------------------ */
    lxSourcesList: () => call('lx/sources', {}, 'GET'),
    lxSourcesImportUrl: (url) => call('lx/sources/import-url', { url }),
    lxSourcesImportFile: (name, content) => call('lx/sources/import-file', { name, content }),
    lxSourcesDelete: (id) => call('lx/sources/delete', { id }),
    lxSourcesToggle: (id, enabled) => call('lx/sources/toggle', { id, enabled }),
    lxSourcesRefresh: (id) => call('lx/sources/refresh', { id }),
    lxSourcesBindUrl: (id, url) => call('lx/sources/bind-url', { id, url }),
    /** 不传参 = 读当前开关；传 true/false = 写开关 */
    lxSourcesAutoSwitch: (enabled) => enabled === undefined
      ? call('lx/sources/auto-switch', {}, 'GET')
      : call('lx/sources/auto-switch', { enabled }),

    /** 所有非网易云音源的音频都走各自代理（服务端按源做域名白名单 + 转发 Range） */
    srcAudio: (src, u) => proxyAudioUrl(`api/${src}/audio`, u),

    /* ------------------------------------------------------------------
       本地音乐（文件 App 导入；只在 iOS 壳里有，原生桥 liziNative 负责弹选择器）
       list 回 { code:0, tracks:[{id, source:'local', name, artists:[], duration, size}] }，
       duration 是毫秒，和其它音源的 track.duration 单位一致。
       ------------------------------------------------------------------ */
    localList: () => call('local/list', {}, 'GET'),
    localFile: (id) => `/api/local/file?id=${encodeURIComponent(id)}`,
    localDelete: (id) => call('local/delete', { id }),
  };
})();
