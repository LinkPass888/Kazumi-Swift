//
//  LogExportTests.swift
//  RunnerTests
//

import Foundation
import Testing
@testable import Runner

struct LogExportTests {
    // 2024-01-01 00:00:00 UTC. Exact binary fractions avoid fixture rounding.
    private let start = Date(timeIntervalSince1970: 1_704_067_200)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test("Copy export keeps chronological order, Gregorian date, and milliseconds")
    func chronologicalTimestamps() {
        let entries = [
            entry("first", after: 0.125),
            entry("second", after: 0.5),
            entry("third", after: 1)
        ]

        #expect(KazumiLogExport.text(from: entries, timeZone: utc) == """
        [2024-01-01 00:00:00.125 +0000] first
        [2024-01-01 00:00:00.500 +0000] second
        [2024-01-01 00:00:01.000 +0000] third
        """)
    }

    @Test("Copy export preserves snapshot order when timestamps are equal")
    func equalTimestampOrder() {
        let entries = [entry("z", after: 0), entry("a", after: 0)]
        #expect(KazumiLogExport.text(from: entries, timeZone: utc) == """
        [2024-01-01 00:00:00.000 +0000] z
        [2024-01-01 00:00:00.000 +0000] a
        """)
    }

    @Test("Copy export includes the chosen timezone, including fractional-hour offsets")
    func timezoneOffsets() {
        let entries = [entry("event", after: 0.875)]
        let east = TimeZone(secondsFromGMT: 5 * 3600 + 45 * 60)!
        let west = TimeZone(secondsFromGMT: -(3 * 3600 + 30 * 60))!

        #expect(KazumiLogExport.text(from: entries, timeZone: east)
            == "[2024-01-01 05:45:00.875 +0545] event")
        #expect(KazumiLogExport.text(from: entries, timeZone: west)
            == "[2023-12-31 20:30:00.875 -0330] event")
        // A later export must not retain another export's timezone.
        #expect(KazumiLogExport.text(from: entries, timeZone: utc)
            == "[2024-01-01 00:00:00.875 +0000] event")
    }

    @Test("Every embedded line retains its entry timestamp, including blank lines")
    func multilineMessages() {
        let entries = [
            entry("first\r\nsecond\n\nthird\rfourth\u{2028}fifth\n", after: 0.125),
            entry("next entry", after: 1)
        ]
        let prefix = "[2024-01-01 00:00:00.125 +0000] "
        let expectedLines = ["first", "second", "", "third", "fourth", "fifth", ""]
            .map { prefix + $0 }
            + ["[2024-01-01 00:00:01.000 +0000] next entry"]

        #expect(KazumiLogExport.text(from: entries, timeZone: utc)
            == expectedLines.joined(separator: "\n"))
    }

    @Test("Empty exports and empty messages have distinct output")
    func emptyInputs() {
        #expect(KazumiLogExport.text(from: [], timeZone: utc).isEmpty)
        #expect(KazumiLogExport.text(from: [entry("", after: 0)], timeZone: utc)
            == "[2024-01-01 00:00:00.000 +0000] ")
    }

    private func entry(_ message: String, after seconds: TimeInterval) -> KazumiLogBuffer.Entry {
        KazumiLogBuffer.Entry(category: .player, timestamp: start.addingTimeInterval(seconds), message: message)
    }
}
