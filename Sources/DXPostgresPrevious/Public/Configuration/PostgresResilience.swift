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

// How the client rides out transient trouble so a caller does not have to. When
// `retryTransientFailures` is on (the default), a single query that fails for a
// connection-layer reason — a dropped or half-open connection, a brief server
// restart, a momentarily full pool — is retried on a freshly acquired connection,
// backing off from `reconnectBaseDelay` toward `reconnectMaxDelay` between
// attempts, until the request timeout budget elapses. A retried query has
// at-least-once semantics: if a connection drops after the query reached the
// server but before its reply, the query may have applied and is sent again.
// That is harmless for reads and other idempotent statements; for a
// non-idempotent single statement run outside a transaction, use `.disabled` and
// handle the failure explicitly. The request timeout still bounds the operation;
// only the retry is turned off. Multi-statement transactions, COPY, and streamed
// queries are never auto-retried, because a partial replay would be unsafe.
public struct PostgresResilience: Sendable, Hashable {

    public let retryTransientFailures: Bool
    public let reconnectBaseDelay: TimeAmount
    public let reconnectMaxDelay: TimeAmount

    public init(retryTransientFailures: Bool = true, reconnectBaseDelay: TimeAmount = .milliseconds(20), reconnectMaxDelay: TimeAmount = .seconds(1)) {
        self.retryTransientFailures = retryTransientFailures
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
    }

    // Turns off transient-failure retries: a query fails on the first transient
    // error instead of retrying. The request timeout still applies.
    public static var disabled: PostgresResilience {
        PostgresResilience(retryTransientFailures: false)
    }
}
