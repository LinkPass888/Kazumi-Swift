//
//  CaptchaVerificationService.swift
//  Kazumi
//
//  1:1 翻译 lib/services/plugin/captcha_verification_service.dart。
//
//  三种验证流程：
//   * 类型1 图片验证码：loadForCaptcha + submitCaptcha，图片消失即通过；
//   * 类型2 自动点击：loadForButtonClick，按钮消失或页面跳转即通过；
//   * 类型3 自定义脚本：loadForCustomScript，脚本 done 或返回 true 即通过。
//
//  通过后统一收尾：收割页面 HTML、保存 Cookie 与 UA，再把 HTML 交给 onVerified。
//  收尾与"结果提交权"分离：收尾可被成功/取消共用（single flight），
//  但只有先认领消息的一方能把结果交给 UI。
//

import Foundation
import Observation

@MainActor
@Observable
final class CaptchaVerificationService {
    private var webView: CaptchaWebView?
    private var isInitialized = false
    private var isDisposed = false
    private var pageUrl = ""
    private var outcomeClaimed = false
    private var finalizeTask: Task<String, Never>?

    /// 当前需要用户输入的验证码图片（data URL）。
    private(set) var captchaImageURL: Data?

    var onLog: ((String) -> Void)?

    private let cookies: PluginCookieStore

    init(cookies: PluginCookieStore = .shared) {
        self.cookies = cookies
    }

    private func ensureInitialized() {
        guard !isInitialized, !isDisposed else { return }
        let view = CaptchaWebView()
        view.onLog = { [weak self] message in
            self?.onLog?(message)
            KazumiLog.plugin.debug("\(message, privacy: .public)")
        }
        view.onCaptchaImageFound = { [weak self] src in
            guard let self else { return }
            KazumiLog.plugin.info("[CaptchaVerificationService] Captcha image found: \(src.prefix(64), privacy: .public)")
            if let comma = src.firstIndex(of: ","), src.hasPrefix("data:") {
                self.captchaImageURL = Foundation.Data(base64Encoded: String(src[src.index(after: comma)...]))
            }
        }
        view.initialize()
        webView = view
        isInitialized = true
        KazumiLog.plugin.info("[CaptchaVerificationService] WebView initialized")
    }

    /// 订阅验证通过事件：收尾后把收割到的 HTML 交给 onVerified。
    /// onFinalizing 在观察到验证通过、开始收尾之前触发。
    private func listenForVerification(
        pluginName: String,
        state: CaptchaWebView,
        onVerified: @escaping (String) -> Void,
        logPrefix: String = "",
        onFinalizing: (() -> Void)? = nil
    ) {
        state.onCaptchaDisappeared = { [weak self] in
            guard let self, let view = self.webView else { return }
            // 重新读取：事件与 dispose 之间可能已被置空。
            guard !self.isDisposed else { return }
            view.onCaptchaDisappeared = nil
            onFinalizing?()
            Task { @MainActor in
                let html = await self.runFinalize(pluginName: pluginName, controller: view, logPrefix: logPrefix, harvestHtml: true)
                guard !self.isDisposed, self.claimOutcome() else { return }
                onVerified(html)
            }
        }
    }

    /// 类型1：加载页面并开始监听验证码图片。
    func loadForCaptcha(_ url: String, captchaXpath: String, inputXpath: String? = nil) async {
        pageUrl = url
        ensureInitialized()
        guard !isDisposed, let view = webView else { return }
        await view.loadPage(url, captchaXpath: captchaXpath, inputXpath: inputXpath)
        KazumiLog.plugin.info("[CaptchaVerificationService] Page loading: \(url, privacy: .public)")
    }

    /// 填写验证码并点击提交按钮。
    func submitCaptcha(
        captchaCode: String,
        inputXpath: String,
        buttonXpath: String,
        pluginName: String,
        onVerified: @escaping (String) -> Void,
        onFinalizing: (() -> Void)? = nil
    ) async {
        guard let view = webView else {
            KazumiLog.plugin.warning("[CaptchaVerificationService] submitCaptcha called before init")
            return
        }
        KazumiLog.plugin.info("[CaptchaVerificationService] Submitting captcha code via interact")
        listenForVerification(
            pluginName: pluginName,
            state: view,
            onVerified: onVerified,
            onFinalizing: onFinalizing
        )
        await view.submitCaptcha(captchaCode: captchaCode, inputXpath: inputXpath, buttonXpath: buttonXpath)
    }

    /// 类型2：加载页面并在检测到按钮后自动点击。
    func loadForButtonClick(
        url: String,
        buttonXpath: String,
        pluginName: String,
        onVerified: @escaping (String) -> Void
    ) async {
        pageUrl = url
        ensureInitialized()
        guard !isDisposed, let view = webView else { return }
        listenForVerification(pluginName: pluginName, state: view, onVerified: onVerified, logPrefix: "(type2) ")
        await view.loadPageForButtonClick(url, buttonXpath: buttonXpath)
        KazumiLog.plugin.info("[CaptchaVerificationService] (type2) Page loading for button click: \(url, privacy: .public)")
    }

    /// 类型3：加载页面并注入规则提供的验证脚本。
    func loadForCustomScript(
        url: String,
        script: String,
        pluginName: String,
        onVerified: @escaping (String) -> Void
    ) async {
        pageUrl = url
        ensureInitialized()
        guard !isDisposed, let view = webView else { return }
        listenForVerification(pluginName: pluginName, state: view, onVerified: onVerified, logPrefix: "(type3) ")
        await view.loadPageForCustomScript(url, script: script)
        KazumiLog.plugin.info("[CaptchaVerificationService] (type3) Page loading for custom script: \(url, privacy: .public)")
    }

    /// 用户取消验证：先认领结果提交权（同步、无 await），再保存已有 Cookie。
    func cancelAndSave(pluginName: String) async {
        _ = claimOutcome()
        guard let view = webView, !pageUrl.isEmpty else { return }
        view.onCaptchaDisappeared = nil
        // 若验证成功路径已在收尾，这里汇合到那一次并等它把 Cookie 存完。
        _ = await runFinalize(pluginName: pluginName, controller: view, logPrefix: "on cancel ", harvestHtml: false)
    }

    private func claimOutcome() -> Bool {
        guard !outcomeClaimed else { return false }
        outcomeClaimed = true
        return true
    }

    /// 共享收尾：同一时刻只允许一次收割，成功与取消两条路径共用同一份结果。
    private func runFinalize(
        pluginName: String,
        controller: CaptchaWebView,
        logPrefix: String,
        harvestHtml: Bool
    ) async -> String {
        if let finalizeTask {
            return await finalizeTask.value
        }
        let url = pageUrl
        let store = cookies
        let task = Task { () -> String in
            var html = ""
            if harvestHtml {
                html = await Self.waitForPageHtml(controller)
                KazumiLog.plugin.info(
                    "[CaptchaVerificationService] \(logPrefix, privacy: .public)Harvested page html length: \(html.count)"
                )
            }
            let cookieString = await controller.cookieString(pageUrl: url)
            let userAgent = await controller.userAgentString()
            KazumiLog.plugin.info(
                "[CaptchaVerificationService] \(logPrefix, privacy: .public)Captured cookies: \(cookieString.count) bytes"
            )
            if !cookieString.isEmpty {
                store.saveFromWebView(
                    pluginName: pluginName,
                    pageUrl: url,
                    cookieString: cookieString,
                    userAgent: userAgent
                )
                KazumiLog.plugin.info(
                    "[CaptchaVerificationService] \(logPrefix, privacy: .public)Cookies saved for plugin: \(pluginName, privacy: .public)"
                )
            }
            await controller.unloadPage()
            return html
        }
        finalizeTask = task
        return await task.value
    }

    /// 验证消失事件可能早于结果页加载完成，短暂轮询；超时返回空串由上层回落重搜。
    private static func waitForPageHtml(_ controller: CaptchaWebView) async -> String {
        let maxAttempts = 10
        for _ in 0..<maxAttempts {
            let html = await controller.pageHtml()
            if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return html }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return ""
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        webView?.onCaptchaDisappeared = nil
        webView?.dispose()
        webView = nil
        isInitialized = false
        finalizeTask = nil
        KazumiLog.plugin.info("[CaptchaVerificationService] Disposed")
    }
}
