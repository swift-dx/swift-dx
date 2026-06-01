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
// counts a caller reads through RedisClient.metrics() include pool-internal
// events such as connection opens and acquire timeouts.
struct RedisObservability: Sendable {

    let logger: RedisLogger
    let metrics: RedisMetricsRecorder

    init(logger: Logger) {
        self.logger = RedisLogger(logger)
        self.metrics = RedisMetricsRecorder()
    }
}
