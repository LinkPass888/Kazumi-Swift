//
//  HLSPlaylist.swift
//  Kazumi
//
//  下载要的那点 HLS 解析：从主列表挑一条子列表，把媒体列表里的分片地址一条条换成
//  本地文件名，原样保留 `#EXTINF`、`#EXT-X-DISCONTINUITY` 这些标签。
//
//  为什么不自己重新生成播放列表：原始列表里的时长、断点标记、初始化段都是播放器
//  需要的，照着改地址最省事，也不会漏标签。加密（`#EXT-X-KEY` 且不是 NONE）
//  解不了，早点报出来，别下到一半才炸。
//

import Foundation

enum HLSPlaylist {
    /// 主列表里码率最高的那条子列表地址。
    static func bestVariant(from text: String, baseURL: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = bandwidth(from: line)
                continue
            }
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            guard let url = resolve(line, against: baseURL) else { continue }
            if best == nil || pendingBandwidth > best!.bandwidth {
                best = (pendingBandwidth, url)
            }
            pendingBandwidth = 0
        }
        return best?.url
    }

    /// 一条媒体列表改成本地版：分片换成 `前缀-seg-00000.ts`。
    struct LocalPlan {
        /// 要下的分片地址。
        var segmentURLs: [URL]
        /// 对应的本地文件名，与 `segmentURLs` 一一对应。
        var segmentFileNames: [String]
        /// 初始化段（fMP4）。
        var initURL: URL?
        /// 初始化段的本地文件名。
        var initFileName: String?
        /// 已经把地址换成文件名的那些行，按原顺序。
        private var lines: [String]

        init(
            segmentURLs: [URL],
            segmentFileNames: [String],
            initURL: URL?,
            initFileName: String?,
            lines: [String]
        ) {
            self.segmentURLs = segmentURLs
            self.segmentFileNames = segmentFileNames
            self.initURL = initURL
            self.initFileName = initFileName
            self.lines = lines
        }

        /// 拼出本地播放列表的正文。`initName` 传 nil 表示没有初始化段。
        func render(initName: String?) -> String {
            var output: [String] = []
            for line in lines {
                if line == Self.initPlaceholder, let initName {
                    output.append("#EXT-X-MAP:URI=\"\(initName)\"")
                } else if line == Self.initPlaceholder {
                    // 原本有初始化段但没下下来：删掉这行，别留个指向空气的地址。
                    continue
                } else {
                    output.append(line)
                }
            }
            return output.joined(separator: "\n") + "\n"
        }

        fileprivate static let initPlaceholder = "__KAZUMI_INIT__"
    }

    /// 解析媒体列表，把分片地址换成本地文件名。
    ///
    /// - Parameters:
    ///   - text: 媒体列表正文。
    ///   - baseURL: 列表自己的地址，相对分片靠它补全。
    ///   - prefix: 文件名前缀（`ep-3`），一集内互不冲突。
    static func localPlan(from text: String, baseURL: URL, prefix: String = "seg") throws -> LocalPlan {
        var segmentURLs: [URL] = []
        var segmentFileNames: [String] = []
        var initURL: URL?
        var initFileName: String?
        var lines: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 加密的先拦下来。
            if line.hasPrefix("#EXT-X-KEY") {
                let method = attribute("METHOD", in: line) ?? ""
                if !method.isEmpty, method != "NONE" {
                    throw DownloadEngineError.encrypted
                }
                lines.append(line)
                continue
            }

            if line.hasPrefix("#EXT-X-MAP") {
                if let uri = attribute("URI", in: line), let url = resolve(uri, against: baseURL) {
                    if let existing = initURL, existing != url {
                        throw DownloadEngineError.multipleInitSegments
                    }
                    initURL = url
                    let name = "\(prefix)-init.mp4"
                    initFileName = name
                    lines.append(LocalPlan.initPlaceholder)
                }
                continue
            }

            guard !line.hasPrefix("#"), !line.isEmpty else {
                lines.append(line)
                continue
            }

            guard let url = resolve(line, against: baseURL) else {
                lines.append(line)
                continue
            }
            let name = "\(prefix)-seg-\(String(format: "%05d", segmentURLs.count)).ts"
            segmentURLs.append(url)
            segmentFileNames.append(name)
            lines.append(name)
        }

        return LocalPlan(
            segmentURLs: segmentURLs,
            segmentFileNames: segmentFileNames,
            initURL: initURL,
            initFileName: initFileName,
            lines: lines
        )
    }

    // MARK: - 小工具

    private static func bandwidth(from line: String) -> Int {
        guard let value = attribute("BANDWIDTH", in: line) else { return 0 }
        return Int(value) ?? 0
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        var value = String(line[range.upperBound...])
        // 值可能被引号包着，后面还可能跟着逗号分隔的其它属性。
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let closing = value.firstIndex(of: "\"") {
                return String(value[..<closing])
            }
            return value
        }
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// 相对地址按播放列表自己的位置补全（分片常是相对路径）。
    private static func resolve(_ raw: String, against base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}
