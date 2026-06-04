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

// The operational events the client emits. Each case names a point in the
// connection or query lifecycle that an operator watches: opening and losing
// connections, query completion and failure with timing, transient-failure
// retries, and pool exhaustion. PostgresLogger renders these into the caller's
// injected swift-log Logger; this type stays internal so it is not a public
// contract.
enum PostgresLogEvent: Sendable {

    case connecting(host: String, port: Int)
    case connected(host: String, port: Int, durationNanos: UInt64)
    case connectFailed(host: String, port: Int, reason: String)
    case queryStarted(statement: String)
    case queryCompleted(statement: String, durationNanos: UInt64)
    case queryFailed(statement: String, reason: String, durationNanos: UInt64)
    case retryScheduled(reason: String, delayNanos: UInt64)
    case poolExhausted(maxConnections: Int)
    case poolShutdown
}
