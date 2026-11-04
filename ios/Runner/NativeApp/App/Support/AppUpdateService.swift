//
//  AppUpdateService.swift
//  Kazumi
//
//  启动时的更新检查，顺序与原版一致：
//   1. 应用更新（`SettingsKeys.autoUpdate`）—— 发现新版本时先提示，
//      点「查看」打开 release 页面看更新日志；
//   2. 规则更新（`checkPluginUpdateOnStartup`）—— 应用检查结束后再检查
//      已安装规则，有可更新的再提示。
//
//  检查结果通过 `@Observable` 暴露给根视图，由根视图弹一次提示。
//

import Foundation
import Observation

@MainActor
@Observable
final class AppUpdateService {
    /// 发现新版本时展示的提示内容。
    struct AppUpdateNotice: Identifiable, Sendable {
        let id = UUID()
        let version: String
        let notes: String
    }

    /// 待提示的应用更新；nil 表示没有。
    var appUpdate: AppUpdateNotice?
    /// 待提示的规则更新条数；0 表示没有。
    var pluginUpdateCount = 0

    private var hasChecked = false

    /// 启动时调用一次；已经检查过就直接返回。
    func checkOnLaunch(settings: SettingsStore, plugins: PluginsController) async {
        guard !hasChecked else { return }
        hasChecked = true

        if settings.autoUpdateCheck {
            await checkAppUpdate()
        }
        if settings.checkPluginUpdateOnStartup {
            pluginUpdateCount = await plugins.checkPluginUpdatesOnStartup(enabled: true)
        }
    }

    /// 查询最新 release 并与本地版本比较。
    private func checkAppUpdate() async {
        do {
            var request = URLRequest(url: KazumiAppInfo.latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await KazumiNetworkPolicy.requestSession.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }
            let json = try JSONValue.decode(data)
            let tag = json["tag_name"].stringValue ?? ""
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard !remote.isEmpty else { return }
            guard VersionCompare.needUpdate(local: KazumiAppInfo.version, remote: remote) else {
                return
            }
            let body = json["body"].stringValue ?? ""
            appUpdate = AppUpdateNotice(version: remote, notes: body)
        } catch {
            // 启动检查失败保持静默：不打断用户，设置页里还能手动重试。
            KazumiLog.app.info("启动检查应用更新失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
