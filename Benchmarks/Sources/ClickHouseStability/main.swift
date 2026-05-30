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

// Stability suite for the DXClickHouse transport. Runs three
// independent phases against a live ClickHouse instance:
//
//   * soak           — 13 read/scalar modes mixed at random for the
//                      configured duration (600s by default). Records
//                      RSS over time and minute-by-minute P99 drift.
//   * fault          — 7 failure scenarios (container kill+restart,
//                      mid-stream task cancellation, wrong-port connect,
//                      pool exhaustion, server-side query error, mid-
//                      receive TCP RST via a forwarder, mid-receive
//                      cancel). Each asserts a typed error surface and
//                      no resource leak.
//   * concurrency    — N tasks (default 100) × random 4-way query mix
//                      against a shared raw connection pool for the
//                      configured duration (300s default). Verifies
//                      zero errors, zero deadlocks, matching INSERT
//                      row counts post-run.
//
// Phase selection via env STAB_PHASE=soak|fault|concurrency|all
// (default "all"). Output is namespaced [STAB SOAK]/[STAB FAULT]/
// [STAB CONC] for downstream parsing.

private func env(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

private func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = env(key), let value = Int(raw) else { return fallback }
    return value
}

private func envString(_ key: String, _ fallback: String) -> String {
    env(key) ?? fallback
}

let stabilityHost = envString("CH_BENCH_HOST", "localhost")
let stabilityPort = envInt("CH_BENCH_PORT", 9000)
let stabilityUser = envString("CH_BENCH_USER", "default")
let stabilityPassword = envString("CH_BENCH_PASSWORD", "")
let stabilityDatabase = envString("CH_BENCH_DATABASE", "test")

let stabilityLedgerDatabase = envString("CH_BENCH_LEDGER_DATABASE", "bench_ledgers")
let stabilityLedgerRows = envInt("CH_BENCH_LEDGER_ROWS", 10_000_000)
let stabilityLedgerUniqueIds = max(1, envInt("CH_BENCH_LEDGER_UNIQUE_IDS", 100_000))
let stabilityLedgerKinds = max(1, envInt("CH_BENCH_LEDGER_KINDS", 2_000))
let stabilityLedgerTable = "\(stabilityLedgerDatabase).ledger_\(stabilityLedgerRows / 1_000_000)M"

let stabilityRealDatabase = envString("CH_BENCH_SAMPLE_DATABASE", "bench_sample")
let stabilityRealEventsRows = envInt("CH_BENCH_EVENTS_ROWS", 10_000_000)
let stabilityRealEventsTable = "\(stabilityRealDatabase).events_\(stabilityRealEventsRows / 1_000_000)M"

let stabilitySoakDuration = envInt("STAB_SOAK_SECONDS", 600)
let stabilityConcurrencyDuration = envInt("STAB_CONC_SECONDS", 300)
let stabilityConcurrencyTasks = envInt("STAB_CONC_TASKS", 100)
let stabilityFaultDockerName = envString("STAB_FAULT_DOCKER", "swift-dx-clickhouse1")
let stabilitySudoPath = envString("STAB_SUDO_PATH", "/usr/bin/sudo")
let stabilityDockerPath = envString("STAB_DOCKER_PATH", "/usr/bin/docker")
let stabilityPhase = envString("STAB_PHASE", "all")

print("[STAB] config host=\(stabilityHost) port=\(stabilityPort) database=\(stabilityDatabase) phase=\(stabilityPhase) soak=\(stabilitySoakDuration)s conc=\(stabilityConcurrencyDuration)s tasks=\(stabilityConcurrencyTasks) docker=\(stabilityFaultDockerName)")

let stabilityPhases = stabilityPhase.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
let stabilityRunAll = stabilityPhases.contains("all")

if stabilityRunAll || stabilityPhases.contains("soak") {
    await StabilitySoak.run()
}
if stabilityRunAll || stabilityPhases.contains("fault") {
    await StabilityFault.run()
}
if stabilityRunAll || stabilityPhases.contains("concurrency") {
    await StabilityConcurrency.run()
}

print("[STAB] done")
