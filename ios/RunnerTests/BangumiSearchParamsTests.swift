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
    }
}
