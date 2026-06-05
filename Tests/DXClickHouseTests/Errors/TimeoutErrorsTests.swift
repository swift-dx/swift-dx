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

// Sad-path coverage for `ClickHouseError.queryTimeout`. The case fires
// when a per-query deadline supplied via the `timeout:` parameter
// expires before the server finishes; the local side cancels the
// in-flight query by shutting down the socket (the server interprets
// that as a client cancel) and surfaces the elapsed Duration.
@Suite("ClickHouseError.queryTimeout payload and broker-fire path")
struct ClickHouseTimeoutErrorsTests {

    @Test(".queryTimeout carries the elapsed Duration")
    func queryTimeoutCarriesElapsed() {
        let error: ClickHouseError = .queryTimeout(elapsed: .milliseconds(250))
        switch error {
        case .queryTimeout(let elapsed):
            #expect(elapsed == .milliseconds(250))
        default:
            Issue.record("expected .queryTimeout")
        }
    }

    @Test(".queryTimeout description mentions the timeout")
    func queryTimeoutDescriptionMentionsTimeout() {
        let error: ClickHouseError = .queryTimeout(elapsed: .seconds(3))
        let described = error.description
        #expect(described.lowercased().contains("time"))
    }

    @Test(".queryTimeout is Equatable on the elapsed Duration")
    func queryTimeoutEquatable() {
        let lhs: ClickHouseError = .queryTimeout(elapsed: .milliseconds(100))
        let rhs: ClickHouseError = .queryTimeout(elapsed: .milliseconds(100))
        let other: ClickHouseError = .queryTimeout(elapsed: .milliseconds(200))
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("ClickHouseQueryDefaults expose sensible per-operation defaults")
    func defaultsValues() {
        #expect(ClickHouseQueryDefaults.selectTimeout == .seconds(30))
        #expect(ClickHouseQueryDefaults.insertTimeout == .seconds(60))
        #expect(ClickHouseQueryDefaults.pingTimeout == .seconds(5))
        #expect(ClickHouseQueryDefaults.streamTimeout == .seconds(300))
    }

    @Test("queryTimeout case ordering with other cases is stable for switch dispatch")
    func queryTimeoutCaseOrdering() {
        let error: ClickHouseError = .queryTimeout(elapsed: .milliseconds(0))
        var observed = "other"
        switch error {
        case .queryTimeout:
            observed = "timeout"
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError,
             .queryFailed, .reconnectExhausted, .endpointsExhausted:
            observed = "other"
        }
        #expect(observed == "timeout")
    }

    // Live broker-fire test: drive a deliberately slow query against
    // the running ClickHouse with a short client-side timeout. The
    // client must surface `.queryTimeout` within a reasonable tolerance
    // of the configured deadline, and the underlying socket should be
    // safely closed so the next operation reconnects cleanly.
    @Test(
        "Live SELECT exceeding the timeout surfaces .queryTimeout within tolerance",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func liveSelectTimeoutFiresWithinTolerance() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let password = ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
        let client = try await ClickHouseClient(host: host, port: port, password: password)
        defer { Task { await client.close() } }

        let start = Date()
        let outcome: TimeoutOutcome = await Self.runUntilTimeout(client: client)
        let elapsed = Date().timeIntervalSince(start)

        switch outcome {
        case .timeout:
            // Allow up to 3 seconds of grace on top of the configured
            // 300ms deadline. The server-side `max_execution_time`
            // setting and the socket-shutdown race both add overhead.
            #expect(elapsed < 3.0, "timeout fired but took \(elapsed)s")
        case .queryFailedWithCode(let code):
            // The server-side `max_execution_time` setting we inject
            // may fire first; ClickHouse reports this as a regular
            // query exception. Both outcomes are valid bounded
            // surface for an over-budget query.
            #expect(code != 0)
        case .completed:
            Issue.record("expected the long-running query to time out, but it completed")
        case .unexpected(let description):
            Issue.record("expected .queryTimeout or .queryFailed, got \(description)")
        }
    }

    @Test(
        "Live timeout cancels the in-flight query and the connection survives",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func liveTimeoutLeavesConnectionUsable() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let password = ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
        let client = try await ClickHouseClient(host: host, port: port, password: password)
        defer { Task { await client.close() } }

        let outcome = await Self.runUntilTimeout(client: client)
        switch outcome {
        case .timeout, .queryFailedWithCode:
            break
        case .completed:
            Issue.record("expected the long-running query to time out")
        case .unexpected(let description):
            Issue.record("unexpected outcome: \(description)")
        }

        // After the timeout the client's underlying socket has been
        // shut down by the timeout-cancel path; the reconnect layer
        // should restore the connection and a follow-up scalar must
        // succeed without manual recovery.
        let follow = try await client.scalar("SELECT toUInt64(7)", as: UInt64.self)
        #expect(follow == 7)
    }

    // Captures the outcome of a deliberately-over-budget query through
    // discrete cases so call sites can switch instead of branching on
    // an Optional ClickHouseError accumulator pattern that triggers a
    // SILGen bug on Swift 6.3 (typed-throws + Optional payload).
    private enum TimeoutOutcome: Sendable {
        case timeout
        case queryFailedWithCode(Int32)
        case completed
        case unexpected(String)
    }

    private static func runUntilTimeout(client: ClickHouseClient) async -> TimeoutOutcome {
        do {
            _ = try await client.scalar(
                "SELECT count() FROM numbers(10000000000)",
                as: UInt64.self,
                timeout: .milliseconds(300)
            )
            return .completed
        } catch let error {
            switch error {
            case .queryTimeout:
                return .timeout
            case .queryFailed(let exception):
                return .queryFailedWithCode(exception.code)
            case .connectionFailed, .socketIOFailed, .unexpectedEOF,
                 .protocolError, .reconnectExhausted, .endpointsExhausted:
                return .unexpected(String(describing: error))
            }
        }
    }
}
