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

// Lock-free cumulative counters shared by the client and its pool. Each value is
// a single monotonic counter where only the atomicity of the increment matters,
// so relaxed ordering is sufficient; no other memory is published alongside the
// update. `snapshot` reads each counter once into an immutable PostgresClientMetrics.
//
// The same events also feed swift-metrics instruments so they flow automatically
// into the application's bootstrapped metrics backend (Prometheus, StatsD, OTLP,
// ...): the consumer calls MetricsSystem.bootstrap once before constructing the
// client and the counters, latency timer, and pool gauges appear with no polling.
// When no backend is bootstrapped the instruments are no-ops, so the pull-based
// snapshot via PostgresClientMetrics is always available regardless.
final class PostgresMetricsRecorder: Sendable {

    private let queries = ManagedAtomic<UInt64>(0)
    private let queryErrors = ManagedAtomic<UInt64>(0)
    private let retries = ManagedAtomic<UInt64>(0)
    private let poolTimeouts = ManagedAtomic<UInt64>(0)
    private let connectionsOpened = ManagedAtomic<UInt64>(0)
    private let queryDurationNanos = ManagedAtomic<UInt64>(0)

    private let queryCounter = Counter(label: "postgres.queries")
    private let errorCounter = Counter(label: "postgres.query.errors")
    private let retryCounter = Counter(label: "postgres.query.retries")
    private let poolTimeoutCounter = Counter(label: "postgres.pool.timeouts")
    private let connectionsOpenedCounter = Counter(label: "postgres.connections.opened")
    private let queryDurationTimer = Metrics.Timer(label: "postgres.query.duration")
    private let idleGauge = Gauge(label: "postgres.pool.idle")
    private let inUseGauge = Gauge(label: "postgres.pool.in_use")

    func recordQuery(durationNanos: UInt64) {
        queries.wrappingIncrement(ordering: .relaxed)
        queryDurationNanos.wrappingIncrement(by: durationNanos, ordering: .relaxed)
        queryCounter.increment()
        queryDurationTimer.recordNanoseconds(Int64(min(durationNanos, UInt64(Int64.max))))
    }

    func recordError() {
        queryErrors.wrappingIncrement(ordering: .relaxed)
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

    func snapshot() -> PostgresClientMetrics {
        PostgresClientMetrics(
            queriesTotal: queries.load(ordering: .relaxed),
            queryErrorsTotal: queryErrors.load(ordering: .relaxed),
            retriesTotal: retries.load(ordering: .relaxed),
            poolTimeoutsTotal: poolTimeouts.load(ordering: .relaxed),
            connectionsOpenedTotal: connectionsOpened.load(ordering: .relaxed),
            totalQueryDurationNanos: queryDurationNanos.load(ordering: .relaxed)
        )
    }
}
