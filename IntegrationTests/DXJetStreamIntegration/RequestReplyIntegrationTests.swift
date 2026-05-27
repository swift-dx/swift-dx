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

    @Suite struct RequestReply {

        @Test
        func managementRequestReceivesReplyPayload() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("req")
            let subject = try NatsTestEnvironment.uniqueSubject("req")
            try await conn.ensure(stream, subject: subject)

            let infoSubject = try Subject("$JS.API.STREAM.INFO.\(stream.value)")
            let message = try await conn.request(at: infoSubject, payload: [])
            #expect(!message.payload.isEmpty)
            let body = String(decoding: message.payload, as: UTF8.self)
            #expect(body.contains(stream.value))

            try await conn.delete(stream)
        }
    }
}
