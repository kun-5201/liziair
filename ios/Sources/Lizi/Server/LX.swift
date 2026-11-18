import Foundation

/// 落雪（LX）音源：只剩音源名映射与档位工具（自定义源注册表、脚本实例共用）。
/// 内置解析（oiapi/s0o1 等）已删——用户 2026-11-18 要求删掉「落雪音源」，
/// 取歌只走自定义源，拿不到就由 player.js 走平台接口备用。

enum LXResolver {
    /// liziair 的 source 名 -> LX 的 source 名。波点 / Spotify 没有 LX 解析
    /// （新音源也不支持 bd）；汽水（qs）第 11 轮第 9 件接进来。
    static let sourceMap: [String: String] = [
        "netease": "wy", "qq": "tx", "kugou": "kg", "kuwo": "kw",
        // 汽水（qs）：第 11 轮第 8/9 件——新音源（聆澜音源赞助版 v9.0.1）上报 qs
        // 平台，取链实测通（320k）；App 之前把 qishui 拦在 LX 门外（""），
        // 平台拿不到地址时直接走演示音。波点 / Spotify 没有 LX 解析（脚本也不支持 bd）。
        "qishui": "qs", "bodian": "", "spotify": "",
    ]

    static func normalizeQuality(_ q: String?) -> String {
        guard let q, !q.isEmpty else { return "master" }
        let s = q.lowercased().replacingOccurrences(of: "[\\s_-]", with: "", options: .regularExpression)
        let map: [String: String] = [
            "jymaster": "master", "master": "master",
            "atmos": "atmos", "dolbyatmos": "atmos", "spatial": "atmos", "surround": "atmos",
            "jyeffect": "atmos", "hires": "hires", "flac24bit": "flac24bit", "24bit": "flac24bit",
            "flac": "flac", "lossless": "flac", "320k": "320k", "320": "320k", "exhigh": "320k",
            "128k": "128k", "128": "128k", "standard": "128k", "higher": "320k",
        ]
        return map[s] ?? "master"
    }
}
