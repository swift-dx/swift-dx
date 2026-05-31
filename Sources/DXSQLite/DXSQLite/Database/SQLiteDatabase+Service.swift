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

extension SQLiteDatabase: Service {

    /// Parks until the surrounding `ServiceGroup` begins graceful shutdown, then
    /// closes the reader pool, the writer connection, and the thread pools. The
    /// database is already open before it joins the group, so `run()` performs no
    /// startup work.
    public func run() async throws {
        try await gracefulShutdown()
        await close()
    }
}
