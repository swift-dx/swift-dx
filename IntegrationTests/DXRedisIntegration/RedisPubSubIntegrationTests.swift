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

import DXRedis
import Foundation
import Testing

// Exercises publish/subscribe end to end against a live server: channel and
// pattern delivery, typed payloads, fan-out, explicit unsubscribe, and recovery
// after the subscription connection is killed. Subscriptions establish
// asynchronously, so each test gives the SUBSCRIBE a moment to reach the wire
// before publishing. A time limit guards against a hang if delivery breaks.
@Suite("Redis pub/sub", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisPubSubIntegrationTests {

    private struct Note: Codable, Equatable {

        let id: Int
        let body: String
    }

    private func client() throws -> RedisClient {
        try RedisIntegration.makeClient()
    }

    @Test("a published message reaches a channel subscriber", .timeLimit(.minutes(1)))
    func channelRoundtrip() async throws {
        let subscriber = try client()
        let publisher = try client()
        let channel = RedisChannel("\(RedisIntegration.uniquePrefix()):ch")
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let subscription = try await subscriber.subscribe(to: channel) { _, message in
            continuation.yield(try message.string())
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await publisher.publish(to: channel, message: "hello")
        var iterator = events.makeAsyncIterator()
        guard let received = await iterator.next() else {
            Issue.record("no message received")
            return
        }
        #expect(received == "hello")
        subscription.cancel()
        await subscriber.shutdown()
        await publisher.shutdown()
    }

    @Test("the handler is given the channel each message arrived on", .timeLimit(.minutes(1)))
    func channelNameDelivered() async throws {
        let subscriber = try client()
        let publisher = try client()
        let channel = RedisChannel("\(RedisIntegration.uniquePrefix()):named")
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let subscription = try await subscriber.subscribe(to: channel) { deliveredChannel, _ in
            continuation.yield(deliveredChannel.name)
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await publisher.publish(to: channel, payload: Array("x".utf8))
        var iterator = events.makeAsyncIterator()
        guard let name = await iterator.next() else {
            Issue.record("no message received")
            return
        }
        #expect(name == channel.name)
        subscription.cancel()
        await subscriber.shutdown()
        await publisher.shutdown()
    }

    @Test("a pattern subscriber receives the matched channel and message", .timeLimit(.minutes(1)))
    func patternRoundtrip() async throws {
        let subscriber = try client()
        let publisher = try client()
        let prefix = RedisIntegration.uniquePrefix()
        let pattern = RedisPattern("\(prefix):news.*")
        let concrete = RedisChannel("\(prefix):news.sports")
        let (events, continuation) = AsyncStream.makeStream(of: [String].self)
        let subscription = try await subscriber.subscribe(toPattern: pattern) { matchedPattern, channel, message in
            continuation.yield([matchedPattern.value, channel.name, try message.string()])
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await publisher.publish(to: concrete, message: "goal")
        var iterator = events.makeAsyncIterator()
        guard let parts = await iterator.next() else {
            Issue.record("no pattern message received")
            return
        }
        #expect(parts == [pattern.value, concrete.name, "goal"])
        subscription.cancel()
        await subscriber.shutdown()
        await publisher.shutdown()
    }

    @Test("a JSON payload round-trips through publish and a decoding handler", .timeLimit(.minutes(1)))
    func typedPayload() async throws {
        let subscriber = try client()
        let publisher = try client()
        let channel = RedisChannel("\(RedisIntegration.uniquePrefix()):json")
        let note = Note(id: 7, body: "ship it")
        let (events, continuation) = AsyncStream.makeStream(of: Note.self)
        let subscription = try await subscriber.subscribe(to: channel) { _, message in
            continuation.yield(try message.decode(as: Note.self))
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await publisher.publish(to: channel, json: note)
        var iterator = events.makeAsyncIterator()
        guard let received = await iterator.next() else {
            Issue.record("no message received")
            return
        }
        #expect(received == note)
        subscription.cancel()
        await subscriber.shutdown()
        await publisher.shutdown()
    }

    @Test("two subscribers on one channel both receive the message", .timeLimit(.minutes(1)))
    func fanOut() async throws {
        let subscriber = try client()
        let publisher = try client()
        let channel = RedisChannel("\(RedisIntegration.uniquePrefix()):fanout")
        let (first, firstContinuation) = AsyncStream.makeStream(of: String.self)
        let (second, secondContinuation) = AsyncStream.makeStream(of: String.self)
        let subscriptionA = try await subscriber.subscribe(to: channel) { _, message in firstContinuation.yield(try message.string()) }
        let subscriptionB = try await subscriber.subscribe(to: channel) { _, message in secondContinuation.yield(try message.string()) }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await publisher.publish(to: channel, message: "broadcast")
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        guard let a = await firstIterator.next(), let b = await secondIterator.next() else {
            Issue.record("a subscriber missed the message")
            return
        }
        #expect(a == "broadcast")
        #expect(b == "broadcast")
        subscriptionA.cancel()
        subscriptionB.cancel()
        await subscriber.shutdown()
        await publisher.shutdown()
    }

    @Test("a published message survives the subscription connection being killed", .timeLimit(.minutes(1)))
    func reconnectResilience() async throws {
        let subscriber = try client()
        let publisher = try client()
        let channel = RedisChannel("\(RedisIntegration.uniquePrefix()):resilient")
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let subscription = try await subscriber.subscribe(to: channel) { _, message in
            continuation.yield(try message.string())
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await publisher.send(RedisCommand("CLIENT", "KILL", "TYPE", "pubsub"))
        try await Task.sleep(for: .milliseconds(700))
        _ = try await publisher.publish(to: channel, message: "after-reconnect")
        var iterator = events.makeAsyncIterator()
        guard let received = await iterator.next() else {
            Issue.record("no message received after reconnect")
            return
        }
        #expect(received == "after-reconnect")
        subscription.cancel()
        await subscriber.shutdown()
        await publisher.shutdown()
    }
}
