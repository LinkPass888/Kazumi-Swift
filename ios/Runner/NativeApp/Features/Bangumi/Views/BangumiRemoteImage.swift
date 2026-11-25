//
//  BangumiRemoteImage.swift
//  Kazumi
//
//  对应 lib/bean/card/network_img_layer.dart 的职责：加载 Bangumi 封面。
//  Bangumi 的图片地址可能是 http，原生 URLSession 会受 ATS 限制，
//  因此这里统一按 https 发起（bangumi 图床两者都可用）。
//
//  图片走 `KazumiImageLoader` 的两级缓存：视图初始化时先同步问一次内存缓存，
//  命中就直接当首帧画出来 —— 列表上下滚动、从详情页返回都不会再闪一次白。
//

import SwiftUI

struct BangumiRemoteImage: View {
    let url: String
    /// 与 Dart 版 BoxFit.cover 对应的 contentMode。
    var contentMode: ContentMode = .fill
    /// 列表可按自己的队列串行回源；关掉后只读本地缓存。
    var networkLoadEnabled = true
    /// 外层每完成一张有序加载就 +1，让视图重新检查内存缓存。
    var reloadToken = 0
    /// 可选解码像素上限（如模糊背景只需 120px，避免按整屏尺寸解码原图）。
    var maxPixelSize: Int? = nil

    @State private var image: UIImage?
    @State private var pixelSize: Int
    /// 尺寸档位变化时 +1，用来重开一次加载任务。
    @State private var attempt = 0

    init(
        url: String,
        contentMode: ContentMode = .fill,
        networkLoadEnabled: Bool = true,
        reloadToken: Int = 0,
        maxPixelSize: Int? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.networkLoadEnabled = networkLoadEnabled
        self.reloadToken = reloadToken
        self.maxPixelSize = maxPixelSize
        // 命中内存缓存时直接出图，不经历「占位 → 图片」这一帧。
        let defaultSize = KazumiImageLoader.pixelSize(for: CGSize(width: 200, height: 300))
        let size = maxPixelSize.map { min(defaultSize, max(64, $0)) } ?? defaultSize
        _pixelSize = State(initialValue: size)
        let initial = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: size)
            ?? KazumiImageLoader.shared.cachedImage(for: url, pixelSize: 120)
        _image = State(initialValue: initial)
    }

    private var key: String { KazumiImageLoader.cacheKey(for: url) }

    var body: some View {
        ZStack {
            placeholderBackground

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholderSymbol
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onGeometryChange(for: Int.self) { proxy in
            let measured = KazumiImageLoader.pixelSize(for: proxy.size)
            if let cap = maxPixelSize {
                return min(measured, max(64, cap))
            }
            return measured
        } action: { newValue in
            // 只在像素档位真的变了才重来一次：布局每帧都会回调，
            // 若把尺寸直接绑进 .task 的 id，加载会被反复取消，永远出不来图。
            guard newValue != pixelSize else { return }
            let needsUpgrade: Bool
            if let current = image {
                let currentLongest = Int(max(current.size.width * current.scale, current.size.height * current.scale))
                needsUpgrade = newValue > currentLongest + 100
            } else {
                needsUpgrade = true
            }
            pixelSize = newValue
            if needsUpgrade { attempt += 1 }
        }
        .onChange(of: key) { _, newKey in
            guard !newKey.isEmpty else {
                image = nil
                return
            }
            if let cached = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixelSize)
                ?? KazumiImageLoader.shared.cachedImage(for: url, pixelSize: 120) {
                image = cached
            } else {
                image = nil
            }
        }
        .task(id: "\(key)#\(attempt)#\(reloadToken)") {
            await loadIfNeeded()
        }
    }

    /// 占位底：很淡的一层，图片淡入时几乎看不出切换，也不会整块发灰。
    private var placeholderBackground: some View {
        Rectangle()
            .fill(.quinary)
    }

    private var placeholderSymbol: some View {
        Image(systemName: "movieclapper")
            .font(.title3)
            .foregroundStyle(.tertiary)
    }

    /// 失败不留状态：取不到就显示占位，视图再次出现时（或尺寸档位变化时）
    /// 会重新走一遍 .task，跟原版一样每次显示都允许再试。
    private func loadIfNeeded() async {
        guard !key.isEmpty else { return }
        if let cached = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixelSize) {
            image = cached
            return
        }
        if !networkLoadEnabled {
            if await KazumiImageLoader.shared.loadFromDisk(url, pixelSize: pixelSize),
               let cached = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixelSize) {
                withAnimation(.easeOut(duration: 0.15)) {
                    image = cached
                }
            }
            return
        }
        // 重试统一收口在 KazumiImageLoader.fetch 内部，这里只发起一次加载。
        _ = await KazumiImageLoader.shared.load(url, pixelSize: pixelSize)
        // 即使这个任务被取消（视图复用 / 尺寸变化），只要图已经在缓存里就画出来，
        // 否则会白白丢掉一次已经完成的下载。
        if let cached = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixelSize) {
            withAnimation(.easeOut(duration: 0.15)) {
                image = cached
            }
        }
    }
}

/// 圆形头像（对应原版 lib/bean/widget/bangumi_avatar.dart 的 BangumiAvatar）。
///
/// 与原版的差别在裁切方式：原版把图居中裁成圆，人脸偏上时会把头顶切掉。
/// 这里按 `focus` 参数选择竖直方向的取景中心 —— 0 是顶部对齐（露出头部），
/// 0.5 才是居中。角色 / 制作人员头像统一用偏上的取景。
struct KazumiAvatar: View {
    let url: String
    /// 直径。
    var size: CGFloat = 40
    /// 竖直取景中心：0 顶部、0.5 居中、1 底部。
    var focus: CGFloat = 0.18

    @State private var image: UIImage?

    init(url: String, size: CGFloat = 40, focus: CGFloat = 0.18) {
        self.url = url
        self.size = size
        self.focus = focus
        let pixels = KazumiImageLoader.pixelSize(for: CGSize(width: size, height: size))
        _image = State(initialValue: KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixels))
    }

    private var key: String { KazumiImageLoader.cacheKey(for: url) }

    var body: some View {
        ZStack {
            Circle().fill(.quinary)

            if let image, image.size.width > 0, image.size.height > 0 {
                let scale = max(size / image.size.width, size / image.size.height)
                let width = image.size.width * scale
                let height = image.size.height * scale
                Image(uiImage: image)
                    .resizable()
                    .frame(width: width, height: height)
                    // 子视图在 ZStack 里是居中的：先按居中算，再把竖直中心
                    // 从 0.5 平移到 focus（0 顶部 / 1 底部）。
                    .offset(y: (height - size) * (0.5 - focus))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: key) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        guard !key.isEmpty, image == nil else { return }
        let pixels = KazumiImageLoader.pixelSize(for: CGSize(width: size, height: size))
        // 重试统一收口在 KazumiImageLoader.fetch 内部，这里只发起一次加载。
        _ = await KazumiImageLoader.shared.load(url, pixelSize: pixels)
        guard !Task.isCancelled else { return }
        if let cached = KazumiImageLoader.shared.cachedImage(for: url, pixelSize: pixels) {
            withAnimation(.easeOut(duration: 0.15)) {
                image = cached
            }
        }
    }
}

