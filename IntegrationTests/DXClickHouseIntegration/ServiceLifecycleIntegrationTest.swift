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
import Logging
import ServiceLifecycle
import Testing

// Integration cover for the long-running ClickHouseService entry point.
// Gated on CH_INTEGRATION_HOST so it only runs when a live ClickHouse is
// wired.
@Suite(
    "ClickHouseService integration: ServiceGroup lifecycle",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseServiceLifecycleIntegration {

    private static var configuration: ClickHouseConfiguration {
        let environment = ProcessInfo.processInfo.environment
        return ClickHouseConfiguration(
            host: environment["CH_INTEGRATION_HOST"] ?? "localhost",
            port: Int(environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000,
            user: environment["CH_INTEGRATION_USER"] ?? "default",
            password: environment["CH_INTEGRATION_PASSWORD"] ?? "",
            database: environment["CH_INTEGRATION_DATABASE"] ?? "default",
            shutdownGracePeriod: .seconds(5),
            logger: Logger(label: "test.clickhouse.service")
        )
    }

    @Test("ad-hoc ClickHouse.connect(configuration:) still serves queries")
    func adHocConfigurationPathStillWorks() async throws {
        let client = try await ClickHouse.connect(Self.configuration)
        let value: UInt64 = try await client.scalar("SELECT toUInt64(42)", as: UInt64.self, timeout: .seconds(5))
        #expect(value == 42)
        await client.close()
    }

    @Test("ad-hoc ClickHouse.withClient(configuration:) opens and closes scoped")
    func adHocConfigurationScopedPathStillWorks() async throws {
        let value: UInt64 = try await ClickHouse.withClient(Self.configuration) { client in
            try await client.scalar("SELECT toUInt64(7)", as: UInt64.self, timeout: .seconds(5))
        }
        #expect(value == 7)
    }

    @Test("ClickHouseService runs under ServiceGroup, serves queries, and shuts down gracefully")
    func serviceUnderServiceGroupServesQueriesAndShutsDown() async throws {
        let service = try await ClickHouseService(configuration: Self.configuration)
        let other = LongLivedDummyService()
        let group = ServiceGroup(services: [service, other], logger: Logger(label: "test.clickhouse.group"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            // Use the service's client while the group is running.
            let value: UInt64 = try await service.client.scalar(
                "SELECT toUInt64(99)",
                as: UInt64.self,
                timeout: .seconds(5)
            )
            #expect(value == 99)
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
        let didCancel = await other.didShutdown
        #expect(didCancel)
    }

    @Test("graceful shutdown drains in-flight queries within grace period")
    func gracefulShutdownDrainsInflightQuery() async throws {
        let service = try await ClickHouseService(configuration: Self.configuration)
        let group = ServiceGroup(services: [service], logger: Logger(label: "test.clickhouse.drain"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            tasks.addTask {
                // A query that completes within the 5s grace period.
                let total: UInt64 = try await service.client.scalar(
                    "SELECT sum(sleepEachRow(0.5)) FROM numbers(2)",
                    as: UInt64.self,
                    timeout: .seconds(5)
                )
                #expect(total == 0)
            }
            try await Task.sleep(for: .milliseconds(200))
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }
}

private actor LongLivedDummyService: Service {

    private var shutdown: Bool = false

    var didShutdown: Bool { shutdown }

    func run() async throws {
        do {
            try await gracefulShutdown()
        } catch {}
        shutdown = true
    }
}
