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

import Testing
import NIOCore
import NIOPosix
@testable import DXJetStream

@Suite
struct JetStreamConfigurationTests {

    @Test
    func privatePoolInitializer_buildsConfigurationWithDefaults() async throws {
        let endpoint = NatsEndpoint(host: "localhost", port: 4222)
        let configuration = JetStreamConfiguration(endpoint: endpoint)
        #expect(configuration.endpoint.host == "localhost")
        #expect(configuration.endpoint.port == 4222)
        switch configuration.credentials {
        case .anonymous: break
        default: Issue.record("expected anonymous credentials by default")
        }
        try await configuration.eventLoopGroup.shutdownGracefully()
    }

    @Test
    func privatePoolInitializer_honorsExpectedConnections() async throws {
        let endpoint = NatsEndpoint(host: "localhost")
        let configuration = JetStreamConfiguration(endpoint: endpoint, expectedConnections: 4)
        #expect(configuration.endpoint.host == "localhost")
        try await configuration.eventLoopGroup.shutdownGracefully()
    }

    @Test
    func privatePoolInitializer_clampsExpectedConnectionsBelowOne() async throws {
        let endpoint = NatsEndpoint(host: "localhost")
        let configuration = JetStreamConfiguration(endpoint: endpoint, expectedConnections: 0)
        try await configuration.eventLoopGroup.shutdownGracefully()
        _ = configuration
    }

    @Test
    func externalPoolInitializer_keepsProvidedEventLoopGroup() async throws {
        let endpoint = NatsEndpoint(host: "broker.internal", port: 5222)
        let providedGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let configuration = JetStreamConfiguration(endpoint: endpoint, eventLoopGroup: providedGroup)
        #expect(configuration.endpoint.host == "broker.internal")
        #expect(configuration.endpoint.port == 5222)
        try await providedGroup.shutdownGracefully()
    }

    @Test
    func externalPoolInitializer_acceptsCustomCredentialsAndLogger() async throws {
        let endpoint = NatsEndpoint(host: "broker.internal")
        let providedGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let credentials = NatsCredentialsSource.base64Environment(variable: "NATS_CREDS")
        let configuration = JetStreamConfiguration(
            endpoint: endpoint,
            credentials: credentials,
            logger: .silent,
            eventLoopGroup: providedGroup
        )
        switch configuration.credentials {
        case .base64Environment(let variable): #expect(variable == "NATS_CREDS")
        default: Issue.record("expected base64Environment credentials")
        }
        try await providedGroup.shutdownGracefully()
    }
}
