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

// Covers the "service goes down, supervisor brings it back" shape. The
// `ClickHouseService` itself does not crash in normal operation, so the
// scenario under test is the supervised-restart pattern most operators
// run in production: tear the running service down, build a fresh one
// against the same configuration, run it under a fresh `ServiceGroup`,
// and confirm queries resume on the new instance.
@Suite(
    "DXClickHouse ServiceLifecycle: supervised restart cycle",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ServiceRestartIT {

    private static func configuration() -> ClickHouseConfiguration {
        let environment = ProcessInfo.processInfo.environment
        return ClickHouseConfiguration(
            host: environment["CH_INTEGRATION_HOST"] ?? "localhost",
            port: Int(environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000,
            user: environment["CH_INTEGRATION_USER"] ?? "default",
            password: environment["CH_INTEGRATION_PASSWORD"] ?? "",
            database: environment["CH_INTEGRATION_DATABASE"] ?? "default",
            shutdownGracePeriod: .seconds(3),
            logger: Logger(label: "test.clickhouse.service-restart-it")
        )
    }

    @Test("service shuts down via group signal, then a fresh service in a fresh group resumes queries")
    func restartCycleResumesQueries() async throws {
        // First lifecycle: build, run, query, signal-shutdown, drain.
        let firstService = try await ClickHouseService(configuration: Self.configuration())
        let firstGroup = ServiceGroup(services: [firstService], logger: Logger(label: "test.clickhouse.restart-it.first"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await firstGroup.run() }
            let value: UInt64 = try await firstService.client.scalar(
                "SELECT toUInt64(1)",
                as: UInt64.self,
                timeout: .seconds(5)
            )
            #expect(value == 1)
            await firstGroup.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }

        // Second lifecycle: build a fresh service, prove queries
        // resume against the live broker on the new instance.
        let secondService = try await ClickHouseService(configuration: Self.configuration())
        let secondGroup = ServiceGroup(services: [secondService], logger: Logger(label: "test.clickhouse.restart-it.second"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await secondGroup.run() }
            let resumed: UInt64 = try await secondService.client.scalar(
                "SELECT toUInt64(2)",
                as: UInt64.self,
                timeout: .seconds(5)
            )
            #expect(resumed == 2)
            await secondGroup.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }

    @Test("a third lifecycle cycle confirms restart is stable across more than one iteration")
    func threeCyclesAllResume() async throws {
        for iteration in 1...3 {
            let service = try await ClickHouseService(configuration: Self.configuration())
            let group = ServiceGroup(
                services: [service],
                logger: Logger(label: "test.clickhouse.restart-it.cycle-\(iteration)")
            )
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask { try await group.run() }
                let value: UInt64 = try await service.client.scalar(
                    "SELECT toUInt64(\(iteration))",
                    as: UInt64.self,
                    timeout: .seconds(5)
                )
                #expect(value == UInt64(iteration))
                await group.triggerGracefulShutdown()
                try await tasks.waitForAll()
            }
        }
    }
}
