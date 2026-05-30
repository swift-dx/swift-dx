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

import NIOCore

// How the client rides out transient trouble so callers never have to. Every
// operation is bounded by `requestTimeout`: acquiring a connection, waiting out a
// reconnect, and the command round-trip all count against it, and when it elapses
// the operation throws `RedisError.timedOut`. The client never reports a success
// it did not receive from the server.
//
// While the server is unreachable, reconnection is a background concern paced by
// `reconnectBaseDelay` and `reconnectMaxDelay`: attempts back off from the base
// toward the max so the client neither spins on the CPU nor stampedes the server,
// and a single attempt is in flight at a time. A burst of callers beyond the pool
// size waits for a connection to free rather than failing immediately.
//
// `retryTransientFailures` controls whether a transient failure (a dropped
// connection, a brief restart, the pool momentarily full) is retried within the
// timeout window. Retried operations have at-least-once semantics if a connection
// drops after a command was written but before its reply arrived: the command may
// have been applied and is sent again. This is harmless for idempotent commands
// (GET, SET, DEL, most reads); for non-idempotent commands (INCR, LPUSH) use
// `.disabled` to fail on the first transient error and handle it explicitly. The
// timeout still applies; only the retry is turned off.
public struct RedisResilience: Sendable, Hashable {

    public let requestTimeout: TimeAmount
    public let retryTransientFailures: Bool
    public let reconnectBaseDelay: TimeAmount
    public let reconnectMaxDelay: TimeAmount

    public init(requestTimeout: TimeAmount = .seconds(10), retryTransientFailures: Bool = true, reconnectBaseDelay: TimeAmount = .milliseconds(20), reconnectMaxDelay: TimeAmount = .seconds(1)) {
        self.requestTimeout = requestTimeout
        self.retryTransientFailures = retryTransientFailures
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
    }

    // Turn off transient-failure retries: every operation fails on the first
    // transient error instead of retrying within the timeout window. Use for
    // non-idempotent command sequences where an at-least-once retry is
    // unacceptable. The request timeout still applies; only the retry is off.
    public static var disabled: RedisResilience {
        RedisResilience(retryTransientFailures: false)
    }
}
