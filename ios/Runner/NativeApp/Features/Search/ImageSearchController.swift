//
//  ImageSearchController.swift
//  Kazumi
//
//  对应 lib/pages/search/search_controller.dart 的以图搜番部分：
//  isImageSearching / imageSearchError / imageSearchResults + clearImageSearchState。
//
//  结果按相似度倒序（原版在页面里排序，这里放到状态层，避免每次重算）。
//

import ImageIO
import Observation
import UIKit

@MainActor
@Observable
final class ImageSearchController {
    /// 与原版一致的「空结果」文案，页面据此区分「没找到」和「失败了」。
    static let emptyResultMessage = String(localized: "未找到匹配结果")
    static let failureMessage = String(localized: "图片搜索失败，请稍后重试")

    private(set) var isSearching = false
    private(set) var errorMessage = ""
    private(set) var results: [TraceResultItem] = []

    /// 代数机制：切换来源或换图后丢弃过期响应。
    private var generation = 0

    /// 对应 clearImageSearchState。
    func clear() {
        generation += 1
        isSearching = false
        errorMessage = ""
        results = []
    }

    /// 对应 searchImageByFile：body 是图片原始字节。
    func search(imageData: Data) async {
        let current = beginSearch()
        do {
            let item = try await TraceAPI.searchByImageData(imageData)
            apply(item, generation: current)
        } catch {
            applyFailure(error, generation: current)
        }
    }

    /// 对应 searchImageByUrl。
    func search(imageURL: String) async {
        let current = beginSearch()
        do {
            let item = try await TraceAPI.searchByImageURL(imageURL)
            apply(item, generation: current)
        } catch {
            applyFailure(error, generation: current)
        }
    }

    // MARK: - 内部

    private func beginSearch() -> Int {
        generation += 1
        isSearching = true
        errorMessage = ""
        results = []
        return generation
    }

    /// 对应 searchImageByFile / ByUrl 的收尾逻辑。
    private func apply(_ item: ImageSearchItem, generation current: Int) {
        guard current == generation else { return }
        let sorted = (item.result ?? []).sorted {
            ($0.similarity ?? 0) > ($1.similarity ?? 0)
        }
        if let error = item.error, !error.isEmpty {
            errorMessage = error
        } else if sorted.isEmpty {
            errorMessage = Self.emptyResultMessage
        }
        results = sorted
        isSearching = false
    }

    private func applyFailure(_ error: any Error, generation current: Int) {
        guard current == generation else { return }
        KazumiLog.network.error("Image search failed: \(error.localizedDescription, privacy: .public)")
        results = []
        errorMessage = Self.failureMessage
        isSearching = false
    }
}

/// 已选中的本地图片：保留缩放后的 UIImage 用于预览，并持有后台预压缩好的 JPEG 上传数据。
/// UIKit 视图层与 @MainActor 的控制器都在主线程，因此标记 @unchecked Sendable。
struct PickedImage: @unchecked Sendable {
    let image: UIImage
    let fileName: String
    /// trace.moe 只接受 JPEG，后台按长边 ≤ 1600px、质量 0.85 预先压缩后缓存。
    let jpegData: Data

    /// 在后台线程用 ImageIO 直接解码缩略图（长边上限 1600px）并编码为 JPEG（质量 0.85）。
    static func prepare(from rawData: Data, fileName: String) -> PickedImage? {
        let decoded: UIImage? = {
            guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else {
                return UIImage(data: rawData)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
            let fallbackOptions: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, fallbackOptions as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
            return UIImage(data: rawData)
        }()
        guard let image = decoded,
              let jpeg = image.jpegData(compressionQuality: 0.85),
              !jpeg.isEmpty
        else { return nil }
        return PickedImage(image: image, fileName: fileName, jpegData: jpeg)
    }
}
