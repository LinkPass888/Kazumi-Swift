//
//  PlayerErrorMessage.swift
//  Kazumi
//
//  内核报错时给用户看的话（LP 4810 后一句）。
//
//  画面上那行内核日志已经拿掉了，所以「为什么放不了」不能只留在日志里——
//  内核给的是英文（`Failed to open ...`、`Could not resolve host` 这种），
//  这里按关键词归成几句人话，原文照旧进 KazumiLogBuffer 给排查用。
//

import Foundation

enum PlayerErrorMessage {
    /// 把内核那句英文（外加它最后一条 error 级日志）翻成一句话。
    ///
    /// 认不出来就落到最后那条兜底：宁可说得含糊，也别把英文原文甩给用户。
    static func friendly(core: String?, detail: String? = nil) -> String {
        let raw = [core, detail]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        // 网络层：解析不了 / 连不上 / 超时。这三种最多，也最该说清楚。
        if raw.contains("could not resolve host")
            || raw.contains("name or service not known")
            || raw.contains("getaddrinfo")
            || raw.contains("resolve") {
            return String(localized: "连不上这个源的服务器（域名解析不了），可能是源挂了或者网络有问题")
        }
        if raw.contains("timed out") || raw.contains("timeout") {
            return String(localized: "连接超时了，源太慢或者网络断了")
        }
        if raw.contains("connection refused") || raw.contains("connection reset")
            || raw.contains("network is unreachable") || raw.contains("network unreachable") {
            return String(localized: "连不上这个源，网络断了或者源挂了")
        }
        // 源的地址失效：这是「换个源就好了」，要让用户知道该干什么。
        if raw.contains("404") || raw.contains("not found") {
            return String(localized: "这个源的播放地址已经失效了（404），换一个源试试")
        }
        if raw.contains("403") || raw.contains("forbidden")
            || raw.contains("401") || raw.contains("unauthorized") {
            return String(localized: "这个源拒绝了请求（可能要登录或者有防盗链），换一个源试试")
        }
        // 解码层：地址是好的，片子内核解不了。
        if raw.contains("could not open codec") || raw.contains("failed to initialize a decoder")
            || raw.contains("unrecognized file format") || raw.contains("unsupported")
            || raw.contains("no video or audio streams") {
            return String(localized: "这个格式内核解不了，换一个源或者换一集试试")
        }
        if raw.contains("failed to open") || raw.contains("loading failed") {
            return String(localized: "打不开这个播放地址，源可能已经失效了")
        }
        return String(localized: "播放失败了，换一个源或者重新加载试试")
    }
}
