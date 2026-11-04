//
//  PluginCookieStore.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/plugin_cookie_manager.dart。
//
//  为每条规则维护独立的内存 Cookie 集合，由验证码 WebView 写入 document.cookie，
//  规则请求执行器按需组装 Cookie 请求头。验证 Cookie 通常与 UA 绑定，
//  因此同时记录 WebView 的 UA 供后续请求对齐指纹。Cookie 只在本进程内有效，
//  重启后需要重新验证（与原实现一致）。
//

import Foundation

final class PluginCookieStore: @unchecked Sendable {
    static let shared = PluginCookieStore()

    struct Cookie: Sendable, Equatable, Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var isSecure: Bool? = nil
    }

    /// 落盘用：Cookie 与 UA 一起存，重启后登录态还在。
    private struct Snapshot: Codable {
        var jars: [String: [Cookie]]
        var userAgents: [String: String]
    }

    private static let storageKey = "kazumi.rule.cookies.v1"

    private let lock = NSLock()
    private var jars: [String: [Cookie]] = [:]
    private var userAgents: [String: String] = [:]

    private init() {
        restore()
    }

    /// 与 cookie_jar 的 saveFromResponse 对齐：同名同域的 Cookie 覆盖旧值。
    func saveFromWebView(pluginName: String, pageUrl: String, cookieString: String, userAgent: String?) {
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lock.lock()
                userAgents[pluginName] = trimmed
                lock.unlock()
            }
        }
        let trimmedCookies = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCookies.isEmpty { return }
        guard let host = URLComponents(string: pageUrl)?.host, !host.isEmpty else { return }

        let parsed = parse(trimmedCookies, host: host)
        if parsed.isEmpty { return }

        lock.lock()
        var jar = jars[pluginName] ?? []
        for cookie in parsed {
            if let index = jar.firstIndex(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) {
                jar[index] = cookie
            } else {
                jar.append(cookie)
            }
        }
        jars[pluginName] = jar
        lock.unlock()
        persist()

        KazumiLog.plugin.info(
            "[PluginCookieStore] Saved \(parsed.count) cookies for \(pluginName, privacy: .public)"
        )
    }

    /// 登录 WebView 用完把整份 Cookie 交给这里：网络层的 Cookie 对象带真实的 domain/path，
    /// 比从 document.cookie 里拼更准，登录态才认得出来（LP 5427）。
    func saveFromLoginWebView(
        pluginName: String,
        cookies: [Cookie],
        userAgent: String?
    ) {
        guard !cookies.isEmpty || userAgent != nil else { return }
        lock.lock()
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { userAgents[pluginName] = trimmed }
        }
        var jar = jars[pluginName] ?? []
        for raw in cookies {
            var cookie = raw
            cookie.domain = Self.normalizedDomain(cookie.domain)
            if let index = jar.firstIndex(where: {
                $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
            }) {
                jar[index] = cookie
            } else {
                jar.append(cookie)
            }
        }
        jars[pluginName] = jar
        lock.unlock()
        persist()
        KazumiLog.plugin.info(
            "[PluginCookieStore] Login saved \(cookies.count) cookies for \(pluginName, privacy: .public)"
        )
    }

    // MARK: - 落盘

    /// 登录态要跨重启（LP 5427「解决部分规则需要登录才能播放」）：
    /// 每条规则的 Cookie 与 UA 一起写进 UserDefaults，启动时读回来。
    private func persist() {
        lock.lock()
        let snapshot = Snapshot(jars: jars, userAgents: userAgents)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        jars = snapshot.jars
        userAgents = snapshot.userAgents
    }

    /// 解析 `a=b; c=d` 形式的字符串（document.cookie 的格式）。
    private func parse(_ raw: String, host: String) -> [Cookie] {
        var cookies: [Cookie] = []
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            cookies.append(Cookie(name: name, value: value, domain: host, path: "/"))
        }
        return cookies
    }

    /// 与 CookieJar.loadForRequest 对齐：域名匹配（含父域）且路径前缀匹配。
    /// 这条规则有没有存着登录 Cookie（失败提示要据此多一句「可能登录过期了」）。
    func hasCookies(pluginName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(jars[pluginName]?.isEmpty ?? true)
    }

    func cookies(pluginName: String, url: String) -> [Cookie] {
        guard let components = URLComponents(string: url) else { return [] }
        let host = (components.host ?? "").lowercased()
        let isHTTPS = components.scheme?.lowercased() == "https"
        let requestPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        lock.lock()
        defer { lock.unlock() }
        guard let jar = jars[pluginName] else { return [] }
        return jar.filter { cookie in
            if cookie.isSecure == true, !isHTTPS { return false }
            // 域级 Cookie 存下来是带前导点的（`.cycani.org`）：不去点永远筛不上，
            // 整条被静默丢掉（Fuck 5469）。
            let domain = Self.normalizedDomain(cookie.domain)
            let domainMatches = !host.isEmpty && (host == domain || host.hasSuffix(".\(domain)"))
            return domainMatches && pathMatches(requestPath: requestPath, cookiePath: cookie.path)
        }
    }

    /// 去掉前导点、转小写：存的时候和比的时候用同一套。
    static func normalizedDomain(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }

    private func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        if !requestPath.hasPrefix(cookiePath) { return false }
        return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")
    }

    /// 组装 `name=value; name=value` 形式的请求头，无 Cookie 时返回空串。
    func cookieHeader(pluginName: String, url: String) -> String {
        cookies(pluginName: pluginName, url: url)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 验证时 WebView 使用的 UA；未验证过的规则返回 nil。
    func userAgent(for pluginName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return userAgents[pluginName]
    }

    func clear(pluginName: String) {
        lock.lock()
        jars[pluginName] = nil
        userAgents[pluginName] = nil
        lock.unlock()
        persist()
    }

    func clearAll() {
        lock.lock()
        jars.removeAll()
        userAgents.removeAll()
        lock.unlock()
        persist()
    }
}
