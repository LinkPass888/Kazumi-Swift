//
//  ProxyURL.swift
//  Kazumi
//
//  代理地址的解析与拼装，照 main 的 `lib/services/network/proxy_utils.dart`
//  （`parseProxyUrl` / `getFormattedProxyUrl`）逐条搬过来：用户在设置里贴的是
//  一整串（`127.0.0.1:6152`，也可以带 `http://` 壳），存成 `proxyUrl`，
//  用的时候再拼回 `http://host:port` 交给播放内核和网络层。
//
//  LP 5342：照 main 做，内部怎么实现的我们就怎么实现。
//  LP 5345：本地代理就 `127.0.0.1`，不为 IPv6 那种写法留口子，解析照 main 原样
//  ——所以 `[::1]:7890` 这种写法判无效，跟 main 一致。
//

import Foundation

enum ProxyURL {
    /// 解析用户贴进来的那一串，返回主机和端口；空串或写错了返回 nil。
    ///
    /// 与 main 的 `parseProxyUrl` 一一对应：去掉首尾空白、剥掉 `http://` /
    /// `https://` 壳、按 `:` 切成恰好两段、主机非空、端口是整数。
    static func parse(_ text: String) -> (host: String, port: Int)? {
        var hostPort = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostPort.isEmpty else { return nil }

        for prefix in ["http://", "https://"] where hostPort.lowercased().hasPrefix(prefix) {
            hostPort.removeFirst(prefix.count)
        }

        // `omittingEmptySubsequences: false` 才对得上 Dart 的 `split(':')`：
        // `127.0.0.1:` 是两段（第二段空、解析端口失败），`a:b:c` 是三段（直接无效）。
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = Int(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    /// 拼回完整地址（`http://host:port`），给 mpv 的 `http-proxy` 用；解析不了就是 nil。
    static func formatted(_ text: String) -> String? {
        guard let parsed = parse(text) else { return nil }
        return "http://\(parsed.host):\(parsed.port)"
    }

    /// 只出 `host:port`，给设置里折着时右边那一句摘要用。
    /// 这个代理只支持 http，scheme 永远是同一个，写出来不携带信息（Colo 5368）。
    static func hostPort(_ text: String) -> String? {
        guard let parsed = parse(text) else { return nil }
        return "\(parsed.host):\(parsed.port)"
    }

    /// 拿这个代理去请求一次 `target`，通不通。
    ///
    /// 照 main 的 `saveAndTest`：用一份走代理的请求去 GET 测试地址，
    /// 成了才把 `proxyConfigured` 置真。iOS 这边对应的是给 session 配置写
    /// `connectionProxyDictionary`。
    ///
    /// 与 main 的一处出入：main 的 Dio 默认把非 2xx 也当失败，而这里只要
    /// HTTP 层有响应就算代理通了。测试地址默认是 `https://www.google.com`，
    /// 有些网络下它返回 403/451，那是「代理通了、目标不让进」，不是代理不通——
    /// 按 main 的口径会误报成「代理连接失败」并把开关关掉。
    /// 整个测试 10 秒封顶（Ato 6395）：黑洞地址（连得上、一直不回）不能让它拖到
    /// 系统自己的连接超时。
    static func test(proxy: String, target: String, timeout: TimeInterval = 10) async -> Bool {
        guard let parsed = parse(proxy), let url = URL(string: target) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // 只设 request 那层不够：黑洞地址会一直等下去，上限在那个「整个资源」的超时上。
        configuration.timeoutIntervalForResource = timeout
        // HTTP 和 HTTPS 两组键都要给，见 `KazumiNetworkPolicy.proxyDictionary`。
        configuration.connectionProxyDictionary = KazumiNetworkPolicy.proxyDictionary(
            host: parsed.host,
            port: parsed.port
        )
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            // 407 是代理自己把人拦了（要认证），那是「代理不通」而不是
            // 「代理通了、目标不让进」，别当成通过。
            if let http = response as? HTTPURLResponse, http.statusCode == 407 { return false }
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}
