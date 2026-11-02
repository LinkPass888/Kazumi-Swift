//
//  DanmakuAPI.swift
//  Kazumi
//
//  DanDanPlay 弹幕接口的原生实现，对应
//  lib/request/apis/danmaku_api.dart + lib/request/clients/danmaku_client.dart：
//
//   1. `GET /api/v2/bangumi/bgmtv/{bgmId}` 把 Bangumi 的 subject id 换成
//      DanDanPlay 的 animeId（对应 getDanDanBangumiIDByBgmBangumiID）；
//   2. `GET /api/v2/comment/{animeId}{第几集补足四位}?withRelated=true&chConvert=1`
//      取这一集的弹幕（对应 getDanDanmaku）。
//
//  接口需要 AppId / 签名：签名算法为
//  base64(sha256(appId + timestamp + path + secret))，与原版
//  lib/utils/crypto.dart 的 generateDandanSignature 完全一致。
//  凭据优先取设置里手填的值，其次取 Info.plist 的 DanDanAppId / DanDanAppSecret
//  （构建时可通过 DANDAN_APP_ID / DANDAN_APP_SECRET 注入）。
//

import CryptoKit
import Foundation

/// 一条弹幕。字段对应 DanDanPlay 的 `p`：`time,mode,color,uid`。
///
/// * mode 1：滚动（从右往左）
/// * mode 4：底部固定
/// * mode 5：顶部固定
struct DanmakuComment: Identifiable, Hashable, Sendable {
    let id: Int
    let time: Double
    let mode: Int
    let colorValue: Int
    let text: String
    /// 这条弹幕的来路，取 DanDanPlay `p` 的第 4 段（BiliBili／Gamer／DanDanPlay）。
    /// 弹幕设置里三颗来源开关就是按它过滤的（main: _isDanmakuSourceEnabled）。
    let source: String
}

/// 一次取弹幕的结果，UI 据此决定提示文案。
enum DanmakuFetchResult: Sendable {
    case success([DanmakuComment])
    /// 这一集本来就没有弹幕：正常情况，界面上什么都不显示（Ato 2026-10-25）。
    case empty
    /// 没有可用数据（未配置凭据 / DanDanPlay 没有这部番的记录）。
    case unavailable(String)
    /// 网络或接口失败。
    case failed(String)
}

/// DanDanPlay 的凭据。只在打包时注入（Info.plist 的 DanDanAppId / DanDanAppSecret）。
/// 设置页不再手填——LP 2026-10-24：「这个不是手动填的，是打包时从变量注入的」。
enum DanDanCredentials {
    static var appID: String { value(forInfoKey: "DanDanAppId") }
    static var secret: String { value(forInfoKey: "DanDanAppSecret") }

    static var isConfigured: Bool { !appID.isEmpty && !secret.isEmpty }

    private static func value(forInfoKey infoKey: String) -> String {
        let bundleValue = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 没有注入时 Xcode 可能把 `$(...)` 原样留下，这种情况按空处理。
        guard !bundleValue.hasPrefix("$("), !bundleValue.hasPrefix("${") else { return "" }
        return bundleValue
    }
}

/// 与原版 generateDandanSignature 一致。
enum DanDanSignature {
    static func make(appID: String, secret: String, path: String, timestamp: Int) -> String {
        let raw = appID + String(timestamp) + path + secret
        let digest = SHA256.hash(data: Data(raw.utf8))
        return Data(digest).base64EncodedString()
    }
}

enum DanmakuError: LocalizedError {
    case badURL
    case badResponse
    case unauthorized
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: String(localized: "弹幕地址无效")
        case .badResponse: String(localized: "弹幕接口返回了无效响应")
        case .unauthorized: String(localized: "弹幕接口需要有效的 DanDanPlay 凭据")
        case .status(429): String(localized: "今日弹幕请求次数已达上限")
        case .status(let code): String(localized: "弹幕接口返回 HTTP \(String(describing: code))")
        }
    }
}

enum DanmakuAPI {
    private static let domain = "https://api.dandanplay.net"

    private static let sessionProvider = ProxyAwareURLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        KazumiNetworkPolicy.applyProxy(to: configuration)
        return configuration
    }

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private static var session: URLSession { sessionProvider.session }

    // MARK: - 对外

    /// 取某一集的弹幕。任何失败都折叠成 `.failed` / `.unavailable`，不抛错。
    static func fetch(bangumiID: Int, episode: Int) async -> DanmakuFetchResult {
        guard DanDanCredentials.isConfigured else {
            return .unavailable(String(localized: "未配置 DanDanPlay 凭据，无法加载弹幕"))
        }
        do {
            let danDanID = try await danDanBangumiID(bgmID: bangumiID)
            guard danDanID > 0 else {
                return .unavailable(String(localized: "DanDanPlay 没有这部番的记录"))
            }
            let comments = try await comments(danDanBangumiID: danDanID, episode: episode)
            guard !comments.isEmpty else {
                return .empty
            }
            return .success(comments)
        } catch {
            KazumiLog.danmaku.error(
                "弹幕加载失败 \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 接口

    /// 对应 getDanDanBangumiIDByBgmBangumiID。返回 0 表示没有映射。
    static func danDanBangumiID(bgmID: Int) async throws -> Int {
        let path = "/api/v2/bangumi/bgmtv/\(bgmID)"
        let data = try await get(path: path)
        let decoded = try JSONDecoder().decode(BangumiResponse.self, from: data)
        return decoded.bangumi.animeId
    }

    /// 对应 getDanDanmaku：episodeId = animeId + 集数补足四位。
    static func comments(danDanBangumiID: Int, episode: Int) async throws -> [DanmakuComment] {
        let episodeID = "\(danDanBangumiID)\(String(format: "%04d", max(0, episode)))"
        return try await comments(episodeID: episodeID)
    }

    static func comments(episodeID: String) async throws -> [DanmakuComment] {
        let path = "/api/v2/comment/\(episodeID)"
        let data = try await get(
            path: path,
            query: [
                URLQueryItem(name: "withRelated", value: "true"),
                URLQueryItem(name: "chConvert", value: "1"),
            ]
        )
        return try parseComments(data)
    }

    // MARK: - 请求

    private static func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(string: domain + path) else {
            throw DanmakuError.badURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw DanmakuError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(HTTPHeaders.randomUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Auth")

        let appID = DanDanCredentials.appID
        let secret = DanDanCredentials.secret
        if !appID.isEmpty, !secret.isEmpty {
            let timestamp = Int(Date().timeIntervalSince1970)
            request.setValue(appID, forHTTPHeaderField: "X-AppId")
            request.setValue("\(timestamp)", forHTTPHeaderField: "X-Timestamp")
            request.setValue(
                DanDanSignature.make(
                    appID: appID,
                    secret: secret,
                    path: path,
                    timestamp: timestamp
                ),
                forHTTPHeaderField: "X-Signature"
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DanmakuError.badResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw DanmakuError.unauthorized
        default:
            throw DanmakuError.status(http.statusCode)
        }
    }

    // MARK: - 解析

    private struct BangumiResponse: Decodable {
        struct Item: Decodable {
            let animeId: Int
        }

        let bangumi: Item
    }

    private struct CommentsResponse: Decodable {
        struct Item: Decodable {
            let p: String
            let m: String
        }

        let comments: [Item]
    }

    private static func parseComments(_ data: Data) throws -> [DanmakuComment] {
        let decoded = try JSONDecoder().decode(CommentsResponse.self, from: data)
        var result: [DanmakuComment] = []
        result.reserveCapacity(min(decoded.comments.count, 6000))

        for (index, item) in decoded.comments.prefix(6000).enumerated() {
            let text = item.m.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let parts = item.p.split(
                separator: ",",
                maxSplits: 3,
                omittingEmptySubsequences: false
            )
            guard parts.count >= 3, let time = Double(parts[0]), time >= 0 else { continue }
            let mode = Int(parts[1]) ?? 1
            let colorValue = Int(parts[2]) ?? 0xFFFFFF
            // maxSplits: 3 —— 前三段切开，剩下的整段就是来源（含可能出现的逗号）。
            let source = parts.count > 3 ? String(parts[3]).trimmingCharacters(in: .whitespaces) : ""
            result.append(
                DanmakuComment(
                    id: index,
                    time: time,
                    mode: mode,
                    colorValue: colorValue,
                    text: text,
                    source: source
                )
            )
        }
        return result.sorted { $0.time < $1.time }
    }
}
