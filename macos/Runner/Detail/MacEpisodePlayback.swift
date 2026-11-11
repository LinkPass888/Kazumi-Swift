//
//  MacEpisodePlayback.swift
//  Kazumi (macOS)
//
//  「线路 + 第几集」→ 一条起播请求。详情页和播放器里的选集面板共用这一份，
//  免得两处各写一遍地址归一化和请求头拼装。
//
//  只有直链线路能成：网页地址要在 VideoSourceWebView 里捞 m3u8/mp4，那条路还没移植。
//

import Foundation

enum MacEpisodePlayback {
    /// 取不到可直接播放的地址时抛出，消息可直接上屏。
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func request(
        plugin: Plugin,
        animeName: String,
        roads: [Road],
        roadIndex: Int,
        episodeIndex: Int
    ) throws -> MacPlayRequest {
        guard roads.indices.contains(roadIndex) else {
            throw Failure(message: "线路列表里没有这一条。")
        }
        let road = roads[roadIndex]
        guard road.identifier.indices.contains(episodeIndex) else {
            throw Failure(message: "这一集没有地址（规则的线路数据不完整）。")
        }
        let raw = road.identifier[episodeIndex]
        let absolute = EpisodeURL.normalize(baseUrl: plugin.baseUrl, raw: raw)
        let decoded = MediaUtility.decodeVideoSource(absolute)
        guard MediaUtility.isMediaURL(decoded), let url = URL(string: decoded) else {
            throw Failure(
                message: "这条线路给的是网页地址，要在网页里解析出地址才能播——那套 WebView 还没移植到 macOS。换一条直链线路试试。"
            )
        }
        let headers = plugin.buildHttpHeaders()
        let cookie = PluginCookieStore.shared.cookieHeader(pluginName: plugin.name, url: decoded)
        let episodeName = road.data.indices.contains(episodeIndex) ? road.data[episodeIndex] : ""
        let title = episodeName.isEmpty ? animeName : "\(animeName) · \(episodeName)"
        return MacPlayRequest(
            url: url,
            title: title,
            referer: headers["referer"],
            userAgent: PluginCookieStore.shared.userAgent(for: plugin.name) ?? headers["user-agent"],
            cookie: cookie.isEmpty ? nil : cookie,
            playlist: MacPlaylist(
                pluginName: plugin.name,
                animeName: animeName,
                roads: roads,
                roadIndex: roadIndex,
                episodeIndex: episodeIndex
            )
        )
    }
}