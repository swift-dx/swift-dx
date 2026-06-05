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

extension PostgresLeasePool: Service {

    /// Runs the pool as part of a `ServiceGroup`. The connections are already open;
    /// this suspends until the group initiates graceful shutdown, then releases
    /// every connection. Run it in a `ServiceGroup` to tie the pool's lifetime to
    /// the application's and tear it down cleanly on `SIGTERM`/`SIGINT`.
    public func run() async throws {
        defer { shutdown() }
        try await gracefulShutdown()
    }
}
