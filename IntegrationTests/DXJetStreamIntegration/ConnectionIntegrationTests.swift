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

    @Suite struct Connection {

        @Test
        func connectsAndClosesCleanly() async throws {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            await conn.close()
        }

        @Test
        func canConnectMultipleConcurrentConnections() async throws {
            let group = MultiThreadedEventLoopGroup.singleton
            let connections = (0..<4).map { _ in JetStreamClientImpl(group: group) }
            for conn in connections {
                try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            }
            for conn in connections {
                await conn.close()
            }
        }

        @Test
        func closeBeforeConnectIsNoOp() async {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            await conn.close()
        }

        @Test
        func connectFailsOnUnreachableEndpoint() async {
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            let badEndpoint = NatsEndpoint(host: "127.0.0.1", port: 1)
            await #expect(throws: (any Error).self) {
                try await conn.connect(endpoint: badEndpoint)
            }
        }
    }
}
