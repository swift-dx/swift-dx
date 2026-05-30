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

// Drives `ClickHouseService` inside a `ServiceGroup` end-to-end:
// startup, normal query traffic, graceful shutdown signal, drain of
// in-flight queries within the configured grace period, and clean
// stop. Each test owns its own service so failures stay contained.
@Suite(
    "DXClickHouse ServiceLifecycle: ServiceGroup integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ServiceGroupIT {

    private static func configuration(gracePeriod: Duration = .seconds(5)) -> ClickHouseConfiguration {
        let environment = ProcessInfo.processInfo.environment
        return ClickHouseConfiguration(
            host: environment["CH_INTEGRATION_HOST"] ?? "localhost",
            port: Int(environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000,
            user: environment["CH_INTEGRATION_USER"] ?? "default",
            password: environment["CH_INTEGRATION_PASSWORD"] ?? "",
            database: environment["CH_INTEGRATION_DATABASE"] ?? "default",
            shutdownGracePeriod: gracePeriod,
            logger: Logger(label: "test.clickhouse.service-group-it")
        )
    }

    @Test("service inside a ServiceGroup serves a scalar query and shuts down cleanly")
    func serviceGroupServesAndShutsDown() async throws {
        let service = try await ClickHouseService(configuration: Self.configuration())
        let group = ServiceGroup(services: [service], logger: Logger(label: "test.clickhouse.group-it.basic"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            let value: UInt64 = try await service.client.scalar(
                "SELECT toUInt64(13)",
                as: UInt64.self,
                timeout: .seconds(5)
            )
            #expect(value == 13)
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }

    @Test("graceful shutdown drains an in-flight query that completes inside the grace period")
    func gracefulShutdownDrainsInFlightQuery() async throws {
        let service = try await ClickHouseService(configuration: Self.configuration(gracePeriod: .seconds(5)))
        let group = ServiceGroup(services: [service], logger: Logger(label: "test.clickhouse.group-it.drain"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            tasks.addTask {
                // ~1s server-side sleep; well inside the 5s grace.
                let total: UInt64 = try await service.client.scalar(
                    "SELECT toUInt64(sum(sleepEachRow(0.5))) FROM numbers(2)",
                    as: UInt64.self,
                    timeout: .seconds(10)
                )
                #expect(total == 0)
            }
            try await Task.sleep(for: .milliseconds(200))
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }

    @Test("multiple services in the same group all see the shutdown signal")
    func multipleServicesShareTheSignal() async throws {
        let primary = try await ClickHouseService(configuration: Self.configuration())
        let buddy = LifecycleProbeService()
        let group = ServiceGroup(
            services: [primary, buddy],
            logger: Logger(label: "test.clickhouse.group-it.multi")
        )
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            // Make sure the service is alive and the buddy is parked
            // before signalling shutdown.
            try await Task.sleep(for: .milliseconds(100))
            let value: UInt64 = try await primary.client.scalar(
                "SELECT toUInt64(21)",
                as: UInt64.self,
                timeout: .seconds(5)
            )
            #expect(value == 21)
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
        let observed = await buddy.didShutdown
        #expect(observed)
    }

    @Test("service.client.ping() succeeds while the surrounding group is running")
    func clientPingDuringRun() async throws {
        let service = try await ClickHouseService(configuration: Self.configuration())
        let group = ServiceGroup(services: [service], logger: Logger(label: "test.clickhouse.group-it.ping"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            try await service.client.ping(timeout: .seconds(5))
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }

    @Test("ad-hoc ClickHouse.withClient(configuration:) opens and closes cleanly")
    func adHocWithClient() async throws {
        let value: UInt64 = try await ClickHouse.withClient(Self.configuration()) { client in
            try await client.scalar("SELECT toUInt64(77)", as: UInt64.self, timeout: .seconds(5))
        }
        #expect(value == 77)
    }
}

// Companion service used to confirm that the shutdown signal reaches
// every service in the group, not just the ClickHouseService.
private actor LifecycleProbeService: Service {

    private var shutdown: Bool = false

    var didShutdown: Bool { shutdown }

    func run() async throws {
        do {
            try await gracefulShutdown()
        } catch {}
        shutdown = true
    }
}
