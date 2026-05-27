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

    @Suite struct Publish {

        @Test
        func publishReturnsCleanly() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("pub")
            let subject = try NatsTestEnvironment.uniqueSubject("pub")
            try await conn.ensure(stream, subject: subject)

            let payloads: [[UInt8]] = (0..<50).map { Array("payload-\($0)".utf8) }
            try await conn.publish(to: subject, payloads: payloads)

            try await conn.delete(stream)
        }

        @Test
        func enqueueSupportsPipelining() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("pipe")
            let subject = try NatsTestEnvironment.uniqueSubject("pipe")
            try await conn.ensure(stream, subject: subject)

            var handles: [PublishHandle] = []
            for batchIndex in 0..<4 {
                let payloads: [[UInt8]] = (0..<25).map { Array("batch-\(batchIndex)-msg-\($0)".utf8) }
                let handle = conn.enqueue(to: subject, payloads: payloads)
                handles.append(handle)
            }
            for handle in handles {
                try await handle.wait()
            }

            try await conn.delete(stream)
        }

        @Test
        func publishSingleMessageBatchCompletes() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("one")
            let subject = try NatsTestEnvironment.uniqueSubject("one")
            try await conn.ensure(stream, subject: subject)

            let handle = conn.enqueue(to: subject, payloads: [Array("hello".utf8)])
            try await handle.wait()

            try await conn.delete(stream)
        }
    }
}
