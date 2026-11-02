//
//  TraceAPI.swift
//  Kazumi
//
//  1:1 翻译 lib/request/apis/trace_api.dart + lib/request/clients/trace_client.dart：
//  * POST https://api.trace.moe/search?anilistInfo=2
//  * 传图片文件时 body 是图片原始字节，Content-Type 为 image/jpeg；
//  * 传图片链接时 URL 作为 `url` 查询参数，body 为空。
//
//  与 Dart 版一致：识别失败会抛出错误（由页面转成提示文案），
//  只有 trace.moe 明确返回 `error` 字段时，读的是响应体里的错误。
//

import Foundation

enum TraceAPI {
    /// 对应 ApiEndpoints.traceApi。
    static let searchEndpoint = "https://api.trace.moe/search"

    private static let sessionProvider = ProxyAwareURLSession {
        let configuration = URLSessionConfiguration.default
        // 图片识别耗时较长，读超时与 NetworkConfig 的接收超时保持一致的 12s 太短，
        // 原版 trace_client 使用独立的 30s 接收超时。
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        KazumiNetworkPolicy.applyProxy(to: configuration)
        return configuration
    }

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private static var session: URLSession { sessionProvider.session }

    /// 对应 searchAnimeByImageFile。
    static func searchByImageData(_ data: Data, anilistInfo: Int = 2) async throws -> ImageSearchItem {
        var request = try makeRequest(anilistInfo: anilistInfo, imageURL: nil)
        request.httpBody = data
        request.setValue("image/jpeg", forHTTPHeaderField: "content-type")
        return try await send(request)
    }

    /// 对应 searchAnimeByImageUrl。
    static func searchByImageURL(_ imageURL: String, anilistInfo: Int = 2) async throws -> ImageSearchItem {
        let request = try makeRequest(anilistInfo: anilistInfo, imageURL: imageURL)
        return try await send(request)
    }

    // MARK: - 请求

    private static func makeRequest(anilistInfo: Int, imageURL: String?) throws -> URLRequest {
        guard var components = URLComponents(string: searchEndpoint) else {
            throw NetworkError.transport(String(localized: "trace.moe 接口地址无效"))
        }
        var query = [URLQueryItem(name: "anilistInfo", value: String(anilistInfo))]
        if let imageURL, !imageURL.isEmpty {
            query.append(URLQueryItem(name: "url", value: imageURL))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw NetworkError.transport("trace.moe 接口地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(HTTPHeaders.randomUserAgent(), forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> ImageSearchItem {
        KazumiLog.network.debug("POST \(request.url?.absoluteString ?? "", privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw NetworkError.cancelled }
            throw NetworkError.transport(error.localizedDescription)
        } catch {
            throw NetworkError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport(String(localized: "trace.moe 返回了未知响应"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.badResponse(status: http.statusCode, body: body, headers: [:])
        }

        let json: JSONValue
        do {
            json = try JSONValue.decode(data)
        } catch {
            throw NetworkError.decoding(String(localized: "trace.moe 响应解析失败"))
        }
        return ImageSearchItem.fromJSON(json)
    }
}
