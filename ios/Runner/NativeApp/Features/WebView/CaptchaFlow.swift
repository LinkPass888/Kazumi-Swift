//
//  CaptchaFlow.swift
//  Kazumi
//
//  1:1 翻译 lib/pages/info/source_captcha_flow.dart 的验证编排逻辑：
//  * 图片验证码：用户输入 + 提交，提交后 8 秒内未通过视为失败；
//  * 自动点击 / 自定义脚本：无需用户输入，等待服务回调；
//  * 观察通过（onFinalizing）后取消超时，避免把已在收尾的验证判成失败。
//

import Foundation
import Observation

enum CaptchaFlowError: Error, LocalizedError, Sendable {
    case timedOut
    case failed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "验证失败，请稍后重试")
        case .failed: String(localized: "验证失败，请稍后重试")
        case .cancelled: String(localized: "已取消验证")
        }
    }
}

@MainActor
@Observable
final class CaptchaFlow {
    enum Phase: Equatable {
        case preparing
        case awaitingInput
        case verifying
        case completed
        case failed(String)
        case cancelled
    }

    let plugin: Plugin
    private(set) var phase: Phase = .preparing
    private(set) var captchaImage: Foundation.Data?
    private(set) var log: [String] = []

    private let service: CaptchaVerificationService
    private let keyword: String
    private let onFinished: (String) -> Void
    private var timeoutTask: Task<Void, Never>?
    private var observerTasks: [Task<Void, Never>] = []
    private var isFinalizing = false

    init(
        plugin: Plugin,
        keyword: String,
        service: CaptchaVerificationService = CaptchaVerificationService(),
        onFinished: @escaping (String) -> Void
    ) {
        self.plugin = plugin
        self.keyword = keyword
        self.service = service
        self.onFinished = onFinished
    }

    /// 与 Dart 端 `searchURL.replaceAll('@keyword', Uri.encodeQueryComponent(keyword))` 一致。
    var searchURL: String {
        plugin.searchURL.replacingOccurrences(of: "@keyword", with: encodeQueryComponent(keyword))
    }

    var captchaType: CaptchaType { plugin.antiCrawlerConfig.captchaType }

    var requiresUserInput: Bool {
        captchaType != .autoClickButton && captchaType != .customJavaScript
    }

    func start() async {
        guard phase == .preparing else { return }
        service.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        observeService()

        let config = plugin.antiCrawlerConfig
        switch config.captchaType {
        case .customJavaScript:
            await service.loadForCustomScript(
                url: searchURL,
                script: config.captchaScript,
                pluginName: plugin.name,
                onVerified: { [weak self] html in self?.handleVerified(html) }
            )
        case .autoClickButton:
            await service.loadForButtonClick(
                url: searchURL,
                buttonXpath: config.captchaButton,
                pluginName: plugin.name,
                onVerified: { [weak self] html in self?.handleVerified(html) }
            )
        default:
            phase = .awaitingInput
            await service.loadForCaptcha(
                searchURL,
                captchaXpath: config.captchaImage,
                inputXpath: config.captchaInput.isEmpty ? nil : config.captchaInput
            )
        }
        if requiresUserInput { phase = .awaitingInput }
    }

    /// 重新加载验证码图片（对应 onReload）。
    func reload() async {
        guard requiresUserInput else { return }
        phase = .awaitingInput
        captchaImage = nil
        await service.loadForCaptcha(
            searchURL,
            captchaXpath: plugin.antiCrawlerConfig.captchaImage,
            inputXpath: plugin.antiCrawlerConfig.captchaInput.isEmpty ? nil : plugin.antiCrawlerConfig.captchaInput
        )
    }

    /// 提交用户输入的验证码；返回后仍未通过则启动 8 秒超时。
    func submit(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .verifying
        let config = plugin.antiCrawlerConfig
        await service.submitCaptcha(
            captchaCode: trimmed,
            inputXpath: config.captchaInput,
            buttonXpath: config.captchaButton,
            pluginName: plugin.name,
            onVerified: { [weak self] html in self?.handleVerified(html) },
            onFinalizing: { [weak self] in self?.beginFinalizing() }
        )
        // 提交在 JS 点击后即返回，此时验证尚未完成。
        guard !isFinalizing else { return }
        startTimeout(seconds: 8)
    }

    /// 用户取消：保存已拿到的 Cookie 后按取消语义收尾。
    func cancel() async {
        timeoutTask?.cancel()
        await service.cancelAndSave(pluginName: plugin.name)
        phase = .cancelled
        service.dispose()
    }

    func dispose() {
        timeoutTask?.cancel()
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
        service.dispose()
    }

    // MARK: - Internals

    private func observeService() {
        // CaptchaVerificationService 通过闭包交给外部，因此这里只镜像图片与阶段状态。
        let imageTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.captchaImage != self.service.captchaImageURL {
                    self.captchaImage = self.service.captchaImageURL
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        observerTasks.append(imageTask)
    }

    private func appendLog(_ message: String) {
        log.append(message)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func beginFinalizing() {
        isFinalizing = true
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func startTimeout(seconds: Double) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.isFinalizing else { return }
            guard self.phase == .verifying else { return }
            self.phase = .failed(CaptchaFlowError.timedOut.localizedDescription)
            self.service.dispose()
        }
    }

    private func handleVerified(_ html: String) {
        guard phase != .completed, phase != .cancelled else { return }
        phase = .completed
        timeoutTask?.cancel()
        onFinished(html)
    }

    private func encodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
