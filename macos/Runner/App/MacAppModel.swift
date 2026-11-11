//
//  MacAppModel.swift
//  Kazumi (macOS)
//
//  macOS 版的一份共享状态：规则控制器 + 一次「要播这个」的请求。
//
//  为什么需要它：搜索页、详情页、播放器分属三栏，播放请求要从详情页递到播放器，
//  而 macOS 这版没有 iOS 那套 AppEnvironment（那个类带着下载中心、追番同步等
//  一堆 iOS 业务）。这里只装 macOS 真正用得上的两样。
//

import Foundation
import Observation

/// 一次起播请求：地址 + 该带上的请求头（规则的 UA / referer / 登录 cookie）。
struct MacPlayRequest: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var title: String
    var referer: String?
    var userAgent: String?
    var cookie: String?
}

@MainActor
@Observable
final class MacAppModel {
    /// 已安装的规则：读盘、安装、删除、更新都在这个控制器里。
    let plugins = PluginsController()

    /// 待播的这一条。播放页看到它变了就起播，播完自己清掉。
    var playRequest: MacPlayRequest?

    init() {
        plugins.load()
    }

    /// 让播放页放这一段。根视图监听到变化会把侧边栏切到「播放器」。
    func play(_ request: MacPlayRequest) {
        playRequest = request
    }
}