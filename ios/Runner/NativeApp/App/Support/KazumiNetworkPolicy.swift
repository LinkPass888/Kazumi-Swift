//
//  KazumiNetworkPolicy.swift
//  Kazumi
//
//  网络设置里那几项要在「建 URLSession」的那一刻起作用，而各个接口的 session
//  都是静态的、建得比界面早，所以照 BangumiAcceleration 的做法放一份进程内状态：
//  SettingsStore 写入时更新它，各 session 建配置时读它。
//
//  手动代理也在这里（LP 5342 起照 main 接）：main 那边是 `ProxyManager.applyProxy()`
//  重置 Dio 工厂 + 图片缓存管理器，同一个 `proxyUrl` 同时给 mpv、Dio 和图片缓存用。
//  iOS 上没有「全局代理」这种东西，`connectionProxyDictionary` 是每份 URLSession
//  配置自己的，所以做成一个建配置时调一下的方法，替掉 main 那边的「重置工厂」。
//
//  代理变了还要把已经建好的 session 作废重建（`ProxyAwareURLSession`），
//  不然设完代理得重启才生效，跟播放器那一路当场生效对不上（Fuck 5352）。
//

import Foundation
import os

/// 图片加速方式（对应原版 `ImageAcceleration`，经 wsrv.nl 那套改写）。
enum ImageAcceleration: String, Sendable {
    case direct
    case mirror
}

/// 进程内共享的网络策略。
enum KazumiNetworkPolicy {
    private struct State: Sendable {
        var imageAcceleration: ImageAcceleration = .direct
        /// 手动代理地址，一整串（`127.0.0.1:6152`）；空串表示不代理。
        var proxyURL: String = ""
        /// 代理地址变过几次。`ProxyAwareURLSession` 凭它认出自己是不是过期了。
        var proxyGeneration: Int = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// 图片加速方式。
    static var imageAcceleration: ImageAcceleration {
        get { state.withLock { $0.imageAcceleration } }
        set { state.withLock { $0.imageAcceleration = newValue } }
    }

    /// 手动代理地址（`proxyUrl`）；空串表示不代理。
    static var proxyURL: String {
        get { state.withLock { $0.proxyURL } }
        set {
            state.withLock {
                guard $0.proxyURL != newValue else { return }
                $0.proxyURL = newValue
                $0.proxyGeneration += 1
            }
        }
    }

    /// 代理地址变过几次；没变过就是 0。
    static var proxyGeneration: Int {
        state.withLock { $0.proxyGeneration }
    }

    /// 替代 `URLSession.shared` 的那一份：shared 的配置改不了，也就永远不走我们
    /// 填的代理。各调用点自己设 `request.timeoutInterval`，所以这里用默认配置。
    static let requestSession = ProxyAwareURLSession {
        let configuration = URLSessionConfiguration.default
        KazumiNetworkPolicy.applyProxy(to: configuration)
        return configuration
    }

    /// 把当前手动代理套到一份 session 配置上。
    ///
    /// 没开代理、或者地址写错了（`ProxyURL.parse` 返回 nil）就什么都不做，
    /// 交给系统代理——跟 main 的 `findProxy` 为空时一样。
    static func applyProxy(to configuration: URLSessionConfiguration) {
        guard !proxyURL.isEmpty, let parsed = ProxyURL.parse(proxyURL) else {
            configuration.connectionProxyDictionary = nil
            return
        }
        configuration.connectionProxyDictionary = proxyDictionary(host: parsed.host, port: parsed.port)
    }

    /// `connectionProxyDictionary` 里要给的那几项。
    ///
    /// **HTTP 和 HTTPS 两组键都要给。** CFNetwork 对 `https://` 的请求看的是
    /// `HTTPSProxy` 那组，只写 `HTTPProxy` 的话 https 照样直连——而这里几乎
    /// 所有请求都是 https，漏了就等于没代理。这是模拟器上试出来的：拿一个
    /// 根本没在听的 `127.0.0.1:1` 去「保存并测试」，居然报成功，因为请求
    /// 直连 google 拿到了响应。main 的 `findProxy` 不分协议，两组都给才是等价翻译。
    ///
    /// 键名用的是 `kCFNetworkProxies*` 那几个常量的字符串值（`HTTPEnable` /
    /// `HTTPProxy` / `HTTPPort` / `HTTPSEnable` / `HTTPSProxy` / `HTTPSPort`）：
    /// 直接写常量名在这份代码里不一定拿得到，而 URLSession 认的就是这几个字符串。
    static func proxyDictionary(host: String, port: Int) -> [AnyHashable: Any] {
        [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
    }
}

/// 一份「代理变了就重建」的 URLSession。
///
/// `URLSession` 的配置建好就不能改，所以设代理这件事只能在**建**的时候生效。
/// main 靠 `ProxyManager.applyProxy()` 重置 Dio 工厂绕开这点；iOS 这边让各接口
/// 把 session 换成这个盒子，代理一改就重建一份新的（配置在重建那一刻读，
/// 自然带上当时的代理），于是和播放器那一路一样是当场生效。
final class ProxyAwareURLSession: @unchecked Sendable {
    private struct State: Sendable {
        var generation = -1
        var session: URLSession?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let configuration: @Sendable () -> URLSessionConfiguration

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.configuration = configuration
    }

    /// 当前代理下该用的那份 session；代理变过就重建。
    var session: URLSession {
        let generation = KazumiNetworkPolicy.proxyGeneration
        return lock.withLock { state in
            if let session = state.session, state.generation == generation { return session }
            let session = URLSession(configuration: configuration())
            state.session = session
            state.generation = generation
            return session
        }
    }
}

/// Bangumi 图片镜像改写（对应原版 `BangumiImageUrlRewriter`）：
/// lain.bgm.tv 和 api.bgm.tv 的 subjects/characters/persons 图片交给 wsrv.nl 转一层。
enum BangumiImageRewriter {
    private static let apiImageKinds: Set<String> = ["subjects", "characters", "persons"]

    static func isBangumiImage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if url.host == "lain.bgm.tv" { return true }
        return isAPIImage(url)
    }

    private static func isAPIImage(_ url: URL) -> Bool {
        guard url.host == "api.bgm.tv" else { return false }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 4, segments[0] == "v0", segments[3] == "image" else { return false }
        guard apiImageKinds.contains(segments[1]) else { return false }
        guard let id = Int(segments[2]), id > 0 else { return false }
        return true
    }

    /// 当前设置下这张图片该用哪个地址：直连原样返回，镜像走 wsrv.nl。
    static func rewritten(_ url: URL) -> URL {
        guard KazumiNetworkPolicy.imageAcceleration == .mirror, isBangumiImage(url) else {
            return url
        }
        let source = url.host.map { host in
            host + url.path + (url.query.map { "?\($0)" } ?? "")
        } ?? ""
        var components = URLComponents()
        components.scheme = "https"
        components.host = "wsrv.nl"
        components.path = "/"
        var items = [URLQueryItem(name: "url", value: source)]
        // 动图要 wsrv 别压缩帧数（原版同一个参数）。
        if url.path.lowercased().hasSuffix(".gif") {
            items.append(URLQueryItem(name: "n", value: "-1"))
        }
        components.queryItems = items
        return components.url ?? url
    }
}
