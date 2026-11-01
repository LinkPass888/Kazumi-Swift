//
//  RunnerTests.swift
//  RunnerTests
//
//  原生工程冒烟测试：验证包信息与内置资源（Anime4K 着色器）确实打进了 Bundle。
//

import Foundation
import Testing
@testable import Runner

struct RunnerTests {
    @Test("应用包信息保持原样")
    func hostAppIdentity() {
        let host = Bundle(for: BundleToken.self)
        #expect(host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Kazumi")
        #expect(host.object(forInfoDictionaryKey: "CFBundleName") as? String == "kazumi")
    }

    @Test("Anime4K 着色器随包分发")
    func anime4kShadersBundled() {
        let host = Bundle(for: BundleToken.self)
        let shader = host.url(
            forResource: "Anime4K_Upscale_CNN_x2_M",
            withExtension: "glsl",
            subdirectory: "shaders"
        )
        #expect(shader != nil)
    }
}

private final class BundleToken {}
