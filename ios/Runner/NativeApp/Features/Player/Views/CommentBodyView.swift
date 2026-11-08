//
//  CommentBodyView.swift
//  Kazumi
//
//  评论正文：文字照常排，带的图一张一行竖着排（LP 3321 / Colo 3322）。
//
//  Bgm.tv 的评论里图片是 BBCode：`[img]https://…[/img]`。原版直接把整段丢给
//  Markdown 渲染，图片就出来了；我们这边只当纯文字，于是图片地址会当成字显示出来。
//  这里先把正文拆成「文字段 / 图片段」，再按原来的先后顺序排下去 —— 图后面的文字
//  还得在图后面，不能一股脑堆到底下（LP 3308）。
//
//  表情同理：Bgm 的表情是 `(bgm38)` 这种码，对应 bgm.tv 的小图，内联在文字里。
//

import SwiftUI
import UIKit

struct CommentBodyView: View {
    let text: String

    /// 点开的图。为空表示没在看大图。
    @State private var viewer: CommentImageViewerTarget?
    /// 这一块的宽度，图片按它算高。
    @State private var contentWidth: CGFloat = 0

    private var blocks: [CommentBlock] {
        CommentBlock.blocks(from: CommentSegment.parse(text))
    }

    private var images: [String] {
        blocks.flatMap { block in
            if case .images(let urls) = block { return urls }
            return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    CommentRichText(text: value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .images(let urls):
                    VStack(spacing: 4) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                            CommentImageRow(url: url, width: contentWidth)
                                .onTapGesture {
                                    viewer = CommentImageViewerTarget(index: index(of: url))
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(String(localized: "查看第 \(String(describing: index(of: url) + 1)) 张图片"))
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newValue in
            contentWidth = newValue
        }
        .environment(\.openURL, OpenURLAction { url in
            // 评论里的链接按 LP 的规矩走外部浏览器，不在 App 里开网页。
            UIApplication.shared.open(url)
            return .handled
        })
        .fullScreenCover(item: $viewer) { target in
            CommentImageViewer(urls: images, startIndex: target.index)
        }
    }

    /// 整条评论里的第几张 —— 大图翻页按这个走。
    private func index(of url: String) -> Int {
        images.firstIndex(of: url) ?? 0
    }
}

/// 评论里的一张图：一行一张，按内容宽度铺满，高度按图片比例算、最高 200，圆角 8。
/// 加载中和失败都是同尺寸的灰块，行高不会跳（规格 §9）。
private struct CommentImageRow: View {
    let url: String
    /// 外层量到的宽度；还没量到时按 200 高先占位。
    let width: CGFloat

    @State private var image: UIImage?
    @State private var failed = false

    private var ratio: CGFloat {
        guard let image, image.size.height > 0 else { return 0 }
        return image.size.width / image.size.height
    }

    private var height: CGFloat {
        guard width > 0, ratio > 0 else { return 200 }
        return min(width / ratio, 200)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quinary)
            }
        }
        .frame(width: width > 0 ? width : nil, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            guard image == nil, !failed else { return }
            let target = CGSize(width: 900, height: 900)
            let pixelSize = KazumiImageLoader.pixelSize(for: target)
            let ok = await KazumiImageLoader.shared.load(url, pixelSize: pixelSize)
            let loaded = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixelSize)
            if ok, let loaded {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// 一段正文：文字、表情、以及 Bgm 的 BBCode 标记混排。
///
/// 评论里除了 `[img]`，还有 `[color=grey]`、`[size=10]`、`[url=…]文字[/url]`、
/// `[* 文字]` 这些写法，原版是按 Markdown 渲染的。不解析就会把标记原样露出来
/// （LP 3326 贴的那条）。规则（Colo 3327 / 3366）：
/// * `[color=grey]` 次要灰、`[size=10]` 小字；
/// * `[url=地址]文字[/url]` 是可点的链接，文字照抄标记里给的那份，点开设外部浏览器；
/// * `[url=地址]` 后面直接跟别的标记 ＝ 没带文字：链接挂到前面那条**标记给出来的**内容上
///   （`[* Bangumi for android]` 那行，只那一行是链接），里面包着的字（「获取」「#X」这种）整段不显示；
/// * `[* 文字]` 是列表项，前面一个圆点；
/// * 不认识的、写错没闭合的标记一律吞掉，只留里面的文字，不许露标记字。
private struct CommentRichText: View {
    let text: String

    @State private var frames: [String: [UIImage]] = [:]
    /// 动态表情按帧换图用；每 100ms 加一。
    @State private var tick = 0

    private var runs: [CommentMarkup.Run] {
        CommentMarkup.runs(text)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var codes: [String] {
        runs.flatMap { run in
            CommentToken.parse(run.text).compactMap { token in
                if case .emoticon(let code) = token { return code }
                return nil
            }
        }
    }

    var body: some View {
        composed
            .fixedSize(horizontal: false, vertical: true)
            .task(id: codes.joined(separator: ",")) {
                await loadEmoticons()
            }
            .task {
                await animateEmoticons()
            }
    }

    private var composed: Text {
        // 链接的可点性很挑：整段必须是一个 AttributedString、外层不能再加 `.font()`，
        // 否则链接点不动（LP 3361）。所以没有表情的段落走整段那版；
        // 有表情的才拼接（表情只能用 Text(Image) 拼），字号在外层给。
        if codes.isEmpty {
            return Text(wholeParagraph)
        }
        var result = Text("")
        for run in runs {
            for token in CommentToken.parse(run.text) {
                switch token {
                case .text(let value):
                    // iOS 26 弃用了 `Text + Text`，改用插值拼接（各段样式照旧各自保留）。
                    result = Text("\(result)\(styled(value, run.style))")
                case .emoticon(let code):
                    // 还没拿到就当没有：不把 (bgm38) 这种码当字显示出来，也不留空档。
                    guard let list = frames[code], !list.isEmpty else { continue }
                    let image = list[tick % list.count]
                    result = Text("\(result)\(Text(Image(uiImage: image)).baselineOffset(-2))")
                }
            }
        }
        return result.font(.subheadline)
    }

    /// 整段文字做成一个 AttributedString：链接、颜色、字号都在属性上。
    ///
    /// 基础字号必须写在属性里，外层不能再 `.font(.subheadline)`：一加，链接就点不动
    /// （LP 3361，详情页那条「Bangumi for android」）。
    private var wholeParagraph: AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            part.font = .system(size: run.style.size ?? 15)
            if let link = run.style.link {
                part.link = link
                // 链接一律主题色，看得出能点（Colo 3344）。
                part.foregroundColor = KazumiPalette.accent(for: colorScheme)
            } else if let color = run.style.color {
                part.foregroundColor = color
            }
            result.append(part)
        }
        return result
    }

    private func styled(_ value: String, _ style: CommentMarkup.Style) -> Text {
        if let link = style.link {
            var attributed = AttributedString(value)
            attributed.link = link
            // 链接用主题色，看得出能点；不加下划线（Colo 3329 / 3343）。
            attributed.foregroundColor = KazumiPalette.accent(for: colorScheme)
            attributed.underlineStyle = nil
            if let size = style.size { attributed.font = .system(size: size) }
            return Text(attributed)
        }
        var piece = Text(value)
        if let color = style.color { piece = piece.foregroundColor(color) }
        if let size = style.size { piece = piece.font(.system(size: size)) }
        return piece
    }

    private func loadEmoticons() async {
        for code in codes where frames[code] == nil {
            let list = await EmoticonStore.frames(for: code)
            guard !list.isEmpty else { continue }
            frames[code] = list
        }
    }

    /// 有动态表情在屏上才按帧刷，静态表情不动，省得白白重画。
    private func animateEmoticons() async {
        while !Task.isCancelled {
            let animated = frames.values.contains { $0.count > 1 }
            if animated { tick &+= 1 }
            try? await Task.sleep(for: .milliseconds(animated ? 100 : 800))
        }
    }
}

/// 表情图：一次取回、解成每一帧、缩到正文那行字的高度，之后都走缓存。
/// 动态表情（`musume_67` 这种）必须真动，所以留的是帧列表，不是一张静图。
@MainActor
enum EmoticonStore {
    private static var cache: [String: [UIImage]] = [:]

    static func frames(for code: String) async -> [UIImage] {
        if let hit = cache[code] { return hit }
        guard let text = CommentToken.emoticonURL(for: code), let url = URL(string: text) else {
            return []
        }
        guard let (data, _) = try? await KazumiNetworkPolicy.requestSession.session.data(from: url) else { return [] }
        let images = decode(data)
        if !images.isEmpty { cache[code] = images }
        return images
    }

    /// 按 GIF 的每一帧解开；不是动图就是一张。
    private static func decode(_ data: Data) -> [UIImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        var images: [UIImage] = []
        for index in 0 ..< max(count, 1) {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(scaled(UIImage(cgImage: cgImage)))
        }
        if images.isEmpty, let single = UIImage(data: data) {
            images = [scaled(single)]
        }
        return images
    }

    /// 表情原图大小不一，统一缩到跟正文那行字差不多高，排进去才齐。
    private static func scaled(_ image: UIImage) -> UIImage {
        let targetHeight: CGFloat = 18
        guard image.size.height > 0 else { return image }
        let scale = targetHeight / image.size.height
        let size = CGSize(width: max(image.size.width * scale, 1), height: targetHeight)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Bgm 评论里的 BBCode：拆成「文字 + 样式」若干段。
enum CommentMarkup {
    struct Style: Equatable {
        var color: Color?
        var size: CGFloat?
        var link: URL?
    }

    struct Run: Equatable {
        var text: String
        var style: Style
        /// 这段字是不是某个 `[…]` 标记给出来的（现在只有 `[* 文字]`）。
        /// 没带文字的链接只挂到这种段上，不能去挂普通正文 ——
        /// 挂了就会把整条评论变成链接（LP 3397 / Colo 3401）。
        var fromMark = false
    }

    static func runs(_ raw: String) -> [Run] {
        guard !raw.isEmpty else { return [] }
        var runs: [Run] = []
        var current = Style()
        var stack: [Style] = []
        var buffer = ""
        var index = raw.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(Run(text: buffer, style: current))
            buffer = ""
        }

        /// `[url=地址]` 后面跟的是不是文字：跟着别的标记（或者到头了）就是没带文字。
        func carriesText(after close: String.Index) -> Bool {
            var probe = close
            while probe < raw.endIndex, raw[probe].isWhitespace { probe = raw.index(after: probe) }
            return probe < raw.endIndex && raw[probe] != "["
        }

        /// 没带文字的链接：挂到前面那条**标记给出来的**内容上（`[* Bangumi for android]` 那行）；
        /// 找不到才用域名＋路径。不能挂到普通正文上（会把整条评论变成链接，LP 3397）。
        func attachLink(_ address: URL?) {
            guard let address else { return }
            if let index = runs.lastIndex(where: { $0.fromMark && $0.style.link == nil }) {
                runs[index].style.link = address
            } else {
                runs.append(Run(text: addressText(address), style: Style(link: address)))
            }
        }

        while index < raw.endIndex {
            let character = raw[index]
            guard character == "[", let close = raw[index...].firstIndex(of: "]") else {
                buffer.append(character)
                index = raw.index(after: index)
                continue
            }

            let content = String(raw[raw.index(after: index) ..< close])
            let lowered = content.lowercased()
            let afterClose = raw.index(after: close)
            // Markdown 链接 `[文字](地址)` 单独认一次（LP 3361）：评论里也这么写，
            // 不认的话方括号里的字会被当成不认识的标记吞掉，只剩个地址在屏上。
            let markdownLink = afterClose < raw.endIndex
                && raw[afterClose] == "("
                ? raw[afterClose...].firstIndex(of: ")").map { paren in
                    (String(raw[raw.index(after: afterClose)..<paren]), raw.index(after: paren))
                }
                : nil

            if lowered.hasPrefix("color=") {
                flush()
                stack.append(current)
                current.color = color(named: String(content.dropFirst(6)))
            } else if lowered.hasPrefix("size=") {
                flush()
                stack.append(current)
                current.size = size(from: String(content.dropFirst(5)))
            } else if lowered.hasPrefix("url=") {
                let address = url(from: String(content.dropFirst(4)))
                if carriesText(after: afterClose) {
                    flush()
                    stack.append(current)
                    current.link = address
                } else {
                    // 标记后面直接是别的标记：这个链接没带文字。链接挂到前面那条内容上，
                    // 里面包着的那段字整段不显示——「获取」「#X」这种兜底字一律不许露面
                    // （Colo 3366 / 3390）。
                    flush()
                    attachLink(address)
                    index = Self.skipLinkBody(raw, from: afterClose)
                }
            } else if lowered.hasPrefix("/") {
                // 收尾标记：不管写没写对（`[/ur|]` 这种）都只把样式退一层。
                flush()
                current = stack.popLast() ?? Style()
            } else if let (address, next) = markdownLink {
                flush()
                stack.append(current)
                current.link = url(from: address)
                buffer += content
                flush()
                current = stack.popLast() ?? Style()
                index = next
            } else if content.hasPrefix("*") {
                flush()
                let rest = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                buffer += "• "
                buffer += rest
                flush()
                // 标出来：没带文字的链接只挂到这种段上。
                if let index = runs.indices.last { runs[index].fromMark = true }
            } else if looksLikeText(content) {
                // `[来自Bangumi for android]` 这种根本不是标记，是客户端塞的一句话
                // （Bgm 安卓端每条评论尾巴上都有）。原版当文字排，后面的链接也挂在它上面：
                // `[url=…][color=grey]获取[/color][/url]` 里那个「获取」不显示，
                // 链接文字就是这句（LP 3407 / Colo 3410）。
                flush()
                buffer += content
                flush()
                if let index = runs.indices.last { runs[index].fromMark = true }
            } else {
                // 不认识的标记（含残留的 `[img]`）整段吞掉，文字照排。
                flush()
            }
            // 上面几个分支（Markdown 链接、没带文字的链接）已经自己把 index 推过去了，
            // 这里只推「刚认完的这个标记」。
            if index <= close {
                index = raw.index(after: close)
            }
        }

        flush()
        return runs.map { run in
            guard let link = run.style.link else { return run }
            var fixed = run
            fixed.text = displayText(for: run.text, link: link)
            return fixed
        }
    }

    /// 方括号里不像标记、像一句话的：`[来自Bangumi for android]` 这种。
    /// 带空格或者有中文就当文字排；`[/color]`、`[color=grey]`、`[quote]` 这些照旧吞掉。
    private static func looksLikeText(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("=") || trimmed.hasPrefix("/") { return false }
        if trimmed.contains(where: { $0.isWhitespace }) { return true }
        return trimmed.contains { !$0.isASCII }
    }

    /// 跳过「没带文字的链接」里包着的那段内容，返回收尾标记之后的位置。
    /// 收尾标记写错也认（`[/ur|]` 这种）：名字以 `ur` 开头的收尾标记都算。
    private static func skipLinkBody(_ raw: String, from start: String.Index) -> String.Index {
        var probe = start
        while probe < raw.endIndex {
            guard raw[probe] == "[", let close = raw[probe...].firstIndex(of: "]") else {
                probe = raw.index(after: probe)
                continue
            }
            let content = String(raw[raw.index(after: probe) ..< close]).lowercased()
            if content.hasPrefix("/"), content.dropFirst().hasPrefix("ur") {
                return raw.index(after: close)
            }
            probe = raw.index(after: close)
        }
        // 找不到收尾标记：剩下的别吞，当普通文字排下去。
        return start
    }

    /// 链接文字照抄标记里给的那份（Colo 3366）；压根没带文字的才换成域名＋路径。
    private static func displayText(for label: String, link: URL) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? addressText(link) : label
    }

    /// `https://bgm.tv/group/topic/350677` → `bgm.tv/group/topic/350677`
    private static func addressText(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        return text
    }

    private static func color(named name: String) -> Color? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "grey", "gray": return .secondary
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "teal": return .teal
        case "navy": return .indigo
        case "black": return .primary
        case "white": return .white
        default: return hexColor(name)
        }
    }

    /// `[color=#A0A0A0]` 这种写法。
    private static func hexColor(_ raw: String) -> Color? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#"), text.count == 7 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(text.dropFirst())).scanHexInt64(&value) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 字号按点算，太小太大都收一收，免得一行里蹦出个巨字。
    private static func size(from raw: String) -> CGFloat? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(max(CGFloat(value), 9), 17)
    }

    private static func url(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil { return url }
        return URL(string: "https://bgm.tv/\(text)")
    }
}

/// 正文里的一小段：文字，或者一个表情码。
enum CommentToken: Hashable {
    case text(String)
    case emoticon(String)

    /// 两种表情码（Colo 3333）：
    /// * `bgm38` 这种静态小图，在 `/img/smiles/tv/38.gif`；
    /// * `musume_67` 这种动态表情，在 `/img/smiles/musume/musume_67.gif`。
    static func emoticonURL(for code: String) -> String? {
        let lowered = code.lowercased()
        if lowered.hasPrefix("bgm") {
            let digits = String(lowered.dropFirst(3))
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            return "https://bgm.tv/img/smiles/tv/\(digits).gif"
        }
        if lowered.hasPrefix("musume_") {
            let digits = String(lowered.dropFirst(7))
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            return "https://bgm.tv/img/smiles/musume/\(lowered).gif"
        }
        return nil
    }

    /// 按 `(bgm38)` 切开；其余照原样。
    static func parse(_ raw: String) -> [CommentToken] {
        guard !raw.isEmpty else { return [] }
        var tokens: [CommentToken] = []
        var rest = Substring(raw)

        while let open = rest.firstIndex(of: "(") {
            let before = rest[rest.startIndex ..< open]
            if !before.isEmpty { tokens.append(.text(String(before))) }
            guard let close = rest[open...].firstIndex(of: ")") else {
                tokens.append(.text(String(rest[open...])))
                return tokens
            }
            let code = String(rest[rest.index(after: open) ..< close])
            if emoticonURL(for: code) != nil {
                tokens.append(.emoticon(code))
            } else {
                // 不是表情就把括号原样留着。
                tokens.append(.text(String(rest[open ... close])))
            }
            rest = rest[rest.index(after: close)...]
        }

        if !rest.isEmpty { tokens.append(.text(String(rest))) }
        return tokens
    }
}

/// 排下去的一格：一段文字，或者连着的一串图。
enum CommentBlock: Hashable {
    case text(String)
    case images([String])

    /// 把段落按原顺序收成块：相邻的文字并成一段，相邻的图并成一组。
    static func blocks(from segments: [CommentSegment]) -> [CommentBlock] {
        var blocks: [CommentBlock] = []
        var pendingText = ""
        var pendingImages: [String] = []

        func flushText() {
            let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
            pendingText = ""
        }
        func flushImages() {
            if !pendingImages.isEmpty { blocks.append(.images(pendingImages)) }
            pendingImages = []
        }

        for segment in segments {
            switch segment {
            case .text(let value):
                flushImages()
                pendingText += value
            case .image(let url):
                flushText()
                pendingImages.append(url)
            }
        }
        flushText()
        flushImages()
        return blocks
    }
}

/// 拆开后的正文：一段文字或一张图。
enum CommentSegment: Hashable {
    case text(String)
    case image(String)

    /// 按 `[img]…[/img]` 切；没有图就是一整段文字。
    static func parse(_ raw: String) -> [CommentSegment] {
        guard !raw.isEmpty else { return [] }
        var segments: [CommentSegment] = []
        var rest = Substring(raw)

        while let openRange = rest.range(of: "[img", options: .caseInsensitive) {
            let before = rest[rest.startIndex ..< openRange.lowerBound]
            if !before.isEmpty {
                segments.append(.text(String(before)))
            }
            // 开标签可能带参数（`[img width=…]`），到 `]` 为止都算标签。
            guard let openEnd = rest[openRange.lowerBound...].firstIndex(of: "]") else {
                segments.append(.text(String(rest[openRange.lowerBound...])))
                return segments
            }
            let afterOpen = rest.index(after: openEnd)
            guard let closeRange = rest.range(of: "[/img]", options: .caseInsensitive, range: afterOpen ..< rest.endIndex) else {
                // 没有收尾标签：剩下的当文字，别把地址漏出去。
                segments.append(.text(String(rest[afterOpen...])))
                return segments
            }
            let url = rest[afterOpen ..< closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                segments.append(.image(url))
            }
            rest = rest[closeRange.upperBound...]
        }

        if !rest.isEmpty {
            segments.append(.text(String(rest)))
        }
        return segments
    }
}

struct CommentImageViewerTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

/// 看大图：能捏合缩放、能左右滑。
private struct CommentImageViewer: View {
    let urls: [String]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(urls: [String], startIndex: Int) {
        self.urls = urls
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    ZoomableImage(url: url)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .padding(.trailing, 12)
            .padding(.top, 8)

            if urls.count > 1 {
                Text("\(selection + 1) / \(urls.count)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
            }
        }
        .statusBarHidden()
    }
}

/// 单张大图：双击或捏合缩放，放大后可以拖。
private struct ZoomableImage: View {
    let url: String

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 4

    var body: some View {
        BangumiRemoteImage(url: url, contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(committedScale * value, 1), maxScale)
                    }
                    .onEnded { _ in
                        committedScale = scale
                        if scale <= 1 {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scale = 1
                                committedScale = 1
                                offset = .zero
                                committedOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        committedOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1 {
                        scale = 1
                        committedScale = 1
                        offset = .zero
                        committedOffset = .zero
                    } else {
                        scale = 2.5
                        committedScale = 2.5
                    }
                }
            }
    }
}
