import Foundation
import ImageIO
import Testing
import UIKit
@testable import Runner

struct PlayerScreenshotMetadataTests {
    @Test("截图 PNG 写入三条 IPTC 关键词")
    func writesKeywords() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kazumi-shot-test-\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let pngData = try #require(image.pngData())
        try pngData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let expected = ["番剧名", "第3集", "12:34"]
        let resultURL = try PlayerScreenshot.fileByWritingKeywords(expected, toPNGAt: sourceURL)
        defer { try? FileManager.default.removeItem(at: resultURL) }

        let source = try #require(CGImageSourceCreateWithURL(resultURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        let actual = try #require(iptc[kCGImagePropertyIPTCKeywords as String] as? [String])
        #expect(actual == expected)
    }

    @Test("截图关键词设置默认开启并随备份恢复")
    @MainActor
    func settingBacksUpAndRestores() {
        let sourceName = "RunnerTests.Screenshot.Source.\(UUID().uuidString)"
        let targetName = "RunnerTests.Screenshot.Target.\(UUID().uuidString)"
        let sourceDefaults = UserDefaults(suiteName: sourceName)!
        let targetDefaults = UserDefaults(suiteName: targetName)!
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            targetDefaults.removePersistentDomain(forName: targetName)
        }

        let source = SettingsStore(defaults: sourceDefaults)
        #expect(source.screenshotKeywordsEnabled)
        source.screenshotKeywordsEnabled = false
        let backup = source.backupSnapshot(omitCredentials: false)
        #expect(backup[SettingsKey.screenshotKeywordsEnabled]?.boolValue == false)

        let target = SettingsStore(defaults: targetDefaults)
        target.applyBackup(backup)
        #expect(target.screenshotKeywordsEnabled == false)
    }
}
