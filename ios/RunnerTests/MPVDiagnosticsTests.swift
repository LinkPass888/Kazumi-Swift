import Foundation
import Testing
@testable import Runner

struct MPVDiagnosticsTests {
    @Test("保留解码、色彩和嵌套渲染日志")
    func rendererAllowlist() {
        var diagnostics = MPVDiagnostics()
        for prefix in ["vd", "vd/hwdec", "vo/libmpv", "vo/libmpv/gpu", "vo/libmpv/gpu/hwdec", "libmpv_render", "libmpv_render/gpu", "hwdec"] {
            let result = diagnostics.receive(prefix: prefix, level: "v", text: "Using hardware decoding (videotoolbox), format=nv12, matrix=bt.709")
            #expect(result.line?.hasPrefix("[\(prefix)] v ") == true)
            #expect(result.line?.contains("videotoolbox") == true)
            #expect(result.errorText == nil)
        }
        let range = diagnostics.receive(prefix: "vo/libmpv", level: "info", text: "Color range: limited")
        #expect(range.line?.contains("Color range: limited") == true)
        let config = diagnostics.receive(prefix: "vd", level: "v", text: "Decoder format: 1920x1080 nv12")
        #expect(config.line?.contains("1920x1080 nv12") == true)
    }

    @Test("拒绝无关 verbose、debug 和 HTTP 转储，包括错误级别的请求头")
    func rejectsHTTPAndUnrelatedVerbose() {
        var diagnostics = MPVDiagnostics()
        for prefix in ["ffmpeg", "ffmpeg/http", "demux", "vo/libmpv-other", "vd-other", "gpu"] {
            #expect(diagnostics.receive(prefix: prefix, level: "v", text: "unrelated diagnostic").line == nil)
        }
        #expect(diagnostics.receive(prefix: "vd", level: "debug", text: "unneeded detail").line == nil)
        #expect(diagnostics.receive(prefix: "ffmpeg/http", level: "error", text: " FAKE_HEADER_CONTINUATION").line == nil)
        for text in [
            "request: GET /video?fixture=FAKE_REQUEST HTTP/1.1",
            "HTTP/1.1 403 Forbidden\r\nX-Fixture: FAKE_VALUE",
            "request headers\nCookie: session=FAKE_COOKIE\n folded-secret",
            "Authorization: Bearer FAKE_AUTH",
            "Proxy-Authorization: Basic FAKE_PROXY",
            "Set-Cookie: session=FAKE_RESPONSE",
            "http-header-fields=Cookie: FAKE_OPTION",
            "X-Custom-Key: FAKE_CUSTOM",
            "Custom-Auth: FAKE_CUSTOM_HEADER",
            #"request: GET /fixture HTTP/1.1\r\nCookie: FAKE_ESCAPED"#
        ] {
            for level in ["v", "warn", "error", "fatal"] {
                let result = diagnostics.receive(prefix: "vo/libmpv/gpu", level: level, text: text)
                #expect(result.line == nil)
                #expect(result.errorText == nil)
            }
        }
    }

    @Test("签名 URL、代理 userinfo、编码 URL 和令牌均不回显")
    func redactsSecrets() {
        for input in [
            "Failed to open https://fixture-user:FAKE_PASSWORD@media.invalid/FAKE_PATH?expires=FAKE_QUERY#FAKE_FRAGMENT",
            "Failed to open https://fixture-user:'FAKE_QUOTED@media.invalid/FAKE_PATH?value=FAKE_QUERY",
            "Failed to open https://media.invalid/it's/FAKE_PATH?value=FAKE_QUERY",
            "open //media.invalid/FAKE_PATH?value=FAKE_QUERY",
            #"open https:\/\/media.invalid\/FAKE_PATH?value=FAKE_QUERY"#,
            "open https%3A%2F%2Fmedia.invalid%2FFAKE_PATH%3Fvalue%3DFAKE_QUERY",
            "decoder token=FAKE_TOKEN",
            #"{"access_token":"FAKE_JSON"}"#,
            "api-key: FAKE_API_KEY",
            "Bearer FAKE_BEARER",
            "Cookie: session=FAKE_COOKIE\r\n folded FAKE_CONTINUATION",
            "decoder failed\nAuthorization: Basic FAKE_AUTH\nFAKE_CONTINUATION",
            "User-Agent: FAKE_UA\nReferer: https://media.invalid/FAKE_REFERER"
        ] {
            let safe = MPVDiagnostics.sanitize(input)
            #expect(!safe.contains("FAKE_"))
            #expect(!safe.contains("fixture-user"))
            #expect(!safe.contains("media.invalid"))
            #expect(!safe.contains("\n"))
            #expect(!safe.contains("\r"))
        }
        #expect(MPVDiagnostics.sanitize("open https://media.invalid/private") == "open [URL已隐藏]")
    }

    @Test("外部模块错误和摘要先脱敏，警告也受限")
    func sanitizedErrorSummary() {
        var diagnostics = MPVDiagnostics(nonErrorLimit: 0)
        let error = diagnostics.receive(prefix: "ffmpeg", level: "error", text: "Failed to open https://media.invalid/FAKE_SIGNED?value=FAKE_QUERY\nInvalid data")
        #expect(error.line?.hasPrefix("[ffmpeg] error ") == true)
        #expect(error.errorText == "Failed to open [URL已隐藏] Invalid data")
        #expect(error.line?.contains("FAKE_") == false)
        let fatal = diagnostics.receive(prefix: "demux", level: "fatal", text: "token=FAKE_TOKEN")
        #expect(fatal.errorText == "[敏感诊断已隐藏]")
        #expect(diagnostics.receive(prefix: "demux", level: "warn", text: "Failed to seek").errorText == nil)
    }

    @Test("首条接收证明只有安全前缀和级别，不含正文；重置不重复证明")
    func firstReceipt() {
        var diagnostics = MPVDiagnostics()
        let first = diagnostics.receive(prefix: "ffmpeg/http", level: "v", text: "Cookie: FAKE_COOKIE")
        #expect(first.receipt == "内核日志已收到：[ffmpeg/http] 级别=v")
        #expect(first.line == nil)
        diagnostics.resetPlayback()
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "decoder ready").receipt == nil)
        var hostile = MPVDiagnostics()
        let unsafe = hostile.receive(prefix: "vd\nCookie: FAKE_PREFIX", level: "error\nFAKE_LEVEL", text: "FAKE_BODY")
        #expect(unsafe.receipt == "内核日志已收到：[未知] 级别=?")
        #expect(unsafe.line == nil)
    }

    @Test("去重、逐帧过滤、每集限额和重置；错误不受配额影响")
    func budgetAndReset() {
        var diagnostics = MPVDiagnostics(nonErrorLimit: 2, perSourceLimit: 2)
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "frame pts=1.0").line == nil)
        #expect(diagnostics.receive(prefix: "vo/libmpv", level: "v", text: "Rendering frame 20").line == nil)
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "decoder ready").line != nil)
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "decoder ready").line == nil)
        #expect(diagnostics.receive(prefix: "vo/libmpv", level: "v", text: "format=nv12").line != nil)
        #expect(diagnostics.receive(prefix: "vd", level: "warn", text: "decoder fallback").line == "内核诊断已限流（保留错误）")
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "format=yuv420p").line == nil)
        #expect(diagnostics.receive(prefix: "vd", level: "error", text: "decoder failed").errorText == "decoder failed")
        diagnostics.resetPlayback()
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "decoder ready").line != nil)
    }

    @Test("单一来源不能挤掉另一来源，默认配额小于日志环容量")
    func sourceBudget() {
        var diagnostics = MPVDiagnostics()
        var count = 0
        for index in 0..<300 {
            if diagnostics.receive(prefix: "vo/libmpv/gpu", level: "v", text: "GL capability \(index)").line != nil { count += 1 }
        }
        #expect(count == 25) // 24 条样本 + 一条限流说明。
        #expect(diagnostics.receive(prefix: "vd", level: "v", text: "Using hardware decoding (videotoolbox)").line != nil)
    }

    @Test("多行合并、控制字符剔除，超长日志只截断脱敏后的文本")
    func boundedSingleLine() {
        #expect(MPVDiagnostics.sanitize("nv12\r\n bt.709\t limited\u{0}") == "nv12 bt.709 limited")
        let long = String(repeating: "a", count: 800) + " https://media.invalid/FAKE_PATH"
        let safe = MPVDiagnostics.sanitize(long)
        #expect(safe.count == 601)
        #expect(!safe.contains("FAKE_"))
        let hidden = String(repeating: "a", count: 800) + "\nCookie: FAKE_COOKIE\nFAKE_FOLDED"
        #expect(MPVDiagnostics.sanitize(hidden) == "[敏感诊断已隐藏]")
    }
}
