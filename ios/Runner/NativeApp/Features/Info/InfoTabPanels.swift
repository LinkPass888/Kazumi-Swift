//
//  InfoTabPanels.swift
//  Kazumi
//
//  详情页「概览 / 吐槽 / 角色 / 关联 / 制作人员」五个标签的内容面板，
//  对应原版 lib/pages/info/info_tabview.dart 与 info_comments_view.dart：
//    * 概览     —— 简介（超过 7 行折叠）+ 标签；标签可点进搜索；
//    * 吐槽     —— 顶部输入框 + 列表；输入框的占位就是原版的「下面我简单喵两句」；
//    * 角色     —— 圆头像（取景偏上，露头）、角色名右侧是主角/配角；
//    * 关联     —— 只显示动画，关系名是遍历出来的前传 / 续集（见 RelatedAnimeChain）；
//    * 制作人员 —— 左侧头像 + 姓名 + 中文名 + 职务。
//
//  标题一律左对齐、28pt 粗体，与推荐页的「热门番组」同一套字重字号。
//

import SwiftUI
import UIKit

/// 详情页标签。与原版 info_page.dart 的 _infoTabs 逐条一致。
enum InfoTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case comments
    case characters
    case relations
    case staff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "概览")
        case .comments: String(localized: "吐槽")
        case .characters: String(localized: "角色")
        case .relations: "关联"
        case .staff: String(localized: "制作人员")
        }
    }
}

/// 详情页里的区块标题：左对齐，字号字重与「热门番组」一致。
struct InfoSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 面板里的空态 / 加载态。
struct InfoPanelPlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

// MARK: - 概览

/// 概览面板：简介 + 标签（对应 info_tabview.dart 的 infoBody）。
struct InfoOverviewPanel: View {
    let item: BangumiItem

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var introExpanded = false
    @State private var tagsExpanded = false
    /// 简介完整高度的测量值，用来判断要不要给「加载更多」。
    @State private var fullIntroHeight: CGFloat = 0

    /// 原版固定折叠到 7 行。
    private static let collapsedLines = 7
    /// 原版标签最多先铺 13 个（第 13 个换成「更多 +」）。
    private static let collapsedTags = 12

    private var summary: String {
        let text = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "暂无简介") : text
    }

    private var needsCollapse: Bool {
        guard fullIntroHeight > 0 else { return summary.count > 180 }
        return fullIntroHeight > Self.lineHeight * CGFloat(Self.collapsedLines) + 1
    }

    private static var lineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .callout).lineHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InfoSectionTitle(text: String(localized: "简介"))
            intro
            InfoSectionTitle(text: String(localized: "标签"))
                .padding(.top, 8)
            tags
        }
    }
}

extension InfoOverviewPanel {
    /// 简介：超过 7 行折叠，末尾给「加载更多 / 加载更少」。
    @ViewBuilder
    private var intro: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(summary == String(localized: "暂无简介") ? .secondary : .primary)
                .lineLimit(introExpanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { measuringText }

            if needsCollapse {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { introExpanded.toggle() }
                } label: {
                    Text(introExpanded ? "加载更少" : "加载更多")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .onPreferenceChange(IntroHeightKey.self) { height in
            fullIntroHeight = height
        }
    }

    /// 隐藏的一份全文，只用来量高度（不受 lineLimit 影响）。
    private var measuringText: some View {
        Text(summary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: IntroHeightKey.self, value: proxy.size.height)
                }
            }
    }

    /// 标签：原版用 Wrap；这里用 TagFlowLayout 按每颗标签自己的文字宽度流式换行，
    /// 一行放几颗由可用宽度算出来，不预设列宽。
    @ViewBuilder
    private var tags: some View {
        if item.tags.isEmpty {
            Text("暂无标签")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            TagFlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(visibleTags, id: \.name) { tag in
                    tagChip(tag)
                }
                if canExpandTags {
                    moreTagChip
                }
            }
        }
    }

    private var canExpandTags: Bool {
        !tagsExpanded && item.tags.count >= Self.collapsedTags + 1
    }

    private var visibleTags: [BangumiTag] {
        if canExpandTags { return Array(item.tags.prefix(Self.collapsedTags)) }
        return item.tags
    }

    private func tagChip(_ tag: BangumiTag) -> some View {
        Button {
            router.push(.search(keyword: tag.name))
        } label: {
            HStack(spacing: 4) {
                Text(tag.name)
                    .foregroundStyle(.primary)
                    // 文字一个都不许少：正常仍是单行（布局按理想宽度给它），
                    // 只有单颗比整行还宽时才在胶囊里折行，绝不出现省略号。
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if tag.count > 0 {
                    Text("\(tag.count)")
                        .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                }
            }
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var moreTagChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { tagsExpanded = true }
        } label: {
            Text("更多 +")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(KazumiPalette.accent(for: colorScheme).opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct IntroHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 按文字宽度流式换行：每颗标签的宽度由它自己的文字定，一行放几颗由可用宽度算出来。
///
/// 替换掉原来的 `GridItem(.adaptive(minimum: 84))`：那种排法先按 84 点切等宽列、
/// 再让每颗胶囊拉满列宽，于是短标签被撑开、长标签被挤，一行几颗也由列数决定。
/// 与它配套的是胶囊里那句 `frame(maxWidth: .infinity)`——那句必须一起删掉。
///
/// 全 App 只服务概览页标签这一处；行号会动，按字面搜 `InfoOverviewPanel`。
private struct TagFlowLayout: Layout {
    /// 同一行两颗之间。
    var spacing: CGFloat = 8
    /// 两行之间。
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let ideal = sub.sizeThatFits(.unspecified)
            // 单颗宽过整行时按整行宽算，交给胶囊内部折行。
            let width = min(ideal.width, maxWidth)
            if x > 0, x + spacing + width > maxWidth {
                widest = max(widest, x)
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            } else if x > 0 {
                x += spacing
            }
            x += width
            rowHeight = max(rowHeight, ideal.height)
        }
        widest = max(widest, x)
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let ideal = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + ideal.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            } else if x > bounds.minX {
                x += spacing
            }
            // 右边界内收住，不越界。
            let width = min(ideal.width, bounds.maxX - x)
            let proposal = ProposedViewSize(width: width, height: nil)
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: proposal)
            x += width
            rowHeight = max(rowHeight, sub.sizeThatFits(proposal).height)
        }
    }
}

// MARK: - 吐槽

/// 吐槽面板：对应 info_comments_view.dart。
///
/// 顶部是一个输入框，占位文字就是原版的「下面我简单喵两句」——输入后占位自动
/// 消失，右侧是发送按钮；发表走 Bangumi 收藏评价接口（吐槽本身就是收藏评论）。
struct InfoCommentsPanel: View {
    let comments: [BangumiCommentItem]
    let total: Int
    let isLoading: Bool
    let isPosting: Bool
    /// 「发送」回调。发表要碰 Bangumi 接口与控制器状态，因此固定在主线程执行。
    var onSend: @MainActor (String) async -> Bool
    /// 展开某条评论的回复时喊一声，把列表滚一滚（Colo 3366）。
    var onExpandComment: ((String) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @State private var errorText: String?
    @State private var isSending = false
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isPosting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            composer

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if isLoading && comments.isEmpty {
                InfoPanelPlaceholder(symbol: "ellipsis.bubble", text: String(localized: "正在加载吐槽…"))
            } else if comments.isEmpty {
                InfoPanelPlaceholder(symbol: "text.bubble", text: String(localized: "还没有人吐槽这部番"))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        CommentRowView(
                            comment: comment,
                            showsDate: true,
                            score: comment.rate > 0 ? comment.rate : nil,
                            onExpand: { onExpandComment?(comment.id) }
                        )
                        // 上下各 10、行距 0：跟播放器那版评论一样，靠 padding 撑开（Colo 6149）。
                        .padding(.vertical, 10)
                        .id(comment.id)
                        Divider()
                    }
                    if total > comments.count {
                        Text(String(localized: "已显示 \(comments.count) / \(total) 条"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: 输入

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("下面我简单喵两句", text: $draft, axis: .vertical)
                .focused($isFocused)
                .font(.callout)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    KazumiPalette.cardShape(cornerRadius: 20, scheme: colorScheme)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Group {
                    if isSending || isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 40, height: 40)
                .foregroundStyle(.white)
                .background(
                    Circle().fill(
                        canSend ? KazumiPalette.accent(for: colorScheme) : Color.secondary.opacity(0.3)
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("发送吐槽")
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        errorText = nil
        Task {
            let ok = await onSend(text)
            isSending = false
            if ok {
                draft = ""
                isFocused = false
            } else {
                errorText = String(localized: "发送失败：请先在「我的」里登录 Bangumi 后再试。")
            }
        }
    }

    // MARK: 单条

}

// MARK: - 角色

/// 角色面板：对应 character_card.dart 的 CharacterCard。
///
/// 与原版的差别：头像取景偏上（露出头部而不是从额头裁开），
/// 角色定位（主角 / 配角）挪到角色名右侧，头像和行高一起收窄。
struct InfoCharactersPanel: View {
    let characters: [BangumiCharacterItem]
    let isLoading: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isLoading && characters.isEmpty {
            InfoPanelPlaceholder(symbol: "person.2", text: String(localized: "正在加载角色…"))
        } else if characters.isEmpty {
            InfoPanelPlaceholder(symbol: "person.2", text: String(localized: "暂无角色信息"))
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(characters) { character in
                    row(character)
                    Divider().padding(.leading, 50)
                }
            }
        }
    }

    private func row(_ character: BangumiCharacterItem) -> some View {
        HStack(spacing: 10) {
            KazumiAvatar(url: character.largeImage, size: 40, focus: 0.15)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(character.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !character.relation.isEmpty {
                        Text(character.relation)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(KazumiPalette.accent(for: colorScheme).opacity(0.14))
                            )
                    }
                    Spacer(minLength: 0)
                }

                if let actor = character.actors.first, !actor.name.isEmpty {
                    Text(actor.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}


// MARK: - 关联

/// 关联面板：对应 info_tabview.dart 的 _RelatedBangumiCardH。
/// 数据已经在 RelatedAnimeChain 里筛成「只有动画 + 前传 / 续集」，这里只负责画。
struct InfoRelationsPanel: View {
    let relations: [BangumiRelationItem]
    let isLoading: Bool
    /// 关联卡片 → 关联条目详情页的缩放转场命名空间（沿用当前导航栈的那一份）。
    var zoomNamespace: Namespace.ID?

    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isLoading && relations.isEmpty {
            InfoPanelPlaceholder(symbol: "square.stack", text: String(localized: "正在加载关联条目…"))
        } else if relations.isEmpty {
            InfoPanelPlaceholder(symbol: "square.stack", text: String(localized: "暂无关联条目"))
        } else {
            LazyVStack(spacing: 8) {
                ForEach(relations) { relation in
                    Button {
                        router.push(.bangumiInfo(bangumiID: relation.item.id))
                    } label: {
                        card(relation)
                    }
                    .buttonStyle(.plain)
                    // 关联条目也能从卡片放大进入，ID 用被点的那一条，不会和当前页撞号。
                    .kazumiZoomSource(id: relation.item.id, namespace: zoomNamespace)
                }
            }
        }
    }

    private func card(_ relation: BangumiRelationItem) -> some View {
        HStack(spacing: 10) {
            BangumiRemoteImage(url: relation.item.largeImage)
                .frame(width: 60, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(relation.item.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(relation.relation.isEmpty ? "关联" : relation.relation)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            KazumiPalette.cardShape(cornerRadius: 16, scheme: colorScheme)
        )
    }
}

// MARK: - 制作人员

/// 制作人员面板：对应 staff_card.dart 的 StaffCard（左侧头像）。
struct InfoStaffPanel: View {
    let staff: [BangumiStaffItem]
    let isLoading: Bool

    var body: some View {
        if isLoading && staff.isEmpty {
            InfoPanelPlaceholder(symbol: "person.text.rectangle", text: String(localized: "正在加载制作人员…"))
        } else if staff.isEmpty {
            InfoPanelPlaceholder(symbol: "person.text.rectangle", text: String(localized: "暂无制作人员信息"))
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(staff) { member in
                    row(member)
                    Divider().padding(.leading, 50)
                }
            }
        }
    }

    private func row(_ member: BangumiStaffItem) -> some View {
        HStack(spacing: 10) {
            KazumiAvatar(url: member.avatarURL, size: 40, focus: 0.15)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !member.nameCN.isEmpty {
                    Text(member.nameCN)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(member.primaryRelation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}

