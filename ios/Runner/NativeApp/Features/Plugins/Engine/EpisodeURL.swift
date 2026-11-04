//
//  EpisodeURL.swift
//  Kazumi
//
//  1:1 翻译 lib/utils/episode_url.dart。
//
//  把规则抓到的原始 href 归一化为稳定的绝对 URL，使其可以作为"同一集"的身份主键
//  （播放 / 下载 / 历史回填共用）。规则：
//  - 去首尾空白，空输入返回空串；
//  - 相对路径基于 baseUrl 补全；
//  - 与 baseUrl 同站（同 host、同显式端口）时协议统一到 baseUrl 的协议；
//  - 去掉 path 尾部多余斜杠（根路径保留）；
//  - 去掉空 query / 空 fragment；幂等。
//

import Foundation

enum EpisodeURL {
    static func normalize(baseUrl: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let base = parse(baseUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        let hasValidBase = base != nil && !(base?.scheme ?? "").isEmpty && !(base?.host ?? "").isEmpty

        var resolved: ResolvedURL?
        if let absolute = parse(trimmed), !absolute.scheme.isEmpty, !absolute.host.isEmpty {
            resolved = absolute
        } else if hasValidBase, let base {
            resolved = resolve(trimmed, against: base)
        }

        guard var output = resolved, !output.host.isEmpty else { return trimmed }

        // 同站 URL 的协议对齐到 baseUrl，避免 http/https 混用产生两个身份。
        if let base, hasValidBase, isHttpScheme(base.scheme), isHttpScheme(output.scheme),
           output.scheme != base.scheme, output.host == base.host,
           output.hasPort == base.hasPort,
           (!output.hasPort || output.port == base.port) {
            output.scheme = base.scheme
        }

        // 去除尾部斜杠，根路径保留。
        while output.path.count > 1 && output.path.hasSuffix("/") {
            output.path.removeLast()
        }
        if output.query.isEmpty { output.query = "" }
        if output.fragment.isEmpty { output.fragment = "" }

        return output.absoluteString
    }

    private static func isHttpScheme(_ scheme: String) -> Bool {
        scheme == "http" || scheme == "https"
    }

    /// 等价于 Dart 的 Uri.tryParse：scheme / host 为空时视为"无法解析为绝对 URL"。
    private struct ResolvedURL {
        var scheme: String
        var host: String
        var port: Int?
        var user: String?
        var password: String?
        var path: String
        var query: String
        var fragment: String

        var hasPort: Bool { port != nil }

        var absoluteString: String {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            if let port { components.port = port }
            components.user = user
            components.password = password
            components.percentEncodedPath = path
            if !query.isEmpty { components.percentEncodedQuery = query }
            if !fragment.isEmpty { components.percentEncodedFragment = fragment }
            return components.string ?? ""
        }
    }

    private static func parse(_ string: String) -> ResolvedURL? {
        guard let components = URLComponents(string: string) else { return nil }
        let host = components.host ?? ""
        return ResolvedURL(
            scheme: components.scheme ?? "",
            host: host,
            port: components.port,
            user: components.user,
            password: components.password,
            path: components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            query: components.percentEncodedQuery ?? "",
            fragment: components.percentEncodedFragment ?? ""
        )
    }

    /// 按 RFC 3986 相对引用规则补全（等价于 Dart 的 Uri.resolve）。
    private static func resolve(_ reference: String, against base: ResolvedURL) -> ResolvedURL? {
        // 与 Dart 的 Uri.resolve 对齐：先把 base 的 authority + path 拼成字符串，
        // 再按 RFC 3986 处理相对引用（去除 ./ 与 ../ 段）。
        let baseString = base.absoluteString
        guard let rawReference = URL(string: reference) else { return nil }
        guard let resolved = URL(string: rawReference.relativeString, relativeTo: URL(string: baseString))?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            return nil
        }
        let host = components.host ?? ""
        guard !host.isEmpty else { return nil }
        return ResolvedURL(
            scheme: components.scheme ?? base.scheme,
            host: host,
            port: components.port,
            user: components.user,
            password: components.password,
            path: components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            query: components.percentEncodedQuery ?? "",
            fragment: components.percentEncodedFragment ?? ""
        )
    }
}
