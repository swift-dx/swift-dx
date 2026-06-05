//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DXClickHouse
import Testing

// The per-query timeout is mirrored to the server as a `max_execution_time`
// setting whose value is a decimal number of seconds. That value must use
// a '.' decimal separator on the wire. ClickHouse parses the string, and a
// comma-separated value (which String(format:) would emit on Linux under a
// comma-decimal LC_NUMERIC such as de_DE) is malformed and silently breaks
// the server-side timeout. These tests pin the dot-decimal wire contract.
@Suite("max_execution_time is formatted with a dot decimal separator")
struct MaxExecutionTimeFormatTests {

    private func injectedValue(_ timeout: Duration) -> String {
        let settings = ClickHouseClient.injectMaxExecutionTime(into: .empty, timeout: timeout)
        guard let entry = settings.entries.first(where: { $0.name == "max_execution_time" }) else {
            return "<missing>"
        }
        return entry.value
    }

    @Test("a whole-second timeout formats with a dot, not a comma")
    func wholeSeconds() {
        let value = injectedValue(.seconds(30))
        #expect(value == "30.000")
        #expect(!value.contains(","))
    }

    @Test("a fractional-second timeout above one second keeps millisecond precision")
    func fractionalAboveOne() {
        #expect(injectedValue(.milliseconds(1500)) == "1.500")
        #expect(injectedValue(.milliseconds(2250)) == "2.250")
    }

    @Test("a sub-second timeout uses microsecond precision with a dot")
    func subSecond() {
        let value = injectedValue(.milliseconds(500))
        #expect(value == "0.500000")
        #expect(!value.contains(","))
    }

    @Test("a positive sub-microsecond timeout never rounds to zero (no limit)")
    func subMicrosecondStaysPositive() {
        // ClickHouse reads max_execution_time=0 as NO LIMIT, so a positive
        // deadline must never format to "0.000000" (the six-decimal floor).
        #expect((Double(injectedValue(.nanoseconds(100))) ?? 0) > 0)
        #expect((Double(injectedValue(.nanoseconds(500))) ?? 0) > 0)
    }

    @Test("no max_execution_time is injected for a zero timeout")
    func zeroTimeoutSkips() {
        let settings = ClickHouseClient.injectMaxExecutionTime(into: .empty, timeout: .zero)
        #expect(settings.entries.allSatisfy { $0.name != "max_execution_time" })
    }
}
