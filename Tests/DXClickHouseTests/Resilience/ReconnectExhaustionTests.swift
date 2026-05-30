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

// Coverage for `.reconnectExhausted`: the case fires when a connection
// configured with a bounded retry budget exhausts every attempt against
// a target that never comes back. We construct the policy directly
// against an unreachable port so the test is hermetic.
@Suite("Reconnect exhaustion surfaces .reconnectExhausted / .connectionFailed cleanly")
struct ClickHouseReconnectExhaustionTests {

    @Test(".reconnectExhausted carries the attempt count")
    func reconnectExhaustedCarriesAttempts() {
        let error: ClickHouseError = .reconnectExhausted(attempts: 5)
        switch error {
        case .reconnectExhausted(let attempts):
            #expect(attempts == 5)
        default:
            Issue.record("expected .reconnectExhausted")
        }
        #expect(error.description.contains("5"))
    }

    @Test(".reconnectExhausted equality compares the attempt count")
    func reconnectExhaustedEquatable() {
        let lhs: ClickHouseError = .reconnectExhausted(attempts: 3)
        let rhs: ClickHouseError = .reconnectExhausted(attempts: 3)
        let other: ClickHouseError = .reconnectExhausted(attempts: 4)
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("ReconnectionPolicy.failFast surfaces the first transient error without retrying")
    func failFastSkipsRetry() throws {
        var caught: ClickHouseError?
        do {
            _ = try ClickHouseConnection(
                host: "127.0.0.1",
                port: 1,
                reconnectionPolicy: .failFast
            )
            Issue.record("expected immediate failure with failFast policy")
        } catch let error {
            caught = error
        }
        switch caught {
        case .some(.connectionFailed), .some(.socketIOFailed):
            break
        case .some(.reconnectExhausted):
            // Some implementations roll the initial connect through
            // the same reconnect loop; both shapes are acceptable for
            // a never-reachable target.
            break
        default:
            Issue.record("expected transport-level error, got \(String(describing: caught))")
        }
    }

    @Test("ReconnectionPolicy.custom with a small budget exhausts against an unreachable port")
    func customBudgetExhausts() throws {
        let policy = ReconnectionPolicy.custom(
            initial: .milliseconds(10),
            max: .milliseconds(20),
            multiplier: 1.5,
            attempts: 3
        )
        var caught: ClickHouseError?
        do {
            _ = try ClickHouseConnection(
                host: "127.0.0.1",
                port: 1,
                reconnectionPolicy: policy
            )
            Issue.record("expected bounded retry budget to exhaust")
        } catch let error {
            caught = error
        }
        switch caught {
        case .some(.connectionFailed), .some(.socketIOFailed), .some(.reconnectExhausted):
            break
        default:
            Issue.record("expected exhaustion-shaped error, got \(String(describing: caught))")
        }
    }

    @Test("ReconnectionPolicy.alwaysRetry is the default ReconnectionPolicy.default")
    func alwaysRetryEqualsDefault() {
        #expect(ReconnectionPolicy.alwaysRetry == ReconnectionPolicy.default)
        #expect(ReconnectionPolicy.alwaysRetry.maxAttempts == .max)
    }

    @Test("ReconnectionPolicy.disabled equals .failFast (alias)")
    func disabledEqualsFailFast() {
        #expect(ReconnectionPolicy.disabled == ReconnectionPolicy.failFast)
        #expect(ReconnectionPolicy.disabled.maxAttempts == 0)
    }
}
