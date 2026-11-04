import Foundation
import Libmpv
import Testing

/// Exercises the actual linked libmpv without media, render contexts or network access.
struct MPVLogSubscriptionTests {
    @Test("日志订阅拒绝复合等级，并能收到真实内核事件")
    func realCoreLogSubscription() throws {
        let handle = try #require(mpv_create())
        defer { mpv_terminate_destroy(handle) }
        #expect(mpv_set_option_string(handle, "config", "no") >= 0)
        #expect(mpv_set_option_string(handle, "terminal", "no") >= 0)
        #expect(mpv_initialize(handle) >= 0)

        let invalid = mpv_request_log_messages(handle, "warn,ffmpeg=debug,hwdec=v,gpu=v,vo=v")
        #expect(invalid == MPV_ERROR_INVALID_PARAMETER.rawValue)
        let valid = mpv_request_log_messages(handle, "v")
        #expect(valid >= 0)

        let token = "KAZUMI_DIAGNOSTIC_PROBE"
        let command = "print-text \(token)"
        #expect(mpv_command_string(handle, command) >= 0)
        var sawToken = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !sawToken {
            guard let event = mpv_wait_event(handle, 0.05) else { continue }
            guard event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
                  let raw = event.pointee.data else { continue }
            let message = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            sawToken = String(cString: message.text).contains(token)
        }
        #expect(sawToken)
    }
}
