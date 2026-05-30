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

@testable import DXRedis
import Foundation
import Logging
import NIOCore
import NIOPosix
import Testing

@Suite("Redis pub/sub routing")
struct RedisPubSubTests {

    private struct Note: Codable, Equatable {

        let id: Int
        let body: String
    }

    private func makeManager() -> RedisSubscriptionManager {
        let configuration = RedisSubscriptionManager.Configuration(
            endpoint: RedisEndpoint(host: "127.0.0.1", port: 6399),
            credentials: .none,
            transportSecurity: .plaintext,
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            connectTimeout: .milliseconds(100),
            reconnectBaseDelay: .seconds(60),
            reconnectMaxDelay: .seconds(60),
            depthLimit: 64,
            maxBulkBytes: 512 * 1024 * 1024,
            deliveryBufferSize: 1024
        )
        return RedisSubscriptionManager(configuration: configuration, logger: Logger(label: "test.pubsub"))
    }

    private func messageFrame(channel: String, payload: String) -> RESPValue {
        .array([.bulkString(ByteBuffer(string: "message")), .bulkString(ByteBuffer(string: channel)), .bulkString(ByteBuffer(string: payload))])
    }

    private func patternMessageFrame(pattern: String, channel: String, payload: String) -> RESPValue {
        .array([.bulkString(ByteBuffer(string: "pmessage")), .bulkString(ByteBuffer(string: pattern)), .bulkString(ByteBuffer(string: channel)), .bulkString(ByteBuffer(string: payload))])
    }

    @Test("a channel name is expressible by string literal and round-trips")
    func channelType() {
        let channel: RedisChannel = "events"
        #expect(channel == RedisChannel("events"))
        #expect(channel.name == "events")
        #expect(channel.description == "events")
    }

    @Test("a pattern is expressible by string literal and round-trips")
    func patternType() {
        let pattern: RedisPattern = "news.*"
        #expect(pattern == RedisPattern("news.*"))
        #expect(pattern.value == "news.*")
    }

    @Test("a message exposes its payload as bytes, string, and decoded value")
    func messageAccessors() throws {
        let note = Note(id: 1, body: "hi")
        let encoded = try JSONEncoder().encode(note)
        let message = RedisMessage(buffer: ByteBuffer(bytes: Array(encoded)))
        #expect(message.bytes() == Array(encoded))
        #expect(try message.decode(as: Note.self) == note)
        #expect(try RedisMessage(buffer: ByteBuffer(string: "plain")).string() == "plain")
    }

    @Test("a message frame routes to the channel handler with channel and payload", .timeLimit(.minutes(1)))
    func channelDelivery() async throws {
        let manager = makeManager()
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        _ = try manager.subscribe(channels: [RedisChannel("chan")]) { channel, message in
            continuation.yield("\(channel.name)=\(try message.string())")
        }
        manager.handleFrame(messageFrame(channel: "chan", payload: "hello"))
        var iterator = events.makeAsyncIterator()
        guard let received = await iterator.next() else {
            Issue.record("no delivery")
            return
        }
        #expect(received == "chan=hello")
        await manager.shutdown()
    }

    @Test("a pattern message frame routes with pattern, channel, and payload", .timeLimit(.minutes(1)))
    func patternDelivery() async throws {
        let manager = makeManager()
        let (events, continuation) = AsyncStream.makeStream(of: [String].self)
        _ = try manager.subscribe(patterns: [RedisPattern("news.*")]) { pattern, channel, message in
            continuation.yield([pattern.value, channel.name, try message.string()])
        }
        manager.handleFrame(patternMessageFrame(pattern: "news.*", channel: "news.sports", payload: "goal"))
        var iterator = events.makeAsyncIterator()
        guard let parts = await iterator.next() else {
            Issue.record("no delivery")
            return
        }
        #expect(parts == ["news.*", "news.sports", "goal"])
        await manager.shutdown()
    }

    @Test("a frame for an unsubscribed channel is ignored", .timeLimit(.minutes(1)))
    func unmatchedChannelIgnored() async throws {
        let manager = makeManager()
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        _ = try manager.subscribe(channels: [RedisChannel("wanted")]) { _, message in
            continuation.yield(try message.string())
        }
        manager.handleFrame(messageFrame(channel: "other", payload: "ignored"))
        manager.handleFrame(messageFrame(channel: "wanted", payload: "kept"))
        var iterator = events.makeAsyncIterator()
        guard let received = await iterator.next() else {
            Issue.record("no delivery")
            return
        }
        #expect(received == "kept")
        await manager.shutdown()
    }
}
