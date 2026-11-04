//
//  WebViewContentRules.swift
//  Kazumi
//
//  1:1 翻译 lib/webview/video/impl/video_webview_apple_impl.dart 中的
//  contentBlockers 列表（ContentBlockerTrigger → WKContentRuleList JSON）。
//
//  目的：视频嗅探只需要拿到媒体地址，图片与广告页只会拖慢加载并触发反爬，
//  因此整站屏蔽图片、屏蔽 devtools-detector 脚本与常见广告跳转页。
//

import Foundation
import WebKit

@MainActor
final class WebViewContentRules {
    private static var cachedList: WKContentRuleList?
    private static var compileTask: Task<WKContentRuleList?, Never>?

    /// 规则 JSON：resource-type 与 load-type 语义与 ContentBlockers 等价。
    static let json = """
    [
      {
        "trigger": { "url-filter": "^https?://.+?devtools-detector\\\\.js", "resource-type": ["script"] },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": ".*", "resource-type": ["image"] },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^https?://.+?googleads", "resource-type": ["document"] },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^https?://.+?googlesyndication\\\\.com", "resource-type": ["document"] },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^https?://.+?prestrain\\\\.html", "resource-type": ["document"] },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^https?://.+?prestrain%2Ehtml", "resource-type": ["document"] },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^https?://.+?adtrafficquality", "resource-type": ["document"] },
        "action": { "type": "block" }
      }
    ]
    """

    /// 编译结果在进程内复用；编译失败时返回 nil（放行所有请求，不阻断嗅探）。
    static func ruleList() async -> WKContentRuleList? {
        if let cachedList { return cachedList }
        if let compileTask {
            return await compileTask.value
        }
        let task = Task { () -> WKContentRuleList? in
            do {
                return try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "KazumiVideoSourceBlocker",
                    encodedContentRuleList: json
                )
            } catch {
                KazumiLog.plugin.error("WebView: content rule list compile failed: \(error.localizedDescription)")
                return nil
            }
        }
        compileTask = task
        let list = await task.value
        cachedList = list
        compileTask = nil
        return list
    }
}
