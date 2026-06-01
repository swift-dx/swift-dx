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

import ServiceLifecycle

extension PostgresClient: Service {

    // Running under a ServiceGroup, the client warms one connection at startup so
    // it is ready before the first request. An unreachable server at boot is not
    // fatal: it is logged and the group still starts. The client then parks until
    // graceful shutdown and tears the pool down.
    public func run() async throws {
        await warmUpTolerantly()
        try await gracefulShutdown()
        await shutdown()
    }

    private func warmUpTolerantly() async {
        do {
            try await warmUp(connections: 1)
        } catch {
            logger.warning("PostgreSQL unreachable at startup; starting anyway and connecting on demand", metadata: ["error": .string(String(describing: error))])
        }
    }
}
