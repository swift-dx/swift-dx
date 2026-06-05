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

import DXClickHouse
import Foundation
import ServiceLifecycle
import Testing

// ClickHouseService graceful shutdown coverage. The service parks in
// `run()` until the surrounding ServiceGroup signals shutdown, then
// drains in-flight queries within `configuration.shutdownGracePeriod`
// before closing the underlying client.
//
// The full ServiceGroup integration test (real broker, real
// ServiceGroup with multiple services) lives in
// IntegrationTests/DXClickHouseIntegration. Here we cover the shape
// contract and the drain race using a real broker when one is
// available.
@Suite("ClickHouseService shutdown drain semantics")
struct ClickHouseServiceShutdownTests {

    @Test("ClickHouseConfiguration default shutdownGracePeriod is 30 seconds")
    func defaultGracePeriodIs30Seconds() throws {
        let configuration = try ClickHouseConfiguration(
            endpoints: [ClickHouseEndpoint(host: "h", port: 9000)]
        )
        #expect(configuration.shutdownGracePeriod == .seconds(30))
    }

    @Test("ClickHouseConfiguration accepts a custom grace period")
    func customGracePeriod() {
        let configuration = ClickHouseConfiguration(
            host: "h",
            port: 9000,
            shutdownGracePeriod: .seconds(5)
        )
        #expect(configuration.shutdownGracePeriod == .seconds(5))
    }

    @Test(
        "Service.run() returns when the gracefulShutdown signal fires",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func serviceRunReturnsOnShutdown() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let password = ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""

        let configuration = ClickHouseConfiguration(
            host: host,
            port: port,
            password: password,
            shutdownGracePeriod: .seconds(2)
        )
        let service = try await ClickHouseService(configuration: configuration)

        let group = ServiceGroup(
            services: [service],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: configuration.logger
        )

        let runTask = Task {
            try await group.run()
        }

        // Verify the service's client is reachable while running.
        let value = try await service.client.scalar("SELECT toUInt64(1)", as: UInt64.self)
        #expect(value == 1)

        await group.triggerGracefulShutdown()
        try await runTask.value
    }

    @Test(
        "Service drains in-flight short queries before shutdown completes",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func serviceDrainsInFlightShortQueries() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let password = ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""

        let configuration = ClickHouseConfiguration(
            host: host,
            port: port,
            password: password,
            shutdownGracePeriod: .seconds(5)
        )
        let service = try await ClickHouseService(configuration: configuration)
        let group = ServiceGroup(
            services: [service],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: configuration.logger
        )
        let runTask = Task {
            try await group.run()
        }

        // Issue a short query, then trigger shutdown. The drain path
        // serialises through the worker queue so a short in-flight call
        // gets to finish before the underlying socket is closed.
        let queryTask = Task {
            try await service.client.scalar("SELECT toUInt64(42)", as: UInt64.self)
        }

        try await Task.sleep(for: .milliseconds(20))
        await group.triggerGracefulShutdown()
        let result = try await queryTask.value
        #expect(result == 42)
        try await runTask.value
    }
}
