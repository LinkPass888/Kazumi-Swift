import Foundation
import Testing
@testable import Runner

struct BangumiSearchParamsTests {
    @Test("无 Token 的搜索参数明确排除 NSFW")
    func searchExcludesNSFWByDefault() {
        let params = BangumiAPI.searchParams(keyword: "测试")
        #expect(params["filter"]["nsfw"].boolValue == false)
    }

    @Test("带 Token 的主动搜索省略 NSFW 字段")
    func authenticatedSearchIncludesBothKinds() {
        let params = BangumiAPI.searchParams(keyword: "测试", includeNSFW: true)
        #expect(!params["filter"]["nsfw"].exists)
    }

    @Test("中文字段或中文原名都会保留")
    func chineseNameDetection() {
        #expect(BangumiAPI.hasChineseName(.object([
            "name": .string("Japanese Title"),
            "name_cn": .string("中文名"),
        ])))
        #expect(BangumiAPI.hasChineseName(.object([
            "name": .string("罗小黑战记 学前篇"),
            "name_cn": .string(""),
        ])))
        #expect(!BangumiAPI.hasChineseName(.object([
            "name": .string("Japanese Title"),
            "name_cn": .string(""),
        ])))
        #expect(!BangumiAPI.hasChineseName(.object([
            "name": .string("ゲルぴよ 第2期"),
            "name_cn": .string(""),
        ])))
    }

    @Test("NSFW 搜索开关默认关闭并随设置备份恢复")
    @MainActor
    func settingBacksUpAndRestores() {
        let sourceName = "RunnerTests.NSFW.Source.\(UUID().uuidString)"
        let targetName = "RunnerTests.NSFW.Target.\(UUID().uuidString)"
        let sourceDefaults = UserDefaults(suiteName: sourceName)!
        let targetDefaults = UserDefaults(suiteName: targetName)!
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            targetDefaults.removePersistentDomain(forName: targetName)
        }

        let source = SettingsStore(defaults: sourceDefaults)
        #expect(!source.searchNSFWEnabled)
        source.searchNSFWEnabled = true
        let backup = source.backupSnapshot(omitCredentials: false)
        #expect(backup[SettingsKey.searchNSFWEnabled]?.boolValue == true)

        let target = SettingsStore(defaults: targetDefaults)
        target.applyBackup(backup)
        #expect(target.searchNSFWEnabled)
    }
}
