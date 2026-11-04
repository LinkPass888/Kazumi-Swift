//
//  RuleHTTPClient.swift
//  Kazumi
//
//  1:1 翻译 lib/request/clients/plugin_site_client.dart 与 rule_engine.dart 中的
//  _DefaultRuleRequestExecutor。
//
//  行为约定：
//  * 默认头随机 UA / Accept-Language / Connection，规则头覆盖之；
//  * 头名统一小写，避免规则里的 `User-Agent` 与我们发送的头重复冲突；
//  * 附带 Cookie 时改用验证码流程里记录的 UA（clearance cookie 与 UA 绑定），
//    同时补 referer: baseUrl/；
//  * 非 2xx 抛 NetworkError.badResponse，保留响应体供反爬挑战页检测；
//  * POST + json 用 JsonBodyEncoder 编码，避免 JSONValue 被再次转义成字符串。
//

import CoreFoundation
import Foundation

final class RuleHTTPClient: RuleRequestExecutor, @unchecked Sendable {
    static let shared = RuleHTTPClient()

    /// 与 DioFactory 的 NetworkConfig 默认值一致。
    private static let connectTimeout: TimeInterval = 12
    private static let receiveTimeout: TimeInterval = 12

    private let sessionProvider: ProxyAwareURLSession
    private let cookies: PluginCookieStore

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private var session: URLSession { sessionProvider.session }

    init(cookies: PluginCookieStore = .shared, configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = RuleHTTPClient.receiveTimeout
        config.timeoutIntervalForResource = RuleHTTPClient.connectTimeout + RuleHTTPClient.receiveTimeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "user-agent": HTTPHeaders.randomUserAgent(),
            "accept-language": HTTPHeaders.randomAcceptLanguage()
        ]
        self.sessionProvider = ProxyAwareURLSession {
            KazumiNetworkPolicy.applyProxy(to: config)
            return config
        }
        self.cookies = cookies
    }

    func execute(_ request: PreparedRuleRequest, config: RuleExecutionConfig) async throws -> String {
        let cookieHeader = request.includeCookies
            ? cookies.cookieHeader(pluginName: config.pluginName, url: request.url)
            : ""
        let verifiedUserAgent = cookieHeader.isEmpty
            ? nil
            : cookies.userAgent(for: config.pluginName)

        // 头名小写化，规则自带的 User-Agent 覆盖默认值而不是并列发送。
        var headers: [String: String] = [
            "user-agent": HTTPHeaders.randomUserAgent(),
            "accept-language": HTTPHeaders.randomAcceptLanguage(),
            "connection": "keep-alive"
        ]
        headers["referer"] = "\(config.baseUrl)/"
        if !cookieHeader.isEmpty { headers["cookie"] = cookieHeader }
        for (key, value) in request.headers {
            headers[key.lowercased()] = value.stringValue ?? value.serialized(pretty: false)
        }
        // clearance cookie 与签发时的 UA 绑定，用规则自带的 UA 会让站点再次下发挑战页。
        if let verifiedUserAgent, !verifiedUserAgent.isEmpty {
            headers["user-agent"] = verifiedUserAgent
        }
        if request.method == "POST" {
            switch request.bodyType {
            case .json:
                if headers["content-type"] == nil { headers["content-type"] = "application/json" }
            case .form:
                if headers["content-type"] == nil {
                    headers["content-type"] = "application/x-www-form-urlencoded"
                }
            case .none:
                break
            }
        }

        guard var components = URLComponents(string: request.url) else {
            throw NetworkError.transport(String(localized: "请求 URL 无效: \(String(describing: request.url))"))
        }
        if !request.query.isEmpty {
            var items = components.queryItems ?? []
            for (key, value) in request.query {
                items.append(URLQueryItem(
                    name: key,
                    value: value.stringValue ?? value.serialized(pretty: false)
                ))
            }
            components.queryItems = items
        }
        guard let url = components.url else {
            throw NetworkError.transport(String(localized: "请求 URL 无效: \(String(describing: request.url))"))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = RuleHTTPClient.receiveTimeout
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if request.method == "POST", let body = request.body {
            switch request.bodyType {
            case .json:
                urlRequest.httpBody = try JsonBodyEncoder.encode(body)
            case .form:
                urlRequest.httpBody = Data(FormBodyEncoder.encode(body).utf8)
            case .none:
                break
            }
        }

        KazumiLog.network.debug("\(request.method, privacy: .public) \(url.absoluteString, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            if error.code == .cancelled { throw NetworkError.cancelled }
            throw NetworkError.transport(error.localizedDescription)
        } catch {
            throw NetworkError.transport(error.localizedDescription)
        }

        let body = Self.decodeText(data, response: response)
        guard let httpResponse = response as? HTTPURLResponse else {
            return body
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var headerFields: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headerFields[String(describing: key).lowercased()] = String(describing: value)
            }
            throw NetworkError.badResponse(status: httpResponse.statusCode, body: body, headers: headerFields)
        }
        return body
    }

    /// 优先按响应声明的字符集解码（国内站点常有 GBK），失败再退回 UTF-8。
    private static func decodeText(_ data: Data, response: URLResponse) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let name = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
