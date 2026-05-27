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

    @Suite struct MessagesStream {

        @Test
        func asyncStreamDeliversPublishedMessages() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("asyncs")
            let subject = try NatsTestEnvironment.uniqueSubject("asyncs")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("asyncs")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let payloads: [[UInt8]] = (0..<5).map { Array("msg-\($0)".utf8) }
            try await conn.publish(to: subject, payloads: payloads)

            var received: [String] = []
            let options = PullOptions(batch: 5, expires: .seconds(2), wait: .anyAvailable)
            outer: for try await message in conn.messages(from: stream, for: consumer, options: options) {
                received.append(String(decoding: message.payload, as: UTF8.self))
                #expect(message.subject == subject.value)
                conn.ack(message)
                if received.count == 5 { break outer }
            }
            #expect(received == ["msg-0", "msg-1", "msg-2", "msg-3", "msg-4"])

            try await conn.delete(stream)
        }
    }
}
