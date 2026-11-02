//
//  SyncProgressDialog.swift
//  Kazumi
//
//  同步进度弹窗（Colo 2026-10-28）：Bangumi 和 WebDAV 两套同步共用一张。
//
//  以前进度是设置页里的一行字加一条细进度条，跟着页面滚动、还会把下面的行挤下去。
//  现在改成居中的卡片：宽 280、圆角 16、不透明浅色底（跟菜单一样，不用玻璃），
//  标题「正在同步」，下面一行写当前阶段，再下面一条 6 高的圆头进度条和右侧百分比。
//  同步期间不能关，点卡片外面也没反应；成功停 0.5 秒自己收，失败留着并给一颗「关闭」。
//

import SwiftUI

struct SyncProgressDialog: View {
    /// 卡片标题，两套同步都写「正在同步」。
    var title = String(localized: "正在同步")
    /// 当前阶段：「下载收藏…」「合并…」「上传…」。
    var stage: String
    /// 0…1；没有总数就不画进度条。
    var value: Double?
    /// 失败时那句话。有值就说明这次没成：不自动收，给一颗「关闭」。
    var failure: String?
    var onClose: () -> Void

    /// 卡片底色与进度条都跟着系统深浅色走：写死浅色时，深色模式下
    /// 白卡片配 Color.primary 的白字，阶段和百分比都看不见（LP 5145）。
    @Environment(\.colorScheme) private var colorScheme

    private var percentText: String {
        guard let value else { return "" }
        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            // 点外面不关：同步跑到一半被关掉，用户不知道写没写进去。
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.primary)

                Text(stage)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure {
                    Text(failure)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if value != nil {
                    HStack(spacing: 8) {
                        ProgressView(value: min(max(value ?? 0, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(KazumiPalette.accent(for: colorScheme))
                            .frame(height: 6)
                        Text(percentText)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Color.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(height: 6)
                }

                if failure != nil {
                    HStack {
                        Spacer(minLength: 0)
                        Button("关闭") { onClose() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
            .frame(width: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isModal)
        }
    }
}
