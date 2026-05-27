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

    @Suite struct Fetch {

        @Test
        func fetchWithFillCollectsExactBatch() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("fillf")
            let subject = try NatsTestEnvironment.uniqueSubject("fillf")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("fillf")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let payloads: [[UInt8]] = (0..<10).map { Array("msg-\($0)".utf8) }
            try await conn.publish(to: subject, payloads: payloads)

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fs.requestAndAwait(batch: 10, expires: .seconds(5), wait: .fill)
            #expect(result.replies.count == 10)
            #expect(result.payloads.count == 10)
            conn.acknowledge(replies: result.replies)
            await conn.close(fs)

            try await conn.delete(stream)
        }

        @Test
        func fetchWithAnyAvailableReturnsAsSoonAsPossible() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("anyf")
            let subject = try NatsTestEnvironment.uniqueSubject("anyf")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("anyf")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            try await conn.publish(to: subject, payloads: [Array("solo".utf8)])

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: false)
            let result = try await fs.requestAndAwait(batch: 100, expires: .seconds(5), wait: .anyAvailable)
            #expect(result.replies.count >= 1)
            conn.acknowledge(replies: result.replies)
            await conn.close(fs)

            try await conn.delete(stream)
        }

        @Test
        func fetchWithAtLeastWakesAfterCount() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("alf")
            let subject = try NatsTestEnvironment.uniqueSubject("alf")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("alf")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let payloads: [[UInt8]] = (0..<5).map { Array("m-\($0)".utf8) }
            try await conn.publish(to: subject, payloads: payloads)

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: false)
            let result = try await fs.requestAndAwait(batch: 50, expires: .seconds(5), wait: .atLeast(3))
            #expect(result.replies.count >= 3)
            conn.acknowledge(replies: result.replies)
            await conn.close(fs)

            try await conn.delete(stream)
        }

        @Test
        func fetchOnEmptyConsumerHits404OnExpiry() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("emp")
            let subject = try NatsTestEnvironment.uniqueSubject("emp")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("emp")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: false)
            let result = try await fs.requestAndAwait(batch: 10, expires: .seconds(1), wait: .fill)
            #expect(result.replies.isEmpty)
            await conn.close(fs)

            try await conn.delete(stream)
        }
    }
}
