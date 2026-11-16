/**
 * 落雪（LX）音源解析 —— liziair 内置版
 *
 * 作用：主音源（网易云 / QQ / 酷狗 / 酷我）拿不到播放地址时（VIP / 无版权，
 * 上游回 url:null），走 LX 第三方解析兜底，而不是直接放 40 秒演示音轨。
 *
 * 来源：复用已交付的 lx-music-api（~/workspace/lx-music-api/server.js）
 * 的解析逻辑，改成 ESM 模块供 server.mjs import。协议兼容
 * lx-music-api-server v3（GET /lxmusicv3/url/:source/:songId/:quality），
 * 但这里是**内置解析**，不需要再起一个独立的 LX 服务。
 *
 * 音质档位（从高到低），请求某档拿不到时自动向下回退，返回实际拿到的档位：
 *   master（超清母带）> atmos（杜比全景声）> hires（Hi-Res）
 *   > flac24bit（FLAC 24-bit）> flac（无损）> 320k（极高）> 128k（标准）
 * 调用方永远按返回的 quality 显示实际音质，不拿请求的档位冒充。
 *
 * 私有 LX 音源脚本（Ciallo / 溯音 / upload.js）不在这里、不打进包。
 * 想用自己的 LX 服务（含自定义音源脚本）时，设环境变量 LX_API_URL
 * 指到你自己的 lx-music-api-server，server.mjs 会优先代理过去。
 *
 * 环境变量：
 *   LX_API_URL   自建 lx-music-api-server 地址，如 http://127.0.0.1:3000（可选）
 *   LX_API_KEY   该服务的 X-Request-Key（可选）
 *   LX_OIAPI_KEY oiapi.net 的 key（QQ / 酷我用），默认用内置的那个
 */

const OIAPI_KEY = process.env.LX_OIAPI_KEY || 'oiapi-ef6133b7-ac2f-dc7d-878c-d3e207a82575'

export const LX_API_URL = (process.env.LX_API_URL || '').replace(/\/$/, '')
export const LX_API_KEY = process.env.LX_API_KEY || ''

/* liziair 的 source 名 -> LX 的 source 名。汽水 / 波点 / Spotify 没有 LX 解析，返回 null。 */
export const LX_SOURCE_MAP = {
  netease: 'wy',
  qq: 'tx',
  kugou: 'kg',
  kuwo: 'kw',
  qishui: null,
  bodian: null,
  spotify: null,
}

export const TIERS = ['master', 'atmos', 'hires', 'flac24bit', 'flac', '320k', '128k']

export const TIER_NAMES = {
  master: '超清母带 Master',
  atmos: '杜比全景声 Dolby Atmos',
  hires: 'Hi-Res',
  flac24bit: 'Hi-Res / FLAC 24-bit',
  flac: '无损 FLAC',
  '320k': '极高 320 kbps',
  '128k': '标准 128 kbps',
}

export function normalizeQuality(q) {
  if (!q) return 'master'
  const s = String(q).toLowerCase().replace(/[\s_-]/g, '')
  const map = {
    jymaster: 'master', master: 'master',
    atmos: 'atmos', dolbyatmos: 'atmos', spatial: 'atmos', surround: 'atmos',
    jyeffect: 'atmos', hires: 'hires', flac24bit: 'flac24bit', '24bit': 'flac24bit',
    flac: 'flac', lossless: 'flac', '320k': '320k', '320': '320k', exhigh: '320k',
    '128k': '128k', '128': '128k', standard: '128k', higher: '320k',
  }
  return map[s] || 'master'
}

function tiersFrom(quality) {
  const i = TIERS.indexOf(normalizeQuality(quality))
  return TIERS.slice(i < 0 ? 0 : i)
}

async function fetchJson(url, { timeout = 8000, headers = {} } = {}) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeout)
  try {
    const resp = await fetch(url, { headers, signal: ctrl.signal })
    const text = await resp.text()
    try { return JSON.parse(text) } catch { return text }
  } finally {
    clearTimeout(t)
  }
}

function isHttpUrl(u) {
  return typeof u === 'string' && /^https?:\/\//i.test(u)
}

/* --- QQ 音乐 (tx) --- */
const QQ_BR = { master: 1, atmos: 2, hires: 3, flac24bit: 3, flac: 4, '320k': 5, '128k': 7 }

async function resolveTx(songId, tier) {
  const br = QQ_BR[tier] ?? 7
  const params = new URLSearchParams({ key: OIAPI_KEY, type: 'json', br: String(br), n: '1' })
  if (/^\d+$/.test(songId)) params.set('songid', songId)
  else params.set('mid', songId)
  const data = await fetchJson(`https://oiapi.net/api/QQ_Music?${params}`)
  const url = data?.music || data?.url
  if (isHttpUrl(url)) return url
  if (typeof data?.message === 'string') {
    const m = data.message.match(/音频链接：(.+?)(?:\n|$)/)
    if (m && isHttpUrl(m[1].trim())) return m[1].trim()
  }
  throw new Error('QQ 未返回音频链接')
}

/* --- 网易云 (wy) --- */
const WY_YZ = { '128k': '1', '320k': '2', flac: '3', flac24bit: '4', hires: '5', atmos: '6', master: '7' }

async function resolveWy(songId, tier) {
  try {
    const yz = WY_YZ[tier] || '1'
    const data = await fetchJson(`https://www.s0o1.com/API/wyy_music?id=${encodeURIComponent(songId)}&yz=${yz}`, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
    })
    if (data?.status === 200 && data?.success && isHttpUrl(data?.data?.url)) return data.data.url
    throw new Error(data?.message || 's0o1 未返回音频链接')
  } catch (e) {
    let backupErr = '备用接口未返回音频链接'
    try {
      const data = await fetchJson(`https://oiapi.net/api/Music_163?id=${encodeURIComponent(songId)}`)
      if (data?.code === 0 && data?.data) {
        /* oiapi 的 data 有三种形状：数组、单个对象、{ items:[...] }，三种都认 */
        const d = data.data
        const song = Array.isArray(d) ? d[0] : (d.items?.[0] || d)
        /* 备用接口不分档位，给的就是 mp3（实测 128k 级别）：如实报 128k，
           不拿正在试的 master 档位冒充。 */
        if (isHttpUrl(song?.url)) return { url: song.url, quality: '128k' }
      }
    } catch (be) { backupErr = `备用接口请求失败: ${be.message}` }
    throw new Error(`网易解析失败: 主接口 ${e.message}；${backupErr}`)
  }
}

/* --- 酷我 (kw)：oiapi 按关键词搜，songId 是歌名（+歌手）或纯数字 rid --- */
const KW_BR = { master: 1, atmos: 1, hires: 1, flac24bit: 1, flac: 1, '320k': 2, '128k': 3 }

async function resolveKw(songId, tier) {
  const br = KW_BR[tier] ?? 3
  const params = new URLSearchParams({ msg: songId, n: '1', br: String(br) })
  const data = await fetchJson(`https://oiapi.net/api/Kuwo?${params}`)
  if (isHttpUrl(data?.data?.url)) return data.data.url
  if (typeof data?.message === 'string') {
    const m = data.message.match(/音乐链接：(\S+)/)
    if (m && isHttpUrl(m[1])) return m[1]
  }
  throw new Error('酷我未返回音频链接')
}

/* --- 咪咕 (mg)：liziair 目前没有咪咕曲目，留着给以后 --- */
async function resolveMg(songId) {
  const params = new URLSearchParams({ gm: songId, n: '1', num: '1', type: 'json' })
  const data = await fetchJson(`https://api.xcvts.cn/api/music/migu?${params}`)
  if (data?.code === 200 && isHttpUrl(data?.music_url)) return data.music_url
  throw new Error('咪咕未返回音频链接')
}

/* --- 酷狗 (kg)：hash 是 32 位十六进制就直接用，否则按关键词搜第一首 --- */
async function resolveKg(songId, tier) {
  let hash = /^[0-9a-fA-F]{32}$/.test(songId) ? songId : null
  if (!hash) {
    const search = await fetchJson(
      `http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=${encodeURIComponent(songId)}&page=1&pagesize=1&showtype=1`
    )
    hash = search?.data?.info?.[0]?.hash
    if (!hash) throw new Error('酷狗未搜到歌曲')
  }
  const info = await fetchJson(
    `http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=${hash}&from=mkugou`
  )
  const url = info?.url || info?.data?.url
  if (isHttpUrl(url)) return url
  throw new Error('酷狗未返回音频链接')
}

const RESOLVERS = { tx: resolveTx, wy: resolveWy, kw: resolveKw, mg: resolveMg, kg: resolveKg }
export const SUPPORTED_LX_SOURCES = Object.keys(RESOLVERS)

/**
 * 统一入口：按档位从高到低回退，返回 { url, quality }。
 * quality 永远是实际拿到的档位。
 */
export async function resolveMusicUrl(source, songId, quality) {
  const resolve = RESOLVERS[source]
  if (!resolve) throw Object.assign(new Error(`不支持的音源: ${source}`), { code: 6 })
  if (!songId) throw Object.assign(new Error('缺少歌曲 ID'), { code: 6 })
  const errors = []
  for (const tier of tiersFrom(quality)) {
    try {
      /* 解析器可以只回地址字符串（档位就是正在试的这一档），也可以回
         { url, quality }（备用接口不分档位时如实报实际档位）。 */
      const r = await resolve(songId, tier)
      const url = typeof r === 'string' ? r : r.url
      const actual = typeof r === 'object' && r.quality ? r.quality : tier
      return { url, quality: actual }
    } catch (e) {
      errors.push(`${TIER_NAMES[tier]}: ${e.message}`)
    }
  }
  const err = new Error(`全部档位均失败（${errors.join('；')}）`)
  err.code = 2
  throw err
}

/**
 * 走外部自建 LX 服务（LX_API_URL 已设）：直接调它的 v3 协议，
 * GET {LX_API_URL}/lxmusicv3/url/:source/:songId/:quality。
 * 你的 Ciallo / 溯音等自定义音源脚本跑在那台服务上，不进这个仓库。
 */
export async function resolveViaExternalServer(source, songId, quality) {
  const q = normalizeQuality(quality)
  const headers = {}
  if (LX_API_KEY) headers['X-Request-Key'] = LX_API_KEY
  const data = await fetchJson(
    `${LX_API_URL}/lxmusicv3/url/${encodeURIComponent(source)}/${encodeURIComponent(songId)}/${encodeURIComponent(q)}`,
    { headers, timeout: 15000 }
  )
  if (data?.code === 0 && isHttpUrl(data?.data)) return { url: data.data, quality: data.quality || q }
  throw new Error(data?.msg || data?.message || '外部 LX 服务未返回音频链接')
}
