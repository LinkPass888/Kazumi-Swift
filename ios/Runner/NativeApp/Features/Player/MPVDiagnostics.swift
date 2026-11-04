import Foundation

/// 只处理诊断文本，不改内核选项或请求；状态由事件泵串行持有。
struct MPVDiagnostics {
    struct Event {
        var receipt: String?
        var line: String?
        var errorText: String?
    }

    private let nonErrorLimit: Int
    private let perSourceLimit: Int
    private var receivedFirstEvent = false
    private var nonErrorCount = 0
    private var sourceCounts: [String: Int] = [:]
    private var seenLines: Set<String> = []
    private var reportedLimit = false

    init(nonErrorLimit: Int = 48, perSourceLimit: Int = 24) {
        self.nonErrorLimit = max(0, nonErrorLimit)
        self.perSourceLimit = max(0, perSourceLimit)
    }

    /// 新文件重新采样；「确实收到事件」只需在事件泵生命周期内证明一次。
    mutating func resetPlayback() {
        nonErrorCount = 0
        sourceCounts.removeAll(keepingCapacity: true)
        seenLines.removeAll(keepingCapacity: true)
        reportedLimit = false
    }

    mutating func receive(prefix: String, level: String, text: String) -> Event {
        let safePrefix = Self.safePrefix(prefix)
        let safeLevel = ["fatal", "error", "warn", "info", "v", "debug", "trace"].contains(level) ? level : "?"
        var event = Event()
        if !receivedFirstEvent {
            receivedFirstEvent = true
            // 不把首条正文当证明：它可能恰好是被拒收的 HTTP 日志。
            event.receipt = String(localized: "内核日志已收到：[\(String(describing: safePrefix))] 级别=\(String(describing: safeLevel))")
        }

        let isError = level == "error" || level == "fatal"
        let source = Self.diagnosticSource(prefix)
        guard isError || level == "warn" || (source != nil && ["info", "v"].contains(level)) else {
            return event
        }
        // 请求/响应转储整条丢弃，包括续行；不尝试保留某个看似无害的头。
        // HTTP 子模块也可能把续行拆成单独事件，不能只按正文找头名。
        let modules = prefix.lowercased().split(separator: "/")
        guard !modules.contains("http"), !modules.contains("https") else { return event }
        let normalized = Self.normalized(text)
        guard !Self.matches(Self.httpDump, normalized) else { return event }
        let safeText = Self.sanitize(normalized)
        guard !safeText.isEmpty else { return event }
        let line = "[\(safePrefix)] \(safeLevel) \(safeText)"
        if isError {
            event.line = line
            event.errorText = safeText
            return event
        }

        // 逐帧统计不采样；每类留配额，避免 GPU 初始化挤掉 vd 的解码信息。
        guard !Self.matches(Self.frameNoise, text), !seenLines.contains(line) else { return event }
        let family = source ?? "other"
        guard nonErrorCount < nonErrorLimit, sourceCounts[family, default: 0] < perSourceLimit else {
            if !reportedLimit {
                reportedLimit = true
                event.line = String(localized: "内核诊断已限流（保留错误）")
            }
            return event
        }
        nonErrorCount += 1
        sourceCounts[family, default: 0] += 1
        seenLines.insert(line)
        event.line = line
        return event
    }

    /// 所有 onLog 和错误摘要的最后一道边界。先脱敏再截断，输出始终单行。
    static func sanitize(_ text: String) -> String {
        // 整段隐藏，防止折行头、JSON 请求体或转义换行里的凭据漏到下一行。
        let normalized = normalized(text)
        if matches(httpDump, normalized) || matches(secrets, normalized) {
            return String(localized: "[敏感诊断已隐藏]")
        }
        var result = urls.stringByReplacingMatches(
            in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: String(localized: "[URL已隐藏]")
        )
        result = result.components(separatedBy: .controlCharacters.union(.newlines))
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return result.count > 600 ? String(result.prefix(600)) + "…" : result
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\r"#, with: "\r")
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .components(separatedBy: .controlCharacters.subtracting(.newlines))
            .joined(separator: " ")
    }

    private static func diagnosticSource(_ prefix: String) -> String? {
        guard safePrefix(prefix) == prefix else { return nil }
        for source in ["vd", "vo/libmpv", "libmpv_render", "hwdec"] {
            if prefix == source || prefix.hasPrefix(source + "/") { return source }
        }
        return nil
    }

    private static func safePrefix(_ prefix: String) -> String {
        // 不回显非法前缀、换行、URL 或任意长字符串。
        matches(prefixSyntax, prefix) ? prefix : "未知"
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let prefixSyntax = try! NSRegularExpression(pattern: #"\A[a-z0-9_/-]{1,80}\z"#)
    private static let urls = try! NSRegularExpression(
        // 连路径也不保留：签名不一定只在 query；兼容代理 URL、转义和编码 URL。
        // 撇号在 userinfo 和路径里都合法，不能当结束符，宁可多隐藏也不漏凭据。
        pattern: #"(?i)(?:(?:[a-z][a-z0-9+.-]*:)?//|[a-z][a-z0-9+.-]*:\\/\\/|https?%3a%2f%2f)[^\s<>"]+"#
    )
    private static let httpDump = try! NSRegularExpression(
        pattern: #"(?im)\b(?:http[-_ ]header(?:s|[-_ ]fields)?|(?:request|response)[-_ ]headers?|header[-_ ]fields)\b|\b(?:request|response|headers?)\s*[:=]|\b(?:send(?:ing)?|recv|received|read|write)\s+headers?\b|\b(?:GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|CONNECT|TRACE)\s+\S+\s+HTTP/\d|\bHTTP/\d(?:\.\d)?\s+\d{3}|\b(?:Cookie|Set-Cookie|Authorization|Proxy-Authorization|Host|User-Agent|Referer|Referrer|Location|Accept(?:-[a-z]+)?|Content-[a-z-]+|Connection|X-[a-z0-9_-]+)\s*["']?\s*[:=]|(?:^|[\r\n])\s*(?:\[[^\]\r\n]*\]\s*)?[<>]?\s*[a-z][a-z0-9_]*(?:-[a-z0-9_]+)+:\s*\S"#
    )
    private static let secrets = try! NSRegularExpression(
        pattern: #"(?i)\b(?:[a-z0-9_-]*(?:token|secret|signature|credential|api[-_]?key|session[-_]?id|password|passwd)[a-z0-9_-]*|sig|auth|key)\s*["']?\s*[:=]|\b(?:Bearer|Basic)\s+\S+|\beyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+\b"#
    )
    private static let frameNoise = try! NSRegularExpression(
        pattern: #"(?i)\b(?:frame\s+(?:pts|time|\d)|pts\s*[:=]|draw(?:ing)?\s+frame|render(?:ing)?\s+frame|vsync|video\s+pts)"#
    )
}
