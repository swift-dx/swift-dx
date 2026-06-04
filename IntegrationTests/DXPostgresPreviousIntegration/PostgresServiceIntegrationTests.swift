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

import DXPostgresPrevious
import Logging
import ServiceLifecycle
import Testing

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresServiceIntegrationTests {

    @Test func runsUnderAServiceGroupServesAndShutsDown() async throws {
        let client = PostgresClient(configuration: PostgresIntegration.makeConfiguration())
        let group = ServiceGroup(
            services: [client],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: Logger(label: "swift.dx.postgres.test")
        )
        let runTask = Task { try await group.run() }
        let row = try await client.query("SELECT 1 AS ok").rows[0]
        #expect(try row.decode(Int.self, named: "ok") == 1)
        await group.triggerGracefulShutdown()
        try await runTask.value
    }
}
