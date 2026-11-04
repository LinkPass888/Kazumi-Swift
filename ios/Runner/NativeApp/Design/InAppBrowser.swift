//
//  InAppBrowser.swift
//  Kazumi
//
//  应用内浏览器：链接点了不出 App（Colo 3098）。
//  用系统的 SFSafariViewController——它自带地址栏、返回、分享，也跟系统一样能读
//  用户自己的登录态，比自己塞一个 WKWebView 更省事、也不会把页面样式做歪。
//

import SafariServices
import SwiftUI

struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
