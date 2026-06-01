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

import Logging

// The observability handles shared across the client and its connection pool: a
// logger that renders lifecycle events and a metrics recorder that accumulates
// counters. One instance is created per client and threaded into the pool so the
// counts a caller reads through PostgresClient.metrics() include pool-internal
// events such as connection opens and acquire timeouts.
struct PostgresObservability: Sendable {

    let logger: PostgresLogger
    let metrics: PostgresMetricsRecorder

    init(logger: Logger) {
        self.logger = PostgresLogger(logger)
        self.metrics = PostgresMetricsRecorder()
    }
}
