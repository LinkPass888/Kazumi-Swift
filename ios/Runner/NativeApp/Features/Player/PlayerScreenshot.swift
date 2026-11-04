//
//  PlayerScreenshot.swift
//  Kazumi
//
//  播放页截图（LP 3660 / Colo 3667）：抓当前帧、存相册、闪一下。
//
//  只做 iOS 这条路：点一下存一张。main 里那套「候选列表 + 多选 + 一次存一批」
//  只有桌面面板会调用，iOS 上走不到，不照它做（Colo 3667）。
//

import Photos
import SwiftUI
import UIKit

enum PlayerScreenshot {
    /// 存进系统相册。成功返回 nil，失败返回给用户看的那句话。
    ///
    /// **必须是 nonisolated**：PhotoKit 是在它自己的队列
    /// （`com.apple.PHPhotoLibrary.transaction.high`）上回调这两个闭包的。外层只要标着
    /// `@MainActor`，闭包就被染成主线程隔离，进去就撞主线程断言、直接 trap——
    /// 真机上按一次截图就崩一次，连提示都来不及出（LP 4664 / 4688，栈就在这里）。
    /// 所以整段都写在 nonisolated 的地方，不靠「continuation 的闭包自动 nonisolated」。
    nonisolated static func save(pngAt fileURL: URL) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return String(localized: "截图保存失败：没有相册写入权限")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return String(localized: "截图保存失败：截图文件不见了（\(String(describing: fileURL.lastPathComponent))）")
        }
        do {
            // 显式写 isolation: nil：这条闭包不能被绑到任何 actor 上。
            try await withCheckedThrowingContinuation(isolation: nil) { (cont: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges(
                    {
                        // 从文件 URL 建，不把整张 PNG 读进内存（LP 4695 第 6 条）。
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                    },
                    completionHandler: { _, error in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                )
            }
            return nil
        } catch {
            return String(localized: "截图保存失败：\(String(describing: error.localizedDescription))")
        }
    }

    /// 从内存里的 PNG 存（详情页封面那条路）。先落临时文件，再走上面那条。
    ///
    /// 文件名带时间戳，跟截图那条区分开。
    nonisolated static func save(png data: Data) async -> String? {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
        } catch {
            return String(localized: "保存失败：临时文件写不出去")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return await save(pngAt: url)
    }
}

/// 截图时闪的那一下（Colo 3667 的数）：
/// 四角取景框从外往里收、同时淡入淡出，底下垫一层黑脉冲。
/// 系统开了「减弱动态效果」就整段不播。
struct ScreenshotFlashView: View {
    /// 从 0 到 1 走一遍的进度。
    var progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 框从「左右各 5.5%、上下各 7.5%」收到「8% / 10.5%」（0–68% easeOutCubic）。
            let eased = easeOutCubic(min(progress / 0.68, 1))
            let insetX = size.width * (0.055 + (0.08 - 0.055) * eased)
            let insetY = size.height * (0.075 + (0.105 - 0.075) * eased)
            // 线宽 1.4 → 2.2，角长 = 框短边 × 0.12（夹在 22–54 之间）。
            let lineWidth = 1.4 + (2.2 - 1.4) * eased
            let frameWidth = max(0, size.width - insetX * 2)
            let frameHeight = max(0, size.height - insetY * 2)
            let corner = min(max(min(frameWidth, frameHeight) * 0.12, 22), 54)
            // 0–14% 淡入，58–100% 淡出，白 90%。
            let opacity = flashOpacity(progress)
            // 黑底脉冲：18% 到峰值 12%，62% 前散尽。
            let pulse = pulseOpacity(progress)

            ZStack {
                Color.black.opacity(pulse)
                CornersShape(cornerLength: corner)
                    .stroke(
                        Color.white.opacity(0.9 * opacity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .frame(width: frameWidth, height: frameHeight)
                    .position(x: size.width / 2, y: size.height / 2)
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
    }

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    private func flashOpacity(_ t: CGFloat) -> CGFloat {
        if t <= 0.14 { return min(max(t / 0.14, 0), 1) }
        if t < 0.58 { return 1 }
        return max(0, 1 - (t - 0.58) / 0.42)
    }

    private func pulseOpacity(_ t: CGFloat) -> CGFloat {
        guard t > 0, t < 0.62 else { return 0 }
        if t <= 0.18 { return 0.12 * (t / 0.18) }
        return 0.12 * max(0, 1 - (t - 0.18) / 0.44)
    }
}

/// 只画四个角的取景框（不是整框）。
struct CornersShape: Shape {
    var cornerLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = min(cornerLength, min(rect.width, rect.height) / 2)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x + length * dx, y: point.y))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x, y: point.y + length * dy))
        }
        return path
    }
}
