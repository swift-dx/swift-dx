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

extension RedisClient: RedisSubscriber {

    public func publish(to channel: RedisChannel, payload: [UInt8]) async throws(RedisError) -> Int {
        let reply = try await send(RedisCommand(arguments: [Array("PUBLISH".utf8), channel.bytes, payload]))
        return Int(try reply.integerValue())
    }

    public func subscribe(to channels: [RedisChannel], handler: @escaping @Sendable (RedisChannel, RedisMessage) async throws -> Void) async throws(RedisError) -> RedisSubscription {
        try subscriptionManager().subscribe(channels: channels, handler: handler)
    }

    public func subscribe(toPatterns patterns: [RedisPattern], handler: @escaping @Sendable (RedisPattern, RedisChannel, RedisMessage) async throws -> Void) async throws(RedisError) -> RedisSubscription {
        try subscriptionManager().subscribe(patterns: patterns, handler: handler)
    }

    private func subscriptionManager() -> RedisSubscriptionManager {
        subscriptions.withLockedValue { slot in
            switch slot {
            case .created(let manager):
                return manager
            case .none:
                let manager = RedisSubscriptionManager(configuration: makeSubscriptionConfiguration(), logger: logger)
                manager.start()
                slot = .created(manager)
                return manager
            }
        }
    }

    private func makeSubscriptionConfiguration() -> RedisSubscriptionManager.Configuration {
        RedisSubscriptionManager.Configuration(
            endpoint: poolConfiguration.endpoints.first ?? RedisEndpoint(host: "127.0.0.1", port: 6379),
            credentials: poolConfiguration.credentials,
            transportSecurity: poolConfiguration.transportSecurity,
            eventLoopGroup: poolConfiguration.eventLoopGroup,
            connectTimeout: poolConfiguration.connectTimeout,
            reconnectBaseDelay: resilience.reconnectBaseDelay,
            reconnectMaxDelay: resilience.reconnectMaxDelay,
            depthLimit: poolConfiguration.responseDepthLimit,
            maxBulkBytes: poolConfiguration.maxBulkBytes,
            deliveryBufferSize: 1024
        )
    }
}
