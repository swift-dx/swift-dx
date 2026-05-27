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
import DXJetStream

extension IntegrationRoot {

    @Suite struct Facade {

        @Test
        func connectAndCloseViaPublicFacade() async throws {
            let config = JetStreamConfiguration(endpoint: NatsTestEnvironment.endpoint)
            let client = try await JetStream.connect(config)
            #expect(client.inboxPrefix.hasPrefix("_INBOX."))
            await client.close()
        }

        @Test
        func withClientRunsBodyAndAutoCloses() async throws {
            let config = JetStreamConfiguration(endpoint: NatsTestEnvironment.endpoint)
            let received: String = try await JetStream.withClient(config) { client in
                #expect(client.inboxPrefix.hasPrefix("_INBOX."))
                return "ok"
            }
            #expect(received == "ok")
        }

        @Test
        func withClientPropagatesErrorAndStillCloses() async throws {
            let config = JetStreamConfiguration(endpoint: NatsTestEnvironment.endpoint)
            struct SampleError: Error {}
            await #expect(throws: SampleError.self) {
                _ = try await JetStream.withClient(config) { _ in
                    throw SampleError()
                }
            }
        }

        @Test
        func publishAndFetchRoundtripViaFacade() async throws {
            let config = JetStreamConfiguration(endpoint: NatsTestEnvironment.endpoint)
            try await JetStream.withClient(config) { client in
                let stream = try NatsTestEnvironment.uniqueStreamName("fac")
                let subject = try NatsTestEnvironment.uniqueSubject("fac")
                let consumer = try NatsTestEnvironment.uniqueConsumerName("fac")
                try await client.ensure(stream, subject: subject)
                try await client.ensure(consumer, on: stream, ackWait: .seconds(30))

                let payloads: [[UInt8]] = (0..<5).map { Array("facade-\($0)".utf8) }
                try await client.publish(to: subject, payloads: payloads)

                let fs = try await client.fetch(from: stream, for: consumer, needsPayload: true)
                let result = try await fs.requestAndAwait(batch: 5, expires: .seconds(5), wait: .fill)
                await client.close(fs)
                #expect(result.payloads.count == 5)
                let received = result.payloads.map { String(decoding: $0, as: UTF8.self) }.sorted()
                #expect(received == ["facade-0", "facade-1", "facade-2", "facade-3", "facade-4"])
                client.acknowledge(replies: result.replies)

                try await client.delete(stream)
            }
        }
    }
}
