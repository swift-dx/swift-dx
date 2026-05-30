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

import DXClickHouse
import Foundation
import Testing

// Unit tests for the per-query timeout default constants and the
// ClickHouseError.queryTimeout case. Broker-level fault injection lives
// in the integration suite (DXClickHouseIntegration) where a live
// ClickHouse instance is available to back a slow-query scenario.
@Suite("ClickHouse per-query timeout defaults and error shape")
struct ClickHouseTimeoutTests {

    @Test("ClickHouseQueryDefaults exposes sensible defaults for every operation shape")
    func defaultsHaveExpectedValues() {
        #expect(ClickHouseQueryDefaults.selectTimeout == .seconds(30))
        #expect(ClickHouseQueryDefaults.insertTimeout == .seconds(60))
        #expect(ClickHouseQueryDefaults.pingTimeout == .seconds(5))
        #expect(ClickHouseQueryDefaults.streamTimeout == .seconds(300))
    }

    @Test("ClickHouseError.queryTimeout carries the elapsed Duration")
    func queryTimeoutCarriesElapsed() {
        let observed: ClickHouseError = .queryTimeout(elapsed: .milliseconds(123))
        switch observed {
        case .queryTimeout(let elapsed):
            #expect(elapsed == .milliseconds(123))
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError, .queryFailed, .reconnectExhausted, .endpointsExhausted:
            Issue.record("expected .queryTimeout, got \(observed)")
        }
    }

    @Test("ClickHouseError.queryTimeout description mentions the duration")
    func queryTimeoutDescriptionMentionsDuration() {
        let error: ClickHouseError = .queryTimeout(elapsed: .seconds(2))
        #expect(error.description.contains("timed out"))
    }

    @Test("ClickHouseError.queryTimeout is Equatable on the elapsed Duration")
    func queryTimeoutEquatableOnElapsed() {
        let lhs: ClickHouseError = .queryTimeout(elapsed: .milliseconds(100))
        let rhs: ClickHouseError = .queryTimeout(elapsed: .milliseconds(100))
        let other: ClickHouseError = .queryTimeout(elapsed: .milliseconds(200))
        #expect(lhs == rhs)
        #expect(lhs != other)
    }
}
