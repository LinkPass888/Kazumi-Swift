//
//  WebDAVClient.swift
//  Kazumi
//
//  对应 lib/services/sync/webdav.dart 的必要子集：
//  * 目录固定为 <服务器>/Kazumi/，备份文件 kazumi_backup.json；
//  * 上传前先确保目录存在（MKCOL，已存在则忽略 405）；
//  * 使用 Basic 认证，凭据来自 SettingsStore。
//

import Foundation

@MainActor
struct WebDAVClient {
    /// 与 Flutter 版一致的同步根目录。
    ///
    /// 原版的服务端布局（见 lib/services/sync/webdav.dart:16-20）：
    ///   /kazumiSync/collectibles.tmp               追番收藏（Hive 箱文件）
    ///   /kazumiSync/collectchanges.tmp             收藏变更队列
    ///   /kazumiSync/histories.tmp                  旧版观看记录
    ///   /kazumiSync/history/snapshot.json          观看记录快照
    ///   /kazumiSync/history/changes/<设备>.jsonl    观看记录事件日志
    ///   /kazumiSync/danmakuShield/<设备>.json       弹幕屏蔽词
    ///
    /// 本端只实现「整包备份」这一个子集：往同一个根目录写
    /// `kazumi_backup.json`。两边目录同名、文件不同名也不同格式，因此
    /// **互不识别** —— 不过也不会互相干扰：原版读根目录时按文件名精确匹配
    /// （webdav.dart:203-207 只找 collectibles.tmp / collectchanges.tmp），
    /// 多出这个文件既不会被解析，也不会让同步报错。
    static let directoryName = "kazumiSync"
    static let backupFileName = "kazumi_backup.json"

    struct Payload: Codable, Sendable {
        var version: Int = 1
        var exportedAt: Date = Date()
        var entries: [LibraryEntry]
        var history: [WatchRecord]
        /// 弹幕屏蔽词，按原样存那串换行的文本。
        ///
        /// 存成文本而不是拆成数组，是因为本机的存储本来就是用换行拼接的，
        /// 主题里带空格、以 `/` 包起来写正则的规则原样进出，不用二次解析。
        var danmakuRules: String = ""

        /// 收藏：这份备份是「把云盘上原版那份旧格式收藏并进来」的哪一刻（LP 2026-10-28）。
        ///
        /// 旧版把收藏存在 `kazumiSync/collectibles.tmp` 里——Hive 二进制箱体，
        /// 和本端备份里的格式完全不同，所以只有收藏需要这枚记号。
        /// 观看记录与屏蔽词两边都是 JSON、同一套格式，每次同步读写就行，不靠记号。
        ///
        /// 下次同步拿它跟云盘上那份箱体的修改时间比：
        ///   * 字段不写（`nil`）：没并过，或者云盘上根本没有旧格式收藏 —— 这两种不必区分，
        ///     去云盘看一眼就知道；云盘上没有旧文件时故意不写，否则以后翻存档的人
        ///     会以为「有过旧数据却没并」；
        ///   * 有值且箱体比它新：旧版那边又改过收藏，再并一轮；
        ///   * 有值且箱体没比它新：并过了，不再读。
        var legacyCollectMergedAt: Date?

        /// 本端取消过的收藏：番剧 ID + 取消时刻。
        ///
        /// 没有这份记录，取消掉的收藏会被云盘上还在的那一条「复活」。
        /// 合并时按时间比：取消比收藏晚就删。上传后这份会跟着备份走，
        /// 别的设备也能看到这次取消。
        var removedEntries: [RemovedEntry] = []

        init(
            entries: [LibraryEntry],
            history: [WatchRecord],
            danmakuRules: String = "",
            legacyCollectMergedAt: Date? = nil,
            removedEntries: [RemovedEntry] = []
        ) {
            self.entries = entries
            self.history = history
            self.danmakuRules = danmakuRules
            self.legacyCollectMergedAt = legacyCollectMergedAt
            self.removedEntries = removedEntries
        }

        /// 旧备份（只有 entries / history）也要能读：缺的字段当空。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
            entries = try container.decodeIfPresent([LibraryEntry].self, forKey: .entries) ?? []
            history = try container.decodeIfPresent([WatchRecord].self, forKey: .history) ?? []
            danmakuRules = try container.decodeIfPresent(String.self, forKey: .danmakuRules) ?? ""
            legacyCollectMergedAt = try container.decodeIfPresent(Date.self, forKey: .legacyCollectMergedAt)
            removedEntries = try container.decodeIfPresent([RemovedEntry].self, forKey: .removedEntries) ?? []
        }

        /// 服务器上读回来的那份，跟刚写上去的那份是不是同一份。
        ///
        /// 只比「恢复之后用户能看到什么」：条数、每条的 ID、屏蔽词原文、
        /// 记录的更新时间。时间按秒比——`.iso8601` 编码会把小数秒截掉，
        /// 直接比 `Date` 相等会永远不成立。
        func matches(_ other: Payload) -> Bool {
            // 时刻本身也要对得上：写上去的是「并到这一秒」，读回来变成没写，
            // 下次同步就会重新读一遍旧文件，白花一轮。
            switch (legacyCollectMergedAt, other.legacyCollectMergedAt) {
            case (nil, nil):
                break
            case let (mine?, theirs?):
                guard abs(mine.timeIntervalSince(theirs)) < 1 else { return false }
            default:
                return false
            }
            guard danmakuRules == other.danmakuRules else { return false }
            guard entries.count == other.entries.count,
                  history.count == other.history.count else { return false }
            guard entries.map(\.id).sorted() == other.entries.map(\.id).sorted() else { return false }
            // 取消记录也得一样：少了它，取消过的收藏会凭空回来。
            guard removedEntries.map(\.id).sorted() == other.removedEntries.map(\.id).sorted(),
                  Self.sameInstants(removedEntries.map(\.removedAt), other.removedEntries.map(\.removedAt))
            else { return false }
            // 观看记录的 ID 现在是「规则名 + 番剧号」：比 bangumiID 的话，
            // 同一条记录的规则归属变了也会验成「对得上」（Fuck 4875）。
            guard history.map(\.id).sorted() == other.history.map(\.id).sorted() else { return false }
            guard Self.sameInstants(entries.map(\.updatedAt), other.entries.map(\.updatedAt)) else { return false }
            return Self.sameInstants(history.map(\.updatedAt), other.history.map(\.updatedAt))
        }

        private static func sameInstants(_ lhs: [Date], _ rhs: [Date]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { pair in abs(pair.0.timeIntervalSince(pair.1)) < 1 }
        }
    }

    enum WebDAVError: Error, LocalizedError {
        case notConfigured
        case invalidURL(String)
        case unauthorized
        /// 服务器上还没有备份文件（首次使用）。
        case notFound
        /// 云盘上有这个文件，但它是 **0 字节**：没有数据可恢复，也不算读失败。
        ///
        /// koofr 这类服务上出现过：某次写入只落了元数据，之后 forever 返回
        /// 200 且 content-length: 0。以前它走到「开头不是 JSON」那条，被上层
        /// 翻译成「请检查网络」——用户看到的是让他去查网络，可网络是好的。
        case emptyBackup
        case badStatus(Int)
        case decoding(String)
        /// 写上去了，但按恢复那条路读回来对不上——这次不能算备份成功。
        case notReadableBack

        var errorDescription: String? {
            switch self {
            case .notConfigured: "请先填写 WebDAV 服务器地址"
            case .invalidURL(let url): "WebDAV 地址无效：\(url)"
            case .unauthorized: "认证失败，请检查用户名与密码"
            case .notFound: "服务器上还没有备份，先点「立即备份」上传一份"
            case .emptyBackup: "云盘上的备份文件是空的（0 字节），里面没有数据可恢复。"
            case .badStatus(let status): "服务器出错了（\(status)），请稍后再试。"
            case .decoding(let message): message
            case .notReadableBack:
                "文件已经写上去了，但读回来核对不上，这次不算备份成功。"
            }
        }

        /// 只进运行日志的那份：保留技术原文（状态码、解码器的原话）。
        ///
        /// 屏上那句话是给用户看的（他改不了的，就告诉他改不了）；
        /// 这一句是给查问题的人看的，一个字不能少。
        var logDescription: String {
            switch self {
            case .badStatus(let status): "服务器返回 HTTP \(status)"
            case .emptyBackup: "云盘上的备份文件是 0 字节"
            case .decoding(let message): message
            default: errorDescription ?? ""
            }
        }
    }

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func upload(_ payload: Payload) async throws {
        let folder = try folderURL()
        try await ensureDirectory(folder)
        let target = folder.appending(path: Self.backupFileName)
        var request = try authorizedRequest(url: target, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body = try Self.encoder().encode(payload)
        request.httpBody = body
        let (_, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // 云盘上出现过 0 字节的备份文件，靠这两个数分得清是「我们没发出去」
        // 还是「服务器没存」——不然只能猜。
        KazumiLogBuffer.shared.append(
            "WebDAV PUT \(Self.backupFileName) 发出 \(body.count) 字节，HTTP \(status)",
            category: .network
        )
        try Self.validate(response)
    }

    func download() async throws -> Payload {
        let target = try folderURL().appending(path: Self.backupFileName)
        var request = try authorizedRequest(url: target, method: "GET")
        // 备份文件绝不能吃本地缓存：缓存里可能躺着一份旧的（或空的）。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        KazumiLogBuffer.shared.append(
            "WebDAV GET \(Self.backupFileName) 收到 \(data.count) 字节，HTTP \(status)",
            category: .network
        )
        try Self.validate(response)
        // 0 字节是单独一回事：文件在，里面什么都没有。不当成「格式不对」，
        // 否则上层只能报到「请检查网络」，把一个坏文件说成网络故障。
        guard !data.isEmpty else { throw WebDAVError.emptyBackup }
        // WebDAV 服务器出错时常常也是 200，回的却是一张 HTML 登录页 / 错误页。
        // 先看开头是不是 JSON，别让解码器只报一句英文的「格式不对」。
        guard Self.looksLikeJSON(data) else {
            throw WebDAVError.decoding("云盘上的那个文件不是备份文件（开头不是 JSON），可能是登录页或错误页。")
        }
        do {
            return try Self.decoder().decode(Payload.self, from: data)
        } catch let decoding as DecodingError {
            // DecodingError 的 localizedDescription 是系统英文，用户看不懂，这里自己归类成中文。
            switch decoding {
            case .dataCorrupted:
                throw WebDAVError.decoding("云盘上的备份文件不是有效的备份（可能不是本应用写的，或者文件已损坏）。")
            case .keyNotFound, .typeMismatch, .valueNotFound:
                throw WebDAVError.decoding("备份文件格式跟当前版本对不上（缺少或多余的字段）。")
            default:
                throw WebDAVError.decoding("备份文件读取失败，格式不对。")
            }
        } catch {
            throw WebDAVError.decoding("备份文件读取失败，格式不对。")
        }
    }

    /// 拿一个固定路径下的原文，没有这个文件返回 nil（不抛错）。
    ///
    /// 给原版 Flutter 那套旧格式用（`history/snapshot.json`、
    /// `danmakuShield/<设备>.json`）：那些文件不是本端的包，只能用原文读。
    func rawDownload(path: String) async throws -> Data? {
        let base = try folderURL()
        var target = base
        for part in path.split(separator: "/") {
            target.append(path: String(part))
        }
        let request = try authorizedRequest(url: target, method: "GET")
        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try Self.validate(response)
        return data
    }

    /// 往固定路径写原文（旧格式用）：逐级建目录，再 PUT。
    ///
    /// `history/snapshot.json` 和 `danmakuShield/<设备>.json` 不是本端的包，
    /// 只能按原版的格式原样写回去，原版才读得到。
    func uploadRaw(path: String, data: Data, contentType: String = "application/json") async throws {
        let base = try folderURL()
        try await ensureDirectory(base)
        var target = base
        let parts = path.split(separator: "/")
        for part in parts.dropLast() {
            target.append(path: String(part), directoryHint: .isDirectory)
            try await ensureDirectory(target)
        }
        if let last = parts.last { target.append(path: String(last)) }
        var request = try authorizedRequest(url: target, method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        request.httpBody = data
        let (_, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        try Self.validate(response)
    }

    /// 列一个目录下的文件名（PROPFIND Depth 1）。目录不存在时返回空数组。
    func listFolder(path: String) async throws -> [String] {
        let base = try folderURL()
        var target = base
        for part in path.split(separator: "/") {
            target.append(path: String(part), directoryHint: .isDirectory)
        }
        var request = try authorizedRequest(url: target, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "depth")
        request.setValue("application/xml", forHTTPHeaderField: "content-type")
        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return [] }
        try Self.validate(response)
        return Self.hrefs(in: data).filter { !$0.hasSuffix("/") }
    }

    /// 一个目录下每个文件的修改时间（PROPFIND Depth 1 里的 getlastmodified）。
    ///
    /// 只用来回答一个问题：云盘上那份原版旧格式文件，比上次并进备份的那一刻新吗。
    /// 目录不存在时返回空数组。
    func modifiedFiles(path: String) async throws -> [(name: String, modified: Date)] {
        let base = try folderURL()
        var target = base
        for part in path.split(separator: "/") {
            target.append(path: String(part), directoryHint: .isDirectory)
        }
        var request = try authorizedRequest(url: target, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "depth")
        request.setValue("application/xml", forHTTPHeaderField: "content-type")
        let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return [] }
        try Self.validate(response)
        return Self.fileEntries(in: data)
    }

    /// 云盘上那几份能读的旧格式文件里最新的一次修改；一份都没有时返回 nil。
    ///
    /// 看的是原版实际会写的两处：`history/` 下的快照、`danmakuShield/` 下各设备的文件。
    /// 收藏那两份（`collectibles.tmp` / `collectchanges.tmp`）是 Hive 二进制箱，
    /// 本端读不了，也不写，所以既不算进来也不碰。
    func newestLegacyModified() async throws -> Date? {
        var newest: Date?
        for folder in [WebDAVLegacy.historyFolder, WebDAVLegacy.shieldFolder] {
            for entry in try await modifiedFiles(path: folder) where entry.name.hasSuffix(".json") {
                if newest == nil || entry.modified > newest! { newest = entry.modified }
            }
        }
        return newest
    }

    /// 从 PROPFIND 的回包里读出「文件名 + 修改时间」（命名空间前缀各家不同，按后缀匹配）。
    private static func fileEntries(in xml: Data) -> [(name: String, modified: Date)] {
        guard let text = String(data: xml, encoding: .utf8) else { return [] }
        var results: [(name: String, modified: Date)] = []
        var name: String?
        var modified: Date?
        for token in text.components(separatedBy: "<") {
            guard let end = token.firstIndex(of: ">") else { continue }
            let tag = token[..<end]
            let value = String(token[token.index(after: end)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let localName = (tag.hasPrefix("/") ? tag.dropFirst() : tag).split(separator: ":").last ?? ""
            if tag.hasPrefix("/") {
                // 收尾标签：一块 response 读完了，登记这一条。
                if localName == "response", let entryName = name, let entryDate = modified {
                    results.append((entryName, entryDate))
                }
                if localName == "response" {
                    name = nil
                    modified = nil
                }
                continue
            }
            if localName == "href" {
                let decoded = value.removingPercentEncoding ?? value
                name = decoded.split(separator: "/").last.map(String.init)
            } else if localName == "getlastmodified" {
                modified = Self.httpDate(value)
            }
        }
        return results
    }

    /// HTTP 头里那种时间：`Wed, 28 Oct 2026 03:49:00 GMT`。读不出来就是 nil。
    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: text) { return date }
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: text)
    }

        /// 云盘上那两处旧文件的修改时间（PROPFIND 里的 getlastmodified）。
        ///
        /// 只给 `WebDAVSync` 判「旧版又写过东西没有」用：比上次记下的时间新才重新读一遍。
        /// 文件不存在时返回 nil（不是错误）。
        func modifiedDate(path: String) async throws -> Date? {
            let base = try folderURL()
            var target = base
            let parts = path.split(separator: "/")
            for (index, part) in parts.enumerated() {
                let last = index == parts.count - 1
                target.append(path: String(part), directoryHint: last ? .notDirectory : .isDirectory)
            }
            var request = try authorizedRequest(url: target, method: "PROPFIND")
            request.setValue("0", forHTTPHeaderField: "depth")
            request.setValue("application/xml", forHTTPHeaderField: "content-type")
            let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
            try Self.validate(response)
            return Self.fileEntries(in: data).first?.modified
        }

    /// 从 PROPFIND 的回包里挑出条目名（各家的命名空间前缀不一样，按后缀匹配）。
    private static func hrefs(in xml: Data) -> [String] {
        guard let text = String(data: xml, encoding: .utf8) else { return [] }
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: ":href>") {
            guard let close = rest[open.upperBound...].range(of: "</") else { break }
            let raw = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]
            let decoded = raw.removingPercentEncoding ?? String(raw)
            let name = decoded.split(separator: "/").last.map(String.init) ?? ""
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    /// 备份：写上去，再**用恢复那条路**读回来对一遍。
    ///
    /// 安全网自己坏了必须当场知道：以前这里 `upload` 一返回就说「备份完成」，
    /// 可服务器没存全、或者存的格式我们自己读不回来时，用户要到真正恢复的
    /// 那天才发现没得恢复。所以成功与否以「读得回来」为准，不以「传完了」为准。
    func uploadAndVerify(_ payload: Payload) async throws {
        try await upload(payload)
        // 有些服务器写完不是立刻可读（最终一致、或写入后还在落盘）。
        // 立刻读一次就判失败会冤枉它，所以给几次机会再下结论。
        var lastError: Error = WebDAVError.notReadableBack
        for attempt in 1...3 {
            do {
                let readBack = try await download()
                guard readBack.matches(payload) else {
                    lastError = WebDAVError.notReadableBack
                    continue
                }
                return
            } catch {
                lastError = error
            }
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        throw lastError
    }

    /// 连通性检查：对应原版 `WebDav().ping()`。
    ///
    /// 只做一次根目录的 PROPFIND，不发任何写请求，
    /// 用来在填完地址后先确认「地址 / 账号 / 密码」这三样是对的。
    func ping() async throws {
        let raw = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WebDAVError.notConfigured }
        guard var url = URL(string: raw) else { throw WebDAVError.invalidURL(raw) }
        if !url.absoluteString.hasSuffix("/") {
            url.append(path: "")
        }
        var request = try authorizedRequest(url: url, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "depth")
        request.setValue("application/xml", forHTTPHeaderField: "content-type")
        let (_, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        try Self.validate(response)
    }

    // MARK: - 内部

    private func folderURL() throws -> URL {
        let raw = settings.webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WebDAVError.notConfigured }
        guard var base = URL(string: raw) else { throw WebDAVError.invalidURL(raw) }
        if !base.absoluteString.hasSuffix("/") {
            base.append(path: "")
        }
        return base.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    /// MKCOL 建目录。
    ///
    /// 已存在时各家的返回并不统一：RFC 4918 规定是 405，
    /// 也有服务器返回 301 / 409，还有直接回 204 的 —— 这些都算「目录已在」，
    /// 不能当成失败上报（否则第一次之后每次备份都报错）。
    private func ensureDirectory(_ url: URL) async throws {
        var request = try authorizedRequest(url: url, method: "MKCOL")
        request.setValue("0", forHTTPHeaderField: "content-length")
        let (_, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300, 301, 405, 409:
            return
        default:
            try Self.validate(response)
        }
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        let user = settings.webDAVUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            let token = Data("\(user):\(settings.webDAVPassword)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300, 201, 204:
            return
        case 401, 403:
            throw WebDAVError.unauthorized
        case 404:
            // 首次使用时目录或备份文件还不存在，这不是网络故障，
            // 要给用户一句能照着做的话，而不是「服务器返回 HTTP 404」。
            throw WebDAVError.notFound
        default:
            throw WebDAVError.badStatus(http.statusCode)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 第一个非空白字节是不是 `{`。空内容、HTML、纯文本都不算。
    private static func looksLikeJSON(_ data: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return data.first { !whitespace.contains($0) } == 0x7B
    }
}
