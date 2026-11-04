//
//  UsageAgreement.swift
//  Kazumi
//
//  使用约定：正文直接读打包进来的 assets/statements/statements.txt，
//  不在引导里另存一份，App 其它引用同一份文本的页面也就跟着一致。
//

import Foundation

enum UsageAgreement {
    /// 当前这版约定的版本号，欢迎页点「继续」时记下。
    static let version = 1

    enum LoadState: Equatable {
        case loading
        case loaded([String])
        case failed

        var isLoaded: Bool {
            if case .loaded = self { return true }
            return false
        }
    }

    static func load() async -> LoadState {
        guard let url = Bundle.main.url(
            forResource: "statements",
            withExtension: "txt",
            subdirectory: "statements"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failed
        }
        let paragraphs = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty ? .failed : .loaded(paragraphs)
    }
}
