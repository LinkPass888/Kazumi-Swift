//
//  KazumiSyncClient.swift
//  Kazumi
//
//  在 WebDAV 服务器上读写原版 kazumiSync 目录里的文件。
//
//  和 WebDAVClient 的分工：那边管我们自己的整包备份（kazumi_backup.json），
//  这边只碰原版的四个位置，格式与文件名都照原版来，不发明新文件：
//
//    kazumiSync/history/snapshot.json              读写
//    kazumiSync/history/changes/<deviceId>.jsonl   读写（只写自己那一份）
//    kazumiSync/danmakuShield/<deviceId>.json      读写（文件名必须 32 位十六进制）
//    kazumiSync/collectibles.tmp                   只读（Hive 箱体，见 hive-format-findings.md）
//    kazumiSync/collectchanges.tmp                 只读
//    kazumiSync/histories.tmp                      不碰（旧版账本，原版自己都只在没有快照时才读）
//
//  没有删除：本端不发 DELETE，也不发覆盖别人设备文件的 PUT。
//

import Foundation

@MainActor
struct KazumiSyncClient {
    let settings: SettingsStore

    enum SyncError: Error, LocalizedError {
        case notConfigured
        case invalidURL(String)
        case unauthorized
        case badStatus(Int)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "请先填写 WebDAV 服务器地址"
            case .invalidURL(let url): "WebDAV 地址无效：\(url)"
            case .unauthorized: "认证失败，请检查用户名与密码"
            case .badStatus(let status): "服务器返回 HTTP \(status)"
            case .decoding(let message): message
            }
        }
    }

    // MARK: - 路径

    private var rootURL: URL {
        get throws {
            let raw = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { throw SyncError.notConfigured }
            guard var base = URL(string: raw) else { throw SyncError.invalidURL(raw) }
            if !base.absoluteString.hasSuffix("/") { base.append(path: "") }
            return base.appending(path: WebDAVClient.directoryName, directoryHint: .isDirectory)
        }
    }

    private func url(_ components: [String], isDirectory: Bool = false) throws -> URL {
        var result = try rootURL
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            result = result.appending(
                path: component,
                directoryHint: (last && isDirectory) ? .isDirectory : .notDirectory
            )
        }
        return result
    }

    // MARK: - 列目录

    struct RemoteFile: Sendable {
        var name: String
        var size: Int
        var modified: Date?
    }

    /// PROPFIND Depth: 1。目录不存在时返回空数组而不是报错 ——
    /// 第一次使用时这些目录本来就不在，那不是故障。
    func list(_ components: [String]) async throws -> [RemoteFile] {
        let directory = try url(components, isDirectory: true)
        var request = try authorizedRequest(url: directory, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop>
            <d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/>
            </d:prop></d:propfind>
            """.utf8)

        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [] }
        switch http.statusCode {
        case 207, 200: break
        case 404: return []
        case 401, 403: throw SyncError.unauthorized
        default: throw SyncError.badStatus(http.statusCode)
        }
        return Self.parseMultiStatus(data, excluding: directory.lastPathComponent)
    }

    /// 极简 Multistatus 解析：只取 href 末段、长度、修改时间。
    /// 用正则而不是 XMLParser，是因为各家服务器命名空间写法不一，
    /// 这里要的只是三个标量，不需要完整树。
    private static func parseMultiStatus(_ data: Data, excluding directoryName: String) -> [RemoteFile] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var files: [RemoteFile] = []

        let responses = text.replacingOccurrences(
            of: "<(?i)(?:[\\w.-]+:)?response\\b",
            with: "\u{0}",
            options: .regularExpression
        ).components(separatedBy: "\u{0}")
        for response in responses.dropFirst() {
            guard let href = firstMatch(in: response, pattern: "<(?:[\\w.-]+:)?href>([^<]*)</(?:[\\w.-]+:)?href>") else { continue }
            let decoded = href.removingPercentEncoding ?? href
            var name = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
            if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
            guard !name.isEmpty, name != directoryName else { continue }
            // 目录自身那条会被上面过滤掉；子目录（href 以 / 结尾）也跳过。
            if decoded.hasSuffix("/") { continue }

            let size = firstMatch(in: response, pattern: "<(?:[\\w.-]+:)?getcontentlength>(\\d+)</(?:[\\w.-]+:)?getcontentlength>")
                .flatMap(Int.init) ?? 0
            let modified = firstMatch(in: response, pattern: "<(?:[\\w.-]+:)?getlastmodified>([^<]*)</(?:[\\w.-]+:)?getlastmodified>")
                .flatMap(Self.httpDate)
            files.append(RemoteFile(name: name, size: size, modified: modified))
        }
        return files
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }

    // MARK: - 读写文件

    func read(_ components: [String]) async throws -> Data {
        var request = try authorizedRequest(url: try url(components), method: "GET")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw SyncError.unauthorized
        case 404: throw SyncError.badStatus(404)
        default: throw SyncError.badStatus(http.statusCode)
        }
    }

    /// 文件不存在时返回 nil，其余错误照抛。
    func readIfExists(_ components: [String]) async throws -> Data? {
        do {
            return try await read(components)
        } catch SyncError.badStatus(404) {
            return nil
        }
    }

    /// PUT。先确保父目录存在。
    ///
    /// 只用 PUT，不发 MKCOL 以外的方法；也不会 PUT 到别人的文件名上
    /// —— 调用方传进来的最后一段始终是本机 deviceId。
    func write(_ data: Data, to components: [String]) async throws {
        if components.count > 1 {
            try await ensureDirectory(Array(components.dropLast()))
        }
        var request = try authorizedRequest(url: try url(components), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw SyncError.unauthorized
        default: throw SyncError.badStatus(http.statusCode)
        }
    }

    /// MKCOL。已存在时各家返回不一（405 / 301 / 409 / 204），都算成功。
    func ensureDirectory(_ components: [String]) async throws {
        var request = try authorizedRequest(url: try url(components, isDirectory: true), method: "MKCOL")
        request.setValue("0", forHTTPHeaderField: "content-length")
        let (_, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300, 301, 405, 409: return
        case 401, 403: throw SyncError.unauthorized
        default: throw SyncError.badStatus(http.statusCode)
        }
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        let user = settings.webDAVUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            let token = Data("\(user):\(settings.webDAVPassword)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }
}
