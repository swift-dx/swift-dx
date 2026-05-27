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

import NIOPosix
import Testing
@testable import DXJetStream

extension IntegrationRoot {

    @Suite struct EndToEnd {

        @Test
        func publishThenFetchThenAckRoundtrip() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("e2e")
            let subject = try NatsTestEnvironment.uniqueSubject("e2e")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("e2e")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let total = 100
            let payloads: [[UInt8]] = (0..<total).map { Array("e2e-msg-\($0)".utf8) }
            try await conn.publish(to: subject, payloads: payloads)

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            var received: [[UInt8]] = []
            while received.count < total {
                let result = try await fs.requestAndAwait(batch: 50, expires: .seconds(5), wait: .fill)
                received.append(contentsOf: result.payloads)
                conn.acknowledge(replies: result.replies)
                if result.replies.isEmpty { break }
            }
            await conn.close(fs)
            #expect(received.count == total)

            try await conn.delete(stream)
        }

        @Test
        func publishHpubThenFetchReturnsPayloadsAndDedupsByMessageId() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("hpub")
            let subject = try NatsTestEnvironment.uniqueSubject("hpub")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("hpub")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let unique = 10
            let firstBatch = (0..<unique).map { i in
                NatsOutgoingMessage(dedup: .dedupId("msgid-\(i)"), payload: Array("hpub-\(i)".utf8))
            }
            try await conn.publish(to: subject, messages: firstBatch)

            let duplicateBatch = (0..<unique).map { i in
                NatsOutgoingMessage(dedup: .dedupId("msgid-\(i)"), payload: Array("hpub-\(i)".utf8))
            }
            try await conn.publish(to: subject, messages: duplicateBatch)

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fs.requestAndAwait(batch: unique * 2, expires: .seconds(5), wait: .fill)
            await conn.close(fs)

            #expect(result.payloads.count == unique)
            let received = result.payloads.map { String(decoding: $0, as: UTF8.self) }.sorted()
            let expected = (0..<unique).map { "hpub-\($0)" }.sorted()
            #expect(received == expected)
            conn.acknowledge(replies: result.replies)

            try await conn.delete(stream)
        }

        @Test
        func publishHpubWithUserHeadersIsAcceptedAndStoredByServer() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("hdrs")
            let subject = try NatsTestEnvironment.uniqueSubject("hdrs")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("hdrs")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let total = 5
            let messages = (0..<total).map { i in
                NatsOutgoingMessage(
                    dedup: .dedupId("hdr-\(i)"),
                    headers: [
                        NatsHeader(name: "X-Trace-Id", value: "trace-\(i)"),
                        NatsHeader(name: "X-Producer", value: "swift-dx-test"),
                    ],
                    payload: Array("payload-\(i)".utf8)
                )
            }
            try await conn.publish(to: subject, messages: messages)

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fs.requestAndAwait(batch: total, expires: .seconds(5), wait: .fill)
            await conn.close(fs)

            #expect(result.payloads.count == total)
            let received = result.payloads.map { String(decoding: $0, as: UTF8.self) }.sorted()
            let expected = (0..<total).map { "payload-\($0)" }.sorted()
            #expect(received == expected)
            conn.acknowledge(replies: result.replies)

            try await conn.delete(stream)
        }

        @Test
        func dualConnectionPublishFromOneAndFetchFromAnother() async throws {
            let group = MultiThreadedEventLoopGroup.singleton
            let publisher = JetStreamClientImpl(group: group)
            let subscriber = JetStreamClientImpl(group: group)
            try await publisher.connect(endpoint: NatsTestEnvironment.endpoint)
            try await subscriber.connect(endpoint: NatsTestEnvironment.endpoint)
            defer {
                Task {
                    await publisher.close()
                    await subscriber.close()
                }
            }

            let stream = try NatsTestEnvironment.uniqueStreamName("dual")
            let subject = try NatsTestEnvironment.uniqueSubject("dual")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("dual")
            try await publisher.ensure(stream, subject: subject)
            try await publisher.ensure(consumer, on: stream, ackWait: .seconds(30))

            let total = 20
            let payloads: [[UInt8]] = (0..<total).map { Array("dual-\($0)".utf8) }
            try await publisher.publish(to: subject, payloads: payloads)

            let fs = try await subscriber.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fs.requestAndAwait(batch: total, expires: .seconds(5), wait: .fill)
            #expect(result.replies.count == total)
            subscriber.acknowledge(replies: result.replies)
            await subscriber.close(fs)

            try await publisher.delete(stream)
        }
    }
}
