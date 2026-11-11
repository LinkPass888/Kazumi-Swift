//
//  PlayerOfflinePlaybackTests.swift
//  RunnerTests
//
//  离线播放里两块纯逻辑：在线列表抓不到时用下载记录拼选集（#27 / Colo v3 第 9 条），
//  以及播放源还没重建出来时记录归属哪条规则（别写出空白历史、丢掉离线进度）。
//

import Testing
@testable import Runner

struct PlayerOfflinePlaybackTests {
    @Test("下载记录拼出的选集按集号对齐，没下到的留空")
    func offlineEpisodeListPadsGaps() {
        let list = PlayerController.offlineEpisodeList(numbers: [3, 1, 4])
        #expect(list == ["local://1", "", "local://3", "local://4"])
    }

    @Test("没有下载记录时选集也是空的")
    func offlineEpisodeListEmpty() {
        #expect(PlayerController.offlineEpisodeList(numbers: []).isEmpty)
    }

    @Test("重复和非法集号既不撑长列表也不挪位置")
    func offlineEpisodeListIgnoresDuplicatesAndIllegalNumbers() {
        let list = PlayerController.offlineEpisodeList(numbers: [2, 2, 0, -1])
        #expect(list == ["", "local://2"])
    }

    @Test("列表长度跟着最大的下载集号走，不按下载条数")
    func offlineEpisodeListLengthFollowsLastNumber() {
        let list = PlayerController.offlineEpisodeList(numbers: [8])
        #expect(list.count == 8)
        #expect(list.filter { !$0.isEmpty } == ["local://8"])
    }

    @Test("断网离线播放时规则名退回历史卡片上那条")
    func offlinePlaybackKeepsHistoryRule() {
        #expect(PlayerController.resolvedPluginName(sourceName: nil, resumeRule: "规则B") == "规则B")
        #expect(PlayerController.resolvedPluginName(sourceName: "", resumeRule: "规则B") == "规则B")
    }

    @Test("卡片和播放源都带规则名时以卡片为准，详情页没有卡片时用播放源")
    func ruleNameSelection() {
        #expect(PlayerController.resolvedPluginName(sourceName: "规则A", resumeRule: "规则B") == "规则B")
        #expect(PlayerController.resolvedPluginName(sourceName: "规则A", resumeRule: nil) == "规则A")
        #expect(PlayerController.resolvedPluginName(sourceName: nil, resumeRule: nil) == "")
    }
}
