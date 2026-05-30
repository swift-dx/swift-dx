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
# Hyperfine driver for the final raw-floor measurement. Runs every mode
# exposed by the ClickHouseBenchmark binary. Five timing runs + two
# warmup runs per mode. Writes per-mode JSON to results/raw-final/.
#
# Iteration counts for the latency-sampling Ledger modes are tuned to
# keep each process invocation in the 0.5s to 4s window so hyperfine's
# wall-clock measurement has signal but the whole suite still finishes
# in a reasonable wall-clock budget.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ROOT="$REPO_ROOT/Benchmarks"

BENCH_CACHE_ROOT="${BENCH_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/swift-dx-bench}"
BENCH_RESULTS_DIR="${BENCH_RESULTS_DIR:-$BENCH_CACHE_ROOT/results}"
BENCH_VENDOR_DIR="${BENCH_VENDOR_DIR:-$BENCH_CACHE_ROOT/vendor}"
BENCH_BUILD_DIR="${BENCH_BUILD_DIR:-$BENCH_CACHE_ROOT/build}"

RAW_BIN="$BENCH_ROOT/.build/release/ClickHouseBenchmark"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_RESULTS_DIR/raw-final}"

WARMUP=2
RUNS=5

if [[ ! -x "$RAW_BIN" ]]; then
    echo "error: Raw bench binary not found at $RAW_BIN" >&2
    exit 1
fi
if ! command -v hyperfine >/dev/null 2>&1; then
    echo "error: hyperfine not installed" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# Tuned iteration counts (per single process invocation) to keep per-mode
# wall-clock in the 0.5-4s range.
export CH_BENCH_LEDGER_POINT_ITERATIONS="${CH_BENCH_LEDGER_POINT_ITERATIONS:-200}"
export CH_BENCH_LEDGER_HAS_ITERATIONS="${CH_BENCH_LEDGER_HAS_ITERATIONS:-10}"
export CH_BENCH_LEDGER_KIND_ITERATIONS="${CH_BENCH_LEDGER_KIND_ITERATIONS:-20}"
export CH_BENCH_LEDGER_STREAM_ITERATIONS="${CH_BENCH_LEDGER_STREAM_ITERATIONS:-20}"

SAMPLE_MODES=(
    select_orderby_limit
    select_groupby
    select_where_in
    select_full_scan_proj
    select_lc_aggregation
    select_string_filter
    select_decode_only
    select_wire_only_count
    select_full_scan_proj_view
)

# Ledger SELECT/latency modes. The two insert modes report SKIP on RAW
# so they are not included.
LEDGER_MODES=(
    ledger_point_lookup_by_id
    ledger_has_refs
    ledger_has_ref_kinds
    ledger_has_participants
    ledger_kind_slice
)

run_solo_raw() {
    local mode="$1"
    echo ">>> hyperfine solo (RAW): $mode"
    hyperfine \
        --warmup "$WARMUP" \
        --runs "$RUNS" \
        --export-json "$RESULTS_DIR/${mode}-compare.json" \
        --command-name "raw:$mode" \
        "env CH_BENCH_MODES=$mode CH_BENCH_LEDGER_POINT_ITERATIONS=$CH_BENCH_LEDGER_POINT_ITERATIONS CH_BENCH_LEDGER_HAS_ITERATIONS=$CH_BENCH_LEDGER_HAS_ITERATIONS CH_BENCH_LEDGER_KIND_ITERATIONS=$CH_BENCH_LEDGER_KIND_ITERATIONS CH_BENCH_LEDGER_STREAM_ITERATIONS=$CH_BENCH_LEDGER_STREAM_ITERATIONS '$RAW_BIN'" \
        || true

    env CH_BENCH_MODES="$mode" "$RAW_BIN" \
        > "$RESULTS_DIR/${mode}-raw.log" 2>&1 || true
}

for mode in "${SAMPLE_MODES[@]}"; do
    run_solo_raw "$mode"
done
for mode in "${LEDGER_MODES[@]}"; do
    run_solo_raw "$mode"
done

echo ">>> done. results in $RESULTS_DIR"
