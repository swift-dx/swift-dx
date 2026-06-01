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

import Atomics
import Metrics

// Lock-free cumulative counters shared by the client and its pool, plus the
// swift-metrics instruments fed from the same events. Relaxed ordering is
// sufficient: each value is a single monotonic counter whose increment publishes
// no other memory. When no metrics backend is bootstrapped the instruments are
// no-ops, so the per-command cost is a couple of relaxed atomics and the
// pull-based snapshot stays available regardless.
final class RedisMetricsRecorder: Sendable {

    private let commands = ManagedAtomic<UInt64>(0)
    private let commandErrors = ManagedAtomic<UInt64>(0)
    private let retries = ManagedAtomic<UInt64>(0)
    private let poolTimeouts = ManagedAtomic<UInt64>(0)
    private let connectionsOpened = ManagedAtomic<UInt64>(0)
    private let commandDurationNanos = ManagedAtomic<UInt64>(0)

    private let commandCounter = Counter(label: "redis.commands")
    private let errorCounter = Counter(label: "redis.command.errors")
    private let retryCounter = Counter(label: "redis.command.retries")
    private let poolTimeoutCounter = Counter(label: "redis.pool.timeouts")
    private let connectionsOpenedCounter = Counter(label: "redis.connections.opened")
    private let commandDurationTimer = Metrics.Timer(label: "redis.command.duration")
    private let idleGauge = Gauge(label: "redis.pool.idle")
    private let inUseGauge = Gauge(label: "redis.pool.in_use")

    func recordCommand(durationNanos: UInt64) {
        commands.wrappingIncrement(ordering: .relaxed)
        commandDurationNanos.wrappingIncrement(by: durationNanos, ordering: .relaxed)
        commandCounter.increment()
        commandDurationTimer.recordNanoseconds(Int64(min(durationNanos, UInt64(Int64.max))))
    }

    func recordError() {
        commandErrors.wrappingIncrement(ordering: .relaxed)
        errorCounter.increment()
    }

    func recordRetry() {
        retries.wrappingIncrement(ordering: .relaxed)
        retryCounter.increment()
    }

    func recordPoolTimeout() {
        poolTimeouts.wrappingIncrement(ordering: .relaxed)
        poolTimeoutCounter.increment()
    }

    func recordConnectionOpened() {
        connectionsOpened.wrappingIncrement(ordering: .relaxed)
        connectionsOpenedCounter.increment()
    }

    func recordPoolGauges(idle: Int, inUse: Int) {
        idleGauge.record(Double(idle))
        inUseGauge.record(Double(inUse))
    }

    func snapshot() -> RedisClientMetrics {
        RedisClientMetrics(
            commandsTotal: commands.load(ordering: .relaxed),
            commandErrorsTotal: commandErrors.load(ordering: .relaxed),
            retriesTotal: retries.load(ordering: .relaxed),
            poolTimeoutsTotal: poolTimeouts.load(ordering: .relaxed),
            connectionsOpenedTotal: connectionsOpened.load(ordering: .relaxed),
            totalCommandDurationNanos: commandDurationNanos.load(ordering: .relaxed)
        )
    }
}
