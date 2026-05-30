#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
#
# This source file is part of the SwiftDX open source project
#
# Copyright (c) 2026 SwiftDX Contributors
# Licensed under Apache License v2.0. See LICENSE for license information.
#
# SPDX-License-Identifier: Apache-2.0
#
#===----------------------------------------------------------------------===#
#
# Drives the real-workload SELECT modes against the Swift (DXClickHouse)
# and C++ (clickhouse-cpp) benchmark binaries under hyperfine so each mode
# gets statistical confidence (median + 95% CI). The fixture
# (events_NN, logs_NN MergeTree tables) is created ONCE at the top of the
# run and reused by every Swift and C++ invocation thereafter; that way
# both clients query identical data and any rate delta comes from the
# client, not from the fixture.
#
# Usage:
#   ./run-real-workloads.sh                # generic real-workload modes, 10M/1M fixture
#   ./run-real-workloads.sh --ledgers   # event-sourced ledger-shape modes,
#                                          #   10M ledger_10M + ledger_writes fixture
#   CH_BENCH_EVENTS_ROWS=1000000 \         # smoke run, 1M events
#     CH_BENCH_LOGS_ROWS=100000 \
#     ./run-real-workloads.sh
#   CH_BENCH_LEDGER_ROWS=1000000 \     # smoke ledger, 1M ledger rows
#     ./run-real-workloads.sh --ledgers
#
# Outputs:
#   results/real-workloads/<mode>-swift.json
#   results/real-workloads/<mode>-cpp.json
#   results/real-workloads/<mode>-compare.json   (hyperfine native comparison)
#
# Environment variables forwarded to both binaries:
#   CH_BENCH_HOST, CH_BENCH_PORT, CH_BENCH_USER, CH_BENCH_PASSWORD
#   CH_BENCH_EVENTS_ROWS, CH_BENCH_LOGS_ROWS, CH_BENCH_FIXTURE_BLOCK
#   CH_BENCH_SAMPLE_DATABASE, CH_BENCH_SAMPLE_DECODE_ITERATIONS
#   CH_BENCH_LEDGER_ROWS, CH_BENCH_LEDGER_UNIQUE_IDS, CH_BENCH_LEDGER_KINDS
#   CH_BENCH_LEDGER_POINT_ITERATIONS, CH_BENCH_LEDGER_HAS_ITERATIONS
#   CH_BENCH_LEDGER_KIND_ITERATIONS, CH_BENCH_LEDGER_BULK_ROWS
#   CH_BENCH_LEDGER_STREAM_ITERATIONS, CH_BENCH_LEDGER_STREAM_ROWS
#   CH_BENCH_LEDGER_DATABASE

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ROOT="$REPO_ROOT/Benchmarks"

BENCH_CACHE_ROOT="${BENCH_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/swift-dx-bench}"
BENCH_RESULTS_DIR="${BENCH_RESULTS_DIR:-$BENCH_CACHE_ROOT/results}"
BENCH_VENDOR_DIR="${BENCH_VENDOR_DIR:-$BENCH_CACHE_ROOT/vendor}"
BENCH_BUILD_DIR="${BENCH_BUILD_DIR:-$BENCH_CACHE_ROOT/build}"

SWIFT_BIN="$BENCH_ROOT/.build/release/ClickHouseBenchmark"
CPP_BIN="${CPP_BIN:-$BENCH_BUILD_DIR/cpp-bench/dx_clickhouse_cpp_bench}"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_RESULTS_DIR/real-workloads}"

WARMUP="${CH_BENCH_HYPERFINE_WARMUP:-2}"
RUNS="${CH_BENCH_HYPERFINE_RUNS:-5}"

WORKLOAD="real"
for arg in "$@"; do
    case "$arg" in
        --ledgers) WORKLOAD="ledgers" ;;
        --real)       WORKLOAD="real" ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "       usage: $0 [--real|--ledgers]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "error: Swift bench binary not found at $SWIFT_BIN" >&2
    echo "       run: (cd Benchmarks && swift build -c release --product ClickHouseBenchmark)" >&2
    exit 1
fi
if [[ ! -x "$CPP_BIN" ]]; then
    echo "error: C++ bench binary not found at $CPP_BIN" >&2
    echo "       build it under \$BENCH_BUILD_DIR/cpp-bench (default: $BENCH_BUILD_DIR/cpp-bench)" >&2
    exit 1
fi
if ! command -v hyperfine >/dev/null 2>&1; then
    echo "error: hyperfine not installed" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

CH_BENCH_MODES_REAL=(
    select_orderby_limit
    select_groupby
    select_where_in
    select_full_scan_proj
    select_lc_aggregation
    select_string_filter
    select_decode_only
    select_wire_only_count
)

CH_BENCH_MODES_LEDGER=(
    ledger_point_lookup_by_id
    ledger_has_refs
    ledger_has_ref_kinds
    ledger_has_participants
    ledger_kind_slice
    ledger_bulk_insert
    ledger_stream_insert
)

if [[ "$WORKLOAD" == "ledgers" ]]; then
    SETUP_MODE="ledger_benchsetup"
    SETUP_LABEL="ledger fixture"
    SETUP_GREP="ledger_benchsetup"
    MODES=("${CH_BENCH_MODES_LEDGER[@]}")
else
    SETUP_MODE="benchsetup"
    SETUP_LABEL="real-workload fixture"
    SETUP_GREP="benchsetup"
    MODES=("${CH_BENCH_MODES_REAL[@]}")
fi

# One-shot fixture setup via the Swift harness (drops+recreates the
# database, so both clients see the same bytes). C++ benchsetup is
# functionally equivalent — pick one to avoid fighting over the schema.
echo ">>> creating $SETUP_LABEL (this overwrites the configured database)"
CH_BENCH_MODES="$SETUP_MODE" "$SWIFT_BIN" \
    > "$RESULTS_DIR/$SETUP_MODE.log" 2>&1
grep -E "^\[CH PERF SWIFT\] (config|$SETUP_GREP)" "$RESULTS_DIR/$SETUP_MODE.log" || true

for mode in "${MODES[@]}"; do
    echo ">>> running mode: $mode"
    hyperfine \
        --warmup "$WARMUP" \
        --runs "$RUNS" \
        --export-json "$RESULTS_DIR/${mode}-compare.json" \
        --command-name "swift:$mode" \
        "env CH_BENCH_MODES=$mode '$SWIFT_BIN'" \
        --command-name "cpp:$mode" \
        "env CH_BENCH_MODES=$mode '$CPP_BIN'" \
        || true

    # Per-binary single-shot run for the latency / first-byte / decode
    # numbers (hyperfine only reports the wall-clock; the [CH PERF *]
    # lines carry the structured detail).
    env CH_BENCH_MODES="$mode" "$SWIFT_BIN" \
        > "$RESULTS_DIR/${mode}-swift.log" 2>&1 || true
    env CH_BENCH_MODES="$mode" "$CPP_BIN" \
        > "$RESULTS_DIR/${mode}-cpp.log" 2>&1 || true
done

echo ">>> summary (median + 95% CI from hyperfine)"
for mode in "${MODES[@]}"; do
    compare_file="$RESULTS_DIR/${mode}-compare.json"
    if [[ ! -f "$compare_file" ]]; then continue; fi
    python3 - "$compare_file" "$mode" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
print(f"\n== {mode} ==")
for entry in data.get("results", []):
    name = entry["command"]
    mean = entry["mean"]
    stddev = entry["stddev"]
    median = entry.get("median", mean)
    ci95 = 1.96 * stddev / max(1, len(entry.get("times", [])) ** 0.5)
    print(f"  {name}: median={median*1000:.1f}ms mean={mean*1000:.1f}ms 95%CI=±{ci95*1000:.1f}ms")
PY
done
