//
//  DocumentPickerBridge.swift
//  Kazumi
//
//  文件面板只有一份实现，谁要选文件、存文件都从这里走。
//
//  为什么不用 SwiftUI 的 .fileImporter / .fileExporter：
//  侧载包上点文件、点目录都不响应（面板开着，点下去什么也不发生）。改成直接
//  呈现系统的 UIDocumentPickerViewController。
//
//  asCopy 两种模式都要用，选哪个看调用方要什么：
//  - 文件（导入规则、备份）用 asCopy: true——拷进 App 自己的临时目录再交给我们，
//    读的时候不依赖安全作用域，也不依赖文件提供器把 URL 传过来那条路；
//  - 目录（下载位置）必须 asCopy: false——拷贝模式只对文件成立，对文件夹要么
//    不给选、要么整个复制一份，两种都不对；这时拿到的 URL 得自己开安全作用域
//    （见 DownloadDirectoryStore）。
//
//  「等面板退干净再继续」也放在这里：delegate 回调时面板还在退场动画里，
//  上层拿到的结果由调用方延后一拍再弹窗/改状态。
//

import UIKit
import UniformTypeIdentifiers

@MainActor
final class DocumentPickerBridge: NSObject, UIDocumentPickerDelegate {
    typealias Completion = (Result<[URL], Error>) -> Void

    /// 面板期间必须有人持有 bridge，否则 delegate 当场被释放，回调不会来。
    ///
    /// 按 picker 归档而不是全局单份：单份时第二次调用会顶掉第一个的强引用，
    /// 而 UIDocumentPickerViewController 的 delegate 是 weak——屏幕上那个面板的
    /// delegate 当场变 nil，点「打开」永远等不到回调：面板不关、什么也不发生
    /// （LP 5218/5226/5236/5242/5246 的形状）。
    private static var bridges: [ObjectIdentifier: DocumentPickerBridge] = [:]
    private let picker: UIDocumentPickerViewController
    private let completion: Completion

    private init(picker: UIDocumentPickerViewController, completion: @escaping Completion) {
        self.picker = picker
        self.completion = completion
    }

    // MARK: - 入口

    /// 选文件（导入）。asCopy：拷进 App 沙箱，回来的是一个随时能读的 URL。
    /// 选目录必须 asCopy: false —— 拷贝模式只对文件成立，对文件夹要么直接不给选，
    /// 要么把它整个复制一份，两种都不对；这时拿到的 URL 要自己开安全作用域
    /// （见 DownloadDirectoryStore）。
    static func open(
        types: [UTType],
        asCopy: Bool = true,
        startingDirectory: URL? = nil,
        from host: UIViewController? = nil,
        completion: @escaping Completion
    ) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        // 不给起点时，面板会开在「Recents」；那页是空的，「打开」就是灰的——
        // 点下去什么都不发生、面板也不关（LP 5226/5242）。给一个真实文件夹，
        // 「打开」一开局就是蓝的。
        picker.directoryURL = startingDirectory
        present(picker, from: host, mode: asCopy ? "拷贝" : "原地", completion: completion)
    }

    /// 存文件（导出）。调用方先把内容写成临时文件，这里只负责让用户挑位置。
    static func export(
        url: URL,
        from host: UIViewController? = nil,
        completion: @escaping Completion
    ) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        present(picker, from: host, mode: "存储", completion: completion)
    }

    // MARK: - 呈现

    private static func present(
        _ picker: UIDocumentPickerViewController,
        from host: UIViewController?,
        mode: String,
        completion: @escaping Completion
    ) {
        // 真机取证：侧载重签有可能把 Info.plist 里的开关抹掉，光看源码猜不出来
        // （LP 5242：装的是最新版，但「我的 iPhone」里没有 Kazumi 文件夹）。
        logCapabilities()
        KazumiLogBuffer.storage("文件面板：已打开（\(mode)模式）")
        guard let host = host ?? topViewController() else {
            completion(.failure(PickerError.noHost))
            return
        }
        let bridge = DocumentPickerBridge(picker: picker, completion: completion)
        Self.bridges[ObjectIdentifier(picker)] = bridge
        picker.delegate = bridge
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        host.present(picker, animated: true)
    }

    /// 把 App 自己看到的文件能力写进运行日志。装完之后一看就知道：是重签抹掉了，
    /// 还是系统不认。
    private static func logCapabilities() {
        let info = Bundle.main.infoDictionary ?? [:]
        func flag(_ key: String) -> String {
            (info[key] as? Bool) == true ? "是" : "否"
        }
        let types = (info["CFBundleDocumentTypes"] as? [[String: Any]])?.count ?? 0
        KazumiLogBuffer.storage(
            "文件面板：iOS \(UIDevice.current.systemVersion)，允许原地打开=\(flag("LSSupportsOpeningDocumentsInPlace"))，文件 App 可见=\(flag("UIFileSharingEnabled"))，声明可打开类型=\(types) 条"
        )
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
        guard var top = windows.first(where: \.isKeyWindow)?.rootViewController
            ?? windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        KazumiLogBuffer.storage("文件面板：选中 \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        finish(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        KazumiLogBuffer.storage("文件面板：已取消")
        finish(.failure(PickerError.cancelled))
    }

    private func finish(_ result: Result<[URL], Error>) {
        // 面板正在退场：这一拍只放行 bridge，等它退干净再由上层动作。
        Self.bridges[ObjectIdentifier(picker)] = nil
        completion(result)
    }

    enum PickerError: LocalizedError {
        case cancelled
        case noHost

        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消"
            case .noHost: return "打不开文件面板"
            }
        }
    }
}
