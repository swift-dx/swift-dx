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

import Foundation
import NIOPosix
import Testing
@testable import DXJetStream

extension IntegrationRoot {

    @Suite(.enabled(if: AuthenticatedNatsTestEnvironment.isAvailable))
    struct Authenticated {

        @Test
        func connectsWithBase64EnvironmentCredentials() async throws {
            let conn = JetStreamClientImpl(
                group: MultiThreadedEventLoopGroup.singleton,
                credentials: .base64Environment(variable: AuthenticatedNatsTestEnvironment.credentialsVariable),
                logger: .standard()
            )
            try await conn.connect(endpoint: AuthenticatedNatsTestEnvironment.endpoint)
            await conn.close()
        }

        @Test
        func publishesAndFetchesWithAuthenticatedConnection() async throws {
            let conn = JetStreamClientImpl(
                group: MultiThreadedEventLoopGroup.singleton,
                credentials: .base64Environment(variable: AuthenticatedNatsTestEnvironment.credentialsVariable),
                logger: .standard()
            )
            try await conn.connect(endpoint: AuthenticatedNatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("auth")
            let subject = try NatsTestEnvironment.uniqueSubject("auth")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("auth")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let payloads: [[UInt8]] = (0..<10).map { Array("auth-\($0)".utf8) }
            try await conn.publish(to: subject, payloads: payloads)

            let fs = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fs.requestAndAwait(batch: 10, expires: .seconds(5), wait: .fill)
            #expect(result.replies.count == 10)
            conn.acknowledge(replies: result.replies)
            await conn.close(fs)

            try await conn.delete(stream)
        }
    }
}

enum AuthenticatedNatsTestEnvironment {

    static let credentialsVariable = "NATS_TEST_CREDS_BASE64"

    static var isAvailable: Bool {
        NatsTestEnvironment.isAvailable
            && ProcessInfo.processInfo.environment[credentialsVariable] != nil
    }

    static var endpoint: NatsEndpoint {
        NatsTestEnvironment.endpoint
    }
}
