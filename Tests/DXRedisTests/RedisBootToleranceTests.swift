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

import DXRedis
import Logging
import NIOCore
import ServiceLifecycle
import Testing

// Boot is treated the same as a mid-life outage: a server that is unreachable
// when the client starts under a ServiceGroup must not crash the process or fail
// the group's startup. run() warms best-effort, logs, and parks; once graceful
// shutdown is triggered it returns cleanly. Port 6399 has nothing listening.
@Suite("Redis boot tolerance")
struct RedisBootToleranceTests {

    @Test("an unreachable server at startup neither crashes nor fails the service group")
    func toleratesUnreachableServerAtBoot() async throws {
        let configuration = RedisConfiguration(
            endpoint: RedisEndpoint(host: "127.0.0.1", port: 6399),
            connectTimeout: .milliseconds(200),
            resilience: RedisResilience(requestTimeout: .milliseconds(300))
        )
        let client = RedisClient(configuration: configuration)
        let group = ServiceGroup(services: [client], logger: Logger(label: "test.boot"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            try await Task.sleep(for: .milliseconds(500))
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }
}
