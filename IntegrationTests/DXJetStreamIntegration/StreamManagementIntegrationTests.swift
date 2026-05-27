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

    @Suite struct StreamManagement {

        @Test
        func ensureCreatesNewStream() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("ensure")
            let subject = try NatsTestEnvironment.uniqueSubject("ensure")
            try await conn.ensure(stream, subject: subject)
            try await conn.delete(stream)
        }

        @Test
        func ensureWithMemoryStorage() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("mem")
            let subject = try NatsTestEnvironment.uniqueSubject("mem")
            try await conn.ensure(stream, subject: subject, storage: .memory)
            try await conn.delete(stream)
        }

        @Test
        func ensureCreatesNewConsumer() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("cons")
            let subject = try NatsTestEnvironment.uniqueSubject("cons")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("cons")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))
            try await conn.delete(stream)
        }

        @Test
        func deleteRemovesStream() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("del")
            let subject = try NatsTestEnvironment.uniqueSubject("del")
            try await conn.ensure(stream, subject: subject)
            try await conn.delete(stream)
        }
    }
}
