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

// Soak phase. One AsyncClickHouseConnection drives a 13-mode round
// robin against bench_sample.events_NM and bench_ledgers.ledger_NM
// for the configured duration. The selection is RNG-driven so the
// run is reproducible and balanced — every mode runs roughly the same
// number of operations regardless of per-mode latency.
//
// Recorded per run:
//   * Per-operation latency, bucketed into per-minute windows.
//   * Cumulative RSS sample at every minute boundary.
//   * Cumulative error count by mode.
//
// Reported at the end:
//   * RSS baseline, peak, growth, growth fraction.
//   * P99 drift between minute 0 and the last minute (and a
//     per-minute table).
//   * Per-mode operation count + error count.
enum StabilitySoak {

    private static let p99DriftCeilingFraction: Double = 0.20

    private enum Mode: Int, CaseIterable, Sendable {

        case eventsScalarCount
        case eventsOrderByLimit
        case eventsGroupBy
        case eventsWhereIn
        case eventsFullScanProjection
        case eventsLowCardinalityAggregation
        case eventsStringFilterScalar
        case eventsViewFullScanProjection
        case ledgerPointLookupById
        case ledgerHasRefs
        case ledgerHasRefsKinds
        case ledgerHasUserActors
        case ledgerKindSlice

        var label: String {
            switch self {
            case .eventsScalarCount: "events_scalar_count"
            case .eventsOrderByLimit: "events_orderby_limit"
            case .eventsGroupBy: "events_groupby"
            case .eventsWhereIn: "events_where_in"
            case .eventsFullScanProjection: "events_full_scan_proj"
            case .eventsLowCardinalityAggregation: "events_lc_aggregation"
            case .eventsStringFilterScalar: "events_string_filter"
            case .eventsViewFullScanProjection: "events_view_full_scan_proj"
            case .ledgerPointLookupById: "ledger_point_lookup_by_id"
            case .ledgerHasRefs: "ledger_has_refs"
            case .ledgerHasRefsKinds: "ledger_has_ref_kinds"
            case .ledgerHasUserActors: "ledger_has_participants"
            case .ledgerKindSlice: "ledger_kind_slice"
            }
        }
    }

    static func run() async {
        print("[STAB SOAK] starting duration=\(stabilitySoakDuration)s modes=13 target=\(stabilityRealEventsTable),\(stabilityLedgerTable)")

        let connection: AsyncClickHouseConnection
        do {
            connection = try await AsyncClickHouseConnection(
                host: stabilityHost,
                port: stabilityPort,
                user: stabilityUser,
                password: stabilityPassword,
                database: stabilityDatabase
            )
        } catch {
            print("[STAB SOAK] FAIL connect error=\(error)")
            return
        }
        defer { Task { await connection.close() } }

        var rng = StabilityRNG(seed: 0x50AC_F00D_5EED_BEEF)
        let soakStart = ContinuousClock.now
        let deadline = soakStart.advanced(by: .seconds(stabilitySoakDuration))

        var windows: [StabilityWindow] = []
        var currentWindow = StabilityWindow()
        var currentMinuteIndex = 0
        var modeCounts = [Int](repeating: 0, count: Mode.allCases.count)
        var modeErrors = [Int](repeating: 0, count: Mode.allCases.count)

        let baselineRSS = StabilityRSS.currentBytes()
        var peakRSS = baselineRSS
        var rssTrail: [(minute: Int, bytes: UInt64)] = [(0, baselineRSS)]

        var totalOperations = 0
        var totalErrors = 0
        var totalLatencyMicroseconds: Int64 = 0
        var lastMinuteLogged = -1

        while ContinuousClock.now < deadline {
            let elapsedMicroseconds = StabilityClock.microsecondsSince(soakStart)
            let elapsedMinute = Int(elapsedMicroseconds / 60_000_000)
            if elapsedMinute > currentMinuteIndex {
                windows.append(currentWindow)
                currentWindow = StabilityWindow()
                currentMinuteIndex = elapsedMinute
                let nowRSS = StabilityRSS.currentBytes()
                peakRSS = max(peakRSS, nowRSS)
                rssTrail.append((elapsedMinute, nowRSS))
            }
            if elapsedMinute > lastMinuteLogged && elapsedMinute > 0 {
                let recent = windows[windows.count - 1]
                print("[STAB SOAK] minute=\(elapsedMinute) ops=\(recent.samples.count) errors=\(recent.errors) p50_us=\(recent.p50Microseconds()) p95_us=\(recent.p95Microseconds()) p99_us=\(recent.p99Microseconds()) rss_mb=\(rssTrail[rssTrail.count - 1].bytes / 1024 / 1024)")
                lastMinuteLogged = elapsedMinute
            }

            let modeIndex = Int(rng.next() % UInt64(Mode.allCases.count))
            let mode = Mode.allCases[modeIndex]
            modeCounts[modeIndex] += 1
            let opStart = ContinuousClock.now
            do {
                try await runMode(mode, connection: connection, rng: &rng)
                let latency = StabilityClock.microsecondsSince(opStart)
                currentWindow.record(microseconds: latency)
                totalLatencyMicroseconds += latency
                totalOperations += 1
            } catch {
                currentWindow.recordError()
                modeErrors[modeIndex] += 1
                totalErrors += 1
            }
        }
        windows.append(currentWindow)
        let finalRSS = StabilityRSS.currentBytes()
        peakRSS = max(peakRSS, finalRSS)
        rssTrail.append((windows.count, finalRSS))

        let firstP99 = windows.first?.p99Microseconds() ?? 0
        let lastNonEmptyWindow = windows.reversed().first(where: { !$0.samples.isEmpty })
        let lastP99 = lastNonEmptyWindow?.p99Microseconds() ?? 0
        let p99DriftFraction: Double = (firstP99 > 0) ? Double(lastP99 - firstP99) / Double(firstP99) : 0
        let rssGrowthBytes = Int64(peakRSS) - Int64(baselineRSS)
        let rssGrowthFraction: Double = baselineRSS > 0 ? Double(rssGrowthBytes) / Double(baselineRSS) : 0
        let durationSeconds = StabilityClock.elapsedSeconds(soakStart)
        let throughputPerSecond = durationSeconds > 0 ? Double(totalOperations) / durationSeconds : 0
        let driftWithinSpec = (firstP99 == 0) || (p99DriftFraction <= p99DriftCeilingFraction)
        let leakBounded = rssGrowthFraction <= 0.50

        print("[STAB SOAK] summary duration=\(Int(durationSeconds))s total_ops=\(totalOperations) total_errors=\(totalErrors) throughput_ops_per_s=\(String(format: "%.1f", throughputPerSecond)) mean_us=\(totalOperations > 0 ? totalLatencyMicroseconds / Int64(totalOperations) : 0)")
        print("[STAB SOAK] rss baseline_mb=\(baselineRSS / 1024 / 1024) peak_mb=\(peakRSS / 1024 / 1024) growth_mb=\(rssGrowthBytes / 1024 / 1024) growth_pct=\(String(format: "%.1f", rssGrowthFraction * 100))")
        print("[STAB SOAK] p99 first_minute_us=\(firstP99) last_minute_us=\(lastP99) drift_pct=\(String(format: "%.1f", p99DriftFraction * 100)) ceiling_pct=20.0")
        for index in 0..<windows.count where !windows[index].samples.isEmpty {
            print("[STAB SOAK] window minute=\(index) ops=\(windows[index].samples.count) errors=\(windows[index].errors) p50_us=\(windows[index].p50Microseconds()) p95_us=\(windows[index].p95Microseconds()) p99_us=\(windows[index].p99Microseconds())")
        }
        for sample in rssTrail {
            print("[STAB SOAK] rss minute=\(sample.minute) bytes=\(sample.bytes) mb=\(sample.bytes / 1024 / 1024)")
        }
        for index in 0..<Mode.allCases.count {
            print("[STAB SOAK] mode \(Mode.allCases[index].label) ops=\(modeCounts[index]) errors=\(modeErrors[index])")
        }
        print("[STAB SOAK] verdict drift_within_20pct=\(driftWithinSpec) zero_errors=\(totalErrors == 0) leak_bounded=\(leakBounded)")
        let passed = driftWithinSpec && totalErrors == 0 && leakBounded
        print("[STAB SOAK] result=\(passed ? "PASS" : "FAIL")")
    }

    private static func runMode(_ mode: Mode, connection: AsyncClickHouseConnection, rng: inout StabilityRNG) async throws {
        switch mode {
        case .eventsScalarCount:
            try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityRealEventsTable) WHERE event_type = 'click'")
            _ = try await connection.receiveScalarUInt64()
        case .eventsOrderByLimit:
            let sql = "SELECT id, user_id, event_type, value, payload, ts FROM \(stabilityRealEventsTable) WHERE event_type = 'click' ORDER BY ts DESC LIMIT 1000"
            try await connection.sendQuery(sql)
            _ = try await connection.drainBlocks()
        case .eventsGroupBy:
            let sql = "SELECT user_id, count(*) AS c FROM \(stabilityRealEventsTable) GROUP BY user_id ORDER BY c DESC LIMIT 1000"
            try await connection.sendQuery(sql)
            _ = try await connection.drainBlocks()
        case .eventsWhereIn:
            let limit = 1000 + Int(rng.next() % 5_000)
            let sql = "SELECT id, user_id, ts, value FROM \(stabilityRealEventsTable) WHERE user_id IN (SELECT number FROM numbers(1, \(limit))) LIMIT \(limit)"
            try await connection.sendQuery(sql)
            _ = try await connection.drainBlocks()
        case .eventsFullScanProjection:
            // Bounded projection so the soak loop doesn't sit on one
            // 10M-row scan per iteration. LIMIT 200k still exercises
            // the streaming path through several data blocks.
            let sql = "SELECT id, ts, value FROM \(stabilityRealEventsTable) LIMIT 200000"
            try await connection.sendQuery(sql)
            _ = try await connection.drainBlocks()
        case .eventsLowCardinalityAggregation:
            let sql = "SELECT event_type, avg(value) AS avg_value FROM \(stabilityRealEventsTable) GROUP BY event_type"
            try await connection.sendQuery(sql)
            _ = try await connection.drainBlocks()
        case .eventsStringFilterScalar:
            try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityRealEventsTable) WHERE payload LIKE '%abc%'")
            _ = try await connection.receiveScalarUInt64()
        case .eventsViewFullScanProjection:
            let sql = "SELECT payload FROM \(stabilityRealEventsTable) LIMIT 50000"
            try await connection.sendQuery(sql)
            _ = try await connection.extractStringsDrain()
        case .ledgerPointLookupById:
            let id = StabilityIdentifiers.aggregateId(Int(rng.next() % UInt64(stabilityLedgerUniqueIds)))
            try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityLedgerTable) WHERE entity_id = '\(id)'")
            _ = try await connection.receiveScalarUInt64()
        case .ledgerHasRefs:
            let ref = StabilityIdentifiers.aggregateId(Int(rng.next() % 8))
            try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityLedgerTable) WHERE has(entity_refs, '\(ref)')")
            _ = try await connection.receiveScalarUInt64()
        case .ledgerHasRefsKinds:
            let kind = StabilityIdentifiers.aggregateKind(Int(rng.next() % 16))
            try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityLedgerTable) WHERE has(entity_ref_kinds, '\(kind)')")
            _ = try await connection.receiveScalarUInt64()
        case .ledgerHasUserActors:
            let actor = StabilityIdentifiers.aggregateId(Int(rng.next() % 1000))
            try await connection.sendQuery("SELECT toInt64(count()) FROM \(stabilityLedgerTable) WHERE has(participant_ids, '\(actor)')")
            _ = try await connection.receiveScalarUInt64()
        case .ledgerKindSlice:
            let kind = StabilityIdentifiers.aggregateKind(Int(rng.next() % UInt64(stabilityLedgerKinds)))
            let sql = "SELECT entity_id, created_at FROM \(stabilityLedgerTable) WHERE entity_kind = '\(kind)' ORDER BY created_at DESC LIMIT 1000"
            try await connection.sendQuery(sql)
            _ = try await connection.drainBlocks()
        }
    }
}
