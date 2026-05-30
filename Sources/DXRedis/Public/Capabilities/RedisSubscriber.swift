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

import Foundation
import NIOCore

/// Publish/subscribe: fire a message to a channel, or receive messages on
/// channels and glob patterns through an async handler that is also given the
/// channel each message arrived on. Subscriptions deliver without blocking the
/// caller, survive connection drops by re-subscribing automatically, and last
/// until the returned ``RedisSubscription`` is cancelled.
///
/// `RedisClient` conforms to this. Publishing goes over the pooled request path;
/// subscribing runs on a separate connection held in subscribe mode.
public protocol RedisSubscriber: Sendable {

    func publish(to channel: RedisChannel, payload: [UInt8]) async throws(RedisError) -> Int

    func subscribe(to channels: [RedisChannel], handler: @escaping @Sendable (RedisChannel, RedisMessage) async throws -> Void) async throws(RedisError) -> RedisSubscription

    func subscribe(toPatterns patterns: [RedisPattern], handler: @escaping @Sendable (RedisPattern, RedisChannel, RedisMessage) async throws -> Void) async throws(RedisError) -> RedisSubscription
}

extension RedisSubscriber {

    public func publish(to channel: RedisChannel, payload: ByteBuffer) async throws(RedisError) -> Int {
        try await publish(to: channel, payload: Array(payload.readableBytesView))
    }

    public func publish(to channel: RedisChannel, message: String) async throws(RedisError) -> Int {
        try await publish(to: channel, payload: Array(message.utf8))
    }

    public func publish<Value: Encodable & Sendable>(to channel: RedisChannel, json value: Value) async throws(RedisError) -> Int {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(value)
        } catch {
            throw RedisError.jsonEncodingFailed(typeName: String(describing: Value.self), reason: String(describing: error))
        }
        return try await publish(to: channel, payload: Array(encoded))
    }

    public func subscribe(to channel: RedisChannel, handler: @escaping @Sendable (RedisChannel, RedisMessage) async throws -> Void) async throws(RedisError) -> RedisSubscription {
        try await subscribe(to: [channel], handler: handler)
    }

    public func subscribe(toPattern pattern: RedisPattern, handler: @escaping @Sendable (RedisPattern, RedisChannel, RedisMessage) async throws -> Void) async throws(RedisError) -> RedisSubscription {
        try await subscribe(toPatterns: [pattern], handler: handler)
    }
}
