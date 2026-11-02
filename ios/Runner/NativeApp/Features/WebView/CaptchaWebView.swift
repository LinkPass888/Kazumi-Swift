//
//  CaptchaWebView.swift
//  Kazumi
//
//  1:1 翻译 lib/webview/captcha/impl/captcha_webview_inappwebview_impl.dart，
//  用 WKWebView 的 WKUserScript + script message handler 复刻 InAppWebView 的
//  addUserScripts / addJavaScriptHandler 行为。
//
//  桥接协议（与 Dart 端脚本完全一致，改动必须两边同步）：
//    JS → App：CaptchaImageBridge / CaptchaStatusBridge / CaptchaGoneBridge /
//              ButtonClickedBridge / CaptchaLogBridge
//    App → JS：脚本模板中调用 window.flutter_inappwebview.callHandler(...)，
//              这里在 document start 注入一个同名 shim 转发到 WKWebView handler。
//

import Foundation
import WebKit

@MainActor
final class CaptchaWebView: NSObject {
    /// 与 Dart 端的控制器语义一一对应。
    private(set) var captchaWasFound = false
    private(set) var buttonWasClicked = false

    var onInitialized: ((Bool) -> Void)?
    var onCaptchaImageFound: ((String) -> Void)?
    var onCaptchaDisappeared: (() -> Void)?
    var onLog: ((String) -> Void)?

    private static let handlerNames = [
        "CaptchaImageBridge",
        "CaptchaStatusBridge",
        "CaptchaGoneBridge",
        "ButtonClickedBridge",
        "CaptchaLogBridge"
    ]

    private var webView: WKWebView?
    private var currentCaptchaImageXpath = ""
    private var currentInputXpath = ""
    private var isDisposed = false

    /// 随机 UA 与 Dart 端一致；clearance cookie 与 UA 绑定，故整个会话保持不变。
    private let userAgent = HTTPHeaders.randomUserAgent()

    func initialize() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = WKUserContentController()
        for name in Self.handlerNames {
            controller.add(self, name: name)
        }
        controller.addUserScript(WKUserScript(
            source: Self.callHandlerShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.customUserAgent = userAgent
        webView = view
        emit("[Captcha WebView] Created")
        onInitialized?(true)
    }

    /// 类型1：加载页面并监听验证码图片出现/消失。
    func loadPage(_ url: String, captchaXpath: String, inputXpath: String?) async {
        guard webView != nil else { return }
        currentCaptchaImageXpath = captchaXpath
        currentInputXpath = inputXpath ?? ""
        captchaWasFound = false
        buttonWasClicked = false
        injectCaptchaScript()
        await clearCookies()
        await load(url)
    }

    /// 类型2：加载页面并在检测到按钮后自动点击。
    func loadPageForButtonClick(_ url: String, buttonXpath: String) async {
        guard let webView else { return }
        currentCaptchaImageXpath = ""
        currentInputXpath = ""
        captchaWasFound = false
        buttonWasClicked = false
        webView.configuration.userContentController.removeAllUserScripts()
        addUserScript(Self.callHandlerShim, injectionTime: .atDocumentStart)
        addUserScript(Self.buttonClickScript(xpath: buttonXpath), injectionTime: .atDocumentEnd)
        await clearCookies()
        await load(url)
    }

    /// 类型3：加载页面并注入规则提供的验证脚本。
    func loadPageForCustomScript(_ url: String, script: String) async {
        guard let webView else { return }
        currentCaptchaImageXpath = ""
        currentInputXpath = ""
        captchaWasFound = false
        buttonWasClicked = false
        webView.configuration.userContentController.removeAllUserScripts()
        addUserScript(Self.callHandlerShim, injectionTime: .atDocumentStart)
        addUserScript(Self.customScript(script), injectionTime: .atDocumentEnd)
        await clearCookies()
        await load(url)
    }

    /// 在页面内填写验证码并点击提交按钮（对应 submitCaptchaInteract）。
    func submitCaptcha(captchaCode: String, inputXpath: String, buttonXpath: String) async {
        guard let view = webView else { return }
        emit("[Captcha WebView] Filling input and clicking button")
        let source = """
        (function() {
          function evalXpath(xpath) {
            try {
              var r = document.evaluate(xpath, document, null,
                XPathResult.FIRST_ORDERED_NODE_TYPE, null);
              return r.singleNodeValue;
            } catch(e) { return null; }
          }
          var inputEl = evalXpath('\(Self.escape(inputXpath))');
          if (inputEl) {
            inputEl.focus();
            var nativeInput = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value');
            nativeInput.set.call(inputEl, '\(Self.escape(captchaCode))');
            inputEl.dispatchEvent(new Event('input', { bubbles: true }));
            inputEl.dispatchEvent(new Event('change', { bubbles: true }));
            try { window.flutter_inappwebview.callHandler('CaptchaLogBridge', 'Input filled'); } catch(e) {}
          } else {
            try { window.flutter_inappwebview.callHandler('CaptchaLogBridge', 'Input element not found'); } catch(e) {}
          }
          var btnEl = evalXpath('\(Self.escape(buttonXpath))');
          if (btnEl) {
            btnEl.click();
            try { window.flutter_inappwebview.callHandler('CaptchaLogBridge', 'Button clicked'); } catch(e) {}
          } else {
            try { window.flutter_inappwebview.callHandler('CaptchaLogBridge', 'Button element not found'); } catch(e) {}
          }
        })();
        """
        _ = try? await view.evaluateJavaScript(source)
    }

    /// 当前页面 Cookie（`key1=val1; key2=val2`）。
    func cookieString(pageUrl: String) async -> String {
        guard let webView, let url = URL(string: pageUrl) else { return "" }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = url.host ?? ""
        return cookies
            .filter { Self.domain(host: host, matches: $0.domain) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 页面仍在加载时返回空串，由调用方决定是否重试。
    func pageHtml() async -> String {
        guard let webView else { return "" }
        let source = "document.readyState === 'loading' ? '' : document.documentElement.outerHTML;"
        let result = try? await webView.evaluateJavaScript(source)
        guard let html = result as? String else { return "" }
        return html
    }

    func userAgentString() async -> String {
        guard let webView else { return "" }
        let result = try? await webView.evaluateJavaScript("navigator.userAgent;")
        return (result as? String) ?? userAgent
    }

    func unloadPage() async {
        guard let webView, let blank = URL(string: "about:blank") else { return }
        webView.load(URLRequest(url: blank))
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        currentCaptchaImageXpath = ""
        currentInputXpath = ""
        captchaWasFound = false
        buttonWasClicked = false
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
            for name in Self.handlerNames {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
            webView.navigationDelegate = nil
        }
        webView = nil
    }
    // MARK: - 内部实现

    private func addUserScript(_ source: String, injectionTime: WKUserScriptInjectionTime) {
        webView?.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: false)
        )
    }

    private func load(_ url: String) async {
        guard let webView, let target = URL(string: url) else { return }
        webView.load(URLRequest(url: target))
    }

    /// 与 Dart 端一致：每次加载前清空所有 Cookie，避免旧的 clearance 干扰。
    private func clearCookies() async {
        guard let webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        // iOS 26 SDK 起 `delete(_:)` 被标注为可异步；显式绑定到同步签名，
        // 避免编译器把它解析成 async 版本而报 "asynchronous alternative" 警告。
        let deleteSync: (HTTPCookie) -> Void = { store.delete($0) }
        for cookie in cookies {
            deleteSync(cookie)
        }
        emit("[Captcha WebView] Cookies cleared before load")
    }

    private func injectCaptchaScript() {
        guard let webView, !currentCaptchaImageXpath.isEmpty else { return }
        webView.configuration.userContentController.removeAllUserScripts()
        addUserScript(Self.callHandlerShim, injectionTime: .atDocumentStart)
        addUserScript(
            Self.captchaScript(xpath: currentCaptchaImageXpath, inputXpath: currentInputXpath),
            injectionTime: .atDocumentStart
        )
    }

    private func emit(_ message: String) {
        onLog?(message)
    }

    /// 与 Dart 的 `replaceAll('\\\\', '\\\\\\\\').replaceAll("'", "\\'")` 一致。
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func domain(host: String, matches cookieDomain: String) -> Bool {
        let host = host.lowercased()
        let domain = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
    }

    /// InAppWebView 的 callHandler shim：让 Dart 端脚本可以原样复用。
    private static let callHandlerShim = """
    window.flutter_inappwebview = window.flutter_inappwebview || {};
    window.flutter_inappwebview.callHandler = function(name, ...args) {
      var value = args.length > 0 && args[0] != null ? String(args[0]) : '';
      try {
        window.webkit.messageHandlers[name].postMessage(value);
      } catch(e) {}
    };
    """

    private static func captchaScript(xpath: String, inputXpath: String) -> String {
        let escapedXpath = escape(xpath)
        let escapedInputXpath = escape(inputXpath)
        return """
        window.flutter_inappwebview.callHandler('CaptchaLogBridge',
          'CaptchaScript loaded on: ' + window.location.href);

        var _captchaXpath = '\(escapedXpath)';
        var _inputXpath = '\(escapedInputXpath)';
        var _captchaPoller = null;
        var _disappearObserver = null;

        function _evalXpath() {
          try {
            var result = document.evaluate(
              _captchaXpath, document, null,
              XPathResult.FIRST_ORDERED_NODE_TYPE, null);
            return result.singleNodeValue;
          } catch(e) { return null; }
        }

        function _startDisappearMonitor() {
          if (_disappearObserver) return;
          _disappearObserver = new MutationObserver(function() {
            var node = _evalXpath();
            if (!node) {
              _disappearObserver.disconnect();
              _disappearObserver = null;
              try {
                window.flutter_inappwebview.callHandler('CaptchaGoneBridge', '');
              } catch(e) {}
            }
          });
          _disappearObserver.observe(document.documentElement,
            { childList: true, subtree: true, attributes: true });
        }

        function _captureAsBase64(imgNode, callback) {
          function doCapture() {
            try {
              var canvas = document.createElement('canvas');
              canvas.width = imgNode.naturalWidth || imgNode.width || 100;
              canvas.height = imgNode.naturalHeight || imgNode.height || 40;
              var ctx = canvas.getContext('2d');
              ctx.drawImage(imgNode, 0, 0);
              callback(canvas.toDataURL('image/png'));
            } catch(e) { callback(null); }
          }
          if (imgNode.complete && imgNode.naturalWidth > 0) {
            doCapture();
          } else {
            imgNode.addEventListener('load', doCapture);
            imgNode.addEventListener('error', function() { callback(null); });
          }
        }

        function _checkForCaptcha() {
          var node = _evalXpath();
          if (node) {
            _captureAsBase64(node, function(dataUrl) {
              if (dataUrl) {
                try {
                  window.flutter_inappwebview.callHandler('CaptchaImageBridge', dataUrl);
                } catch(e) {}
              }
            });
            _startDisappearMonitor();
            return true;
          }
          return false;
        }

        function _triggerInputFocus() {
          if (!_inputXpath) return false;
          try {
            var inputResult = document.evaluate(_inputXpath, document, null,
              XPathResult.FIRST_ORDERED_NODE_TYPE, null);
            var inputEl = inputResult.singleNodeValue;
            if (inputEl) {
              if (typeof $ !== 'undefined' && $) {
                $(inputEl).trigger('focus');
                return true;
              } else if (typeof jQuery !== 'undefined' && jQuery) {
                jQuery(inputEl).trigger('focus');
                return true;
              } else {
                inputEl.focus();
                return true;
              }
            }
          } catch(e) {
            try { window.flutter_inappwebview.callHandler('CaptchaLogBridge',
              'Failed to trigger input focus - ' + e.message); } catch(e2) {}
          }
          return false;
        }

        window.addEventListener('DOMContentLoaded', function() {
          _triggerInputFocus();
          var node = _evalXpath();
          try {
            window.flutter_inappwebview.callHandler('CaptchaStatusBridge', node ? 'present' : 'absent');
          } catch(e) {}
        });

        if (!_checkForCaptcha()) {
          _captchaPoller = setInterval(function() {
            if (_checkForCaptcha()) {
              clearInterval(_captchaPoller);
              _captchaPoller = null;
            }
          }, 500);
        }
        """
    }
    private static func buttonClickScript(xpath: String) -> String {
        let escapedXpath = escape(xpath)
        return """
        try { window.flutter_inappwebview.callHandler('CaptchaLogBridge',
          'ButtonClickScript loaded on: ' + window.location.href); } catch(e) {}

        var _btnXpath = '\(escapedXpath)';
        var _clicked = false;
        var _poller = null;
        var _disappearObserver = null;

        function _evalBtnXpath() {
          try {
            var result = document.evaluate(
              _btnXpath, document, null,
              XPathResult.FIRST_ORDERED_NODE_TYPE, null);
            return result.singleNodeValue;
          } catch(e) { return null; }
        }

        function _startDisappearMonitor() {
          if (_disappearObserver) return;
          _disappearObserver = new MutationObserver(function() {
            if (!_evalBtnXpath()) {
              _disappearObserver.disconnect();
              _disappearObserver = null;
              try { window.flutter_inappwebview.callHandler('CaptchaGoneBridge', ''); } catch(e) {}
            }
          });
          _disappearObserver.observe(document.documentElement,
            { childList: true, subtree: true, attributes: true });
        }

        function _checkAndClick() {
          var btn = _evalBtnXpath();
          if (btn && !_clicked) {
            _clicked = true;
            btn.click();
            try { window.flutter_inappwebview.callHandler('ButtonClickedBridge', ''); } catch(e) {}
            _startDisappearMonitor();
            return true;
          }
          return false;
        }

        if (!_checkAndClick()) {
          _poller = setInterval(function() {
            if (_checkAndClick()) { clearInterval(_poller); _poller = null; }
          }, 500);
        }
        """
    }

    private static func customScript(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空脚本直接走 fail 分支，与 Dart 端 `!${script.trim().isEmpty ? 'false' : 'true'}` 等价。
        let guardExpression = trimmed.isEmpty ? "false" : "true"
        return """
        (function() {
          try {
            window.KazumiCaptcha = {
              log: function(message) {
                try { window.flutter_inappwebview.callHandler('CaptchaLogBridge', String(message)); } catch(e) {}
              },
              clicked: function() {
                try { window.flutter_inappwebview.callHandler('ButtonClickedBridge', ''); } catch(e) {}
              },
              done: function() {
                try { window.flutter_inappwebview.callHandler('CaptchaGoneBridge', ''); } catch(e) {}
              },
              fail: function(message) {
                try { window.flutter_inappwebview.callHandler('CaptchaLogBridge', 'Custom script failed: ' + String(message)); } catch(e) {}
              }
            };
            window.KazumiCaptcha.log('CustomScript loaded on: ' + window.location.href);
            if (!\(guardExpression)) {
              window.KazumiCaptcha.fail('empty captchaScript');
              return;
            }
            var __kazumiResult = (function() {
        \(script)
            })();
            if (__kazumiResult === true) {
              window.KazumiCaptcha.done();
            }
          } catch(e) {
            try { window.KazumiCaptcha.fail(e && e.message ? e.message : e); } catch(e2) {}
          }
        })();
        """
    }
}

// MARK: - WKNavigationDelegate

extension CaptchaWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emit("[Captcha WebView] Load start: \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit("[Captcha WebView] Load stop: \(webView.url?.absoluteString ?? "")")
        // 自动点击后发生整页跳转，说明验证已通过。
        if buttonWasClicked {
            buttonWasClicked = false
            onCaptchaDisappeared?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emit("[Captcha WebView] Error: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emit("[Captcha WebView] Error: \(error.localizedDescription)")
    }
}

// MARK: - WKScriptMessageHandler

extension CaptchaWebView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let payload = message.body as? String ?? ""
        switch message.name {
        case "CaptchaImageBridge":
            emit("[Captcha WebView] Captcha image found: \(payload)")
            if !payload.isEmpty {
                captchaWasFound = true
                onCaptchaImageFound?(payload)
            }
        case "CaptchaStatusBridge":
            emit("[Captcha WebView JS] Page captcha status: \(payload)")
            // 整页跳转后验证码消失，说明验证通过（类型1）。
            if payload == "absent" && captchaWasFound {
                captchaWasFound = false
                onCaptchaDisappeared?()
            }
        case "CaptchaGoneBridge":
            emit("[Captcha WebView] Captcha image disappeared")
            buttonWasClicked = false
            onCaptchaDisappeared?()
        case "ButtonClickedBridge":
            emit("[Captcha WebView] Button clicked flag set")
            buttonWasClicked = true
        case "CaptchaLogBridge":
            if !payload.isEmpty { emit("[Captcha WebView JS] \(payload)") }
        default:
            break
        }
    }
}
