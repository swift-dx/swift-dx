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

// Operational events the client emits at connection and command lifecycle points.
// RedisLogger renders these into the caller's injected swift-log Logger; the type
// stays internal so it is not a public contract. The operation label decodes its
// verb lazily, so building an event off the hot path costs nothing until a log
// line is actually written.
enum RedisLogEvent: Sendable {

    case connecting(host: String, port: Int)
    case connected(host: String, port: Int, durationNanos: UInt64)
    case connectFailed(host: String, port: Int, reason: String)
    case commandStarted(label: RedisOperationLabel)
    case commandCompleted(label: RedisOperationLabel, durationNanos: UInt64)
    case commandFailed(label: RedisOperationLabel, reason: String, durationNanos: UInt64)
    case retryScheduled(reason: String, delayNanos: UInt64)
    case poolExhausted(maxConnections: Int)
    case poolShutdown
}
