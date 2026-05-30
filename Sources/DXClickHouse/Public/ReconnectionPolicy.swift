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

/// Reconnection behaviour applied to a single ClickHouse connection.
///
/// When a send-side transient failure (EPIPE / ECONNRESET) or a pre-send
/// unexpected EOF is detected, the connection layer transparently closes
/// the socket, sleeps for the exponential backoff between
/// ``initialBackoff`` and ``maxBackoff``, and re-handshakes up to
/// ``maxAttempts`` times before bubbling
/// `ClickHouseError.reconnectExhausted` to the caller.
///
/// ## Default
///
/// The default value is ``alwaysRetry``: a connection keeps trying to
/// reconnect indefinitely with exponential backoff capped at 5 seconds.
/// Callers that prefer to surface a transient I/O failure to the
/// application instead can override with ``failFast`` or
/// ``custom(initial:max:multiplier:attempts:)``.
///
/// ```swift
/// // Always-retry default (the value used when nothing is passed).
/// let connection = try await AsyncClickHouseConnection(host: ..., port: ...)
///
/// // Opt out, surface the I/O error on the first failure.
/// let connection = try await AsyncClickHouseConnection(
///     host: ..., port: ...,
///     reconnectionPolicy: .failFast
/// )
///
/// // Bounded budget with custom backoff curve.
/// let connection = try await AsyncClickHouseConnection(
///     host: ..., port: ...,
///     reconnectionPolicy: .custom(
///         initial: .seconds(1),
///         max: .seconds(60),
///         multiplier: 2.0,
///         attempts: 5
///     )
/// )
/// ```
///
/// `maxAttempts == 0` disables reconnect: the first I/O failure surfaces
/// as `ClickHouseError.socketIOFailed` or `.unexpectedEOF` without any
/// retry. `maxAttempts == Int.max` is treated as the unbounded
/// always-retry budget.
public struct ReconnectionPolicy: Sendable, Equatable {

    /// Sentinel that ``alwaysRetry`` (and any caller-supplied unbounded
    /// budget) places in ``maxAttempts``. The reconnect loop interprets
    /// this value as "retry indefinitely with exponential backoff".
    public static let unboundedAttempts: Int = .max

    public let maxAttempts: Int
    public let initialBackoff: Duration
    public let maxBackoff: Duration
    public let backoffMultiplier: Double

    /// Library default. Always-retry-with-exponential-backoff: 100ms
    /// initial backoff, doubling each attempt up to a 5-second cap, no
    /// upper bound on the number of attempts. This is the value every
    /// public connect path uses when no policy is supplied.
    public static let alwaysRetry = ReconnectionPolicy(
        maxAttempts: unboundedAttempts,
        initialBackoff: .milliseconds(100),
        maxBackoff: .seconds(5),
        backoffMultiplier: 2.0
    )

    /// One-shot policy. Do not reconnect; surface the first transient
    /// I/O failure to the caller as a typed `ClickHouseError`.
    public static let failFast = ReconnectionPolicy(
        maxAttempts: 0,
        initialBackoff: .milliseconds(0),
        maxBackoff: .milliseconds(0),
        backoffMultiplier: 1.0
    )

    /// Build a bounded reconnection policy.
    /// - Parameters:
    ///   - initial: backoff applied before the first retry attempt.
    ///   - max: cap on the backoff between attempts.
    ///   - multiplier: factor each attempt multiplies the current backoff by.
    ///   - attempts: maximum number of reconnect attempts. Pass
    ///     ``unboundedAttempts`` for an unbounded retry budget.
    public static func custom(
        initial: Duration,
        max: Duration,
        multiplier: Double = 2.0,
        attempts: Int
    ) -> ReconnectionPolicy {
        ReconnectionPolicy(
            maxAttempts: attempts,
            initialBackoff: initial,
            maxBackoff: max,
            backoffMultiplier: multiplier
        )
    }

    /// Library default. Alias of ``alwaysRetry`` kept so callers that
    /// passed `.default` before continue to compile.
    public static let `default` = ReconnectionPolicy.alwaysRetry

    /// Alias of ``failFast`` kept so callers that passed `.disabled`
    /// before continue to compile.
    public static let disabled = ReconnectionPolicy.failFast

    public init(
        maxAttempts: Int,
        initialBackoff: Duration,
        maxBackoff: Duration,
        backoffMultiplier: Double = 2.0
    ) {
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.backoffMultiplier = backoffMultiplier
    }
}
