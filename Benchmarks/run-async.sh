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
# Hyperfine driver for async-raw vs sync-raw vs C++. Runs every mode
# exposed by ClickHouseAsyncBenchmark side-by-side with the matching
# mode in ClickHouseBenchmark and dx_clickhouse_cpp_bench. Produces
# per-mode JSON in results/raw-async/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ROOT="$REPO_ROOT/Benchmarks"
RAW_BIN="$BENCH_ROOT/.build/release/ClickHouseBenchmark"
ASYNC_BIN="$BENCH_ROOT/.build/release/ClickHouseAsyncBenchmark"
CPP_BIN="$BENCH_ROOT/Tooling/cpp-bench/build/dx_clickhouse_cpp_bench"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_ROOT/results/raw-async}"

WARMUP=${WARMUP:-1}
RUNS=${RUNS:-3}

if [[ ! -x "$RAW_BIN" ]]; then
    echo "error: sync raw bench binary not found at $RAW_BIN" >&2
    exit 1
fi
if [[ ! -x "$ASYNC_BIN" ]]; then
    echo "error: async raw bench binary not found at $ASYNC_BIN" >&2
    exit 1
fi
if [[ ! -x "$CPP_BIN" ]]; then
    echo "warn: C++ bench binary not found at $CPP_BIN; C++ runs will be skipped" >&2
fi
if ! command -v hyperfine >/dev/null 2>&1; then
    echo "error: hyperfine not installed" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

export CH_BENCH_LEDGER_POINT_ITERATIONS="${CH_BENCH_LEDGER_POINT_ITERATIONS:-200}"
export CH_BENCH_LEDGER_HAS_ITERATIONS="${CH_BENCH_LEDGER_HAS_ITERATIONS:-10}"
export CH_BENCH_LEDGER_KIND_ITERATIONS="${CH_BENCH_LEDGER_KIND_ITERATIONS:-20}"

SAMPLE_MODES_BOTH=(
    select_orderby_limit
    select_groupby
    select_where_in
    select_full_scan_proj
    select_lc_aggregation
    select_string_filter
    select_decode_only
    select_wire_only_count
)
SAMPLE_MODES_RAW_ONLY=(
    select_full_scan_proj_view
)
LEDGER_MODES=(
    ledger_point_lookup_by_id
    ledger_has_refs
    ledger_has_ref_kinds
    ledger_has_participants
    ledger_kind_slice
)

run_triple() {
    local mode="$1"
    echo ">>> hyperfine triple: $mode"
    if [[ -x "$CPP_BIN" ]]; then
        taskset -c 0 hyperfine \
            --warmup "$WARMUP" \
            --runs "$RUNS" \
            --export-json "$RESULTS_DIR/${mode}-compare.json" \
            --command-name "raw:$mode" \
            "env CH_BENCH_MODES=$mode CH_BENCH_LEDGER_POINT_ITERATIONS=$CH_BENCH_LEDGER_POINT_ITERATIONS CH_BENCH_LEDGER_HAS_ITERATIONS=$CH_BENCH_LEDGER_HAS_ITERATIONS CH_BENCH_LEDGER_KIND_ITERATIONS=$CH_BENCH_LEDGER_KIND_ITERATIONS '$RAW_BIN'" \
            --command-name "async:$mode" \
            "env CH_BENCH_MODES=$mode CH_BENCH_LEDGER_POINT_ITERATIONS=$CH_BENCH_LEDGER_POINT_ITERATIONS CH_BENCH_LEDGER_HAS_ITERATIONS=$CH_BENCH_LEDGER_HAS_ITERATIONS CH_BENCH_LEDGER_KIND_ITERATIONS=$CH_BENCH_LEDGER_KIND_ITERATIONS '$ASYNC_BIN'" \
            --command-name "cpp:$mode" \
            "env CH_BENCH_MODES=$mode CH_BENCH_LEDGER_POINT_ITERATIONS=$CH_BENCH_LEDGER_POINT_ITERATIONS CH_BENCH_LEDGER_HAS_ITERATIONS=$CH_BENCH_LEDGER_HAS_ITERATIONS CH_BENCH_LEDGER_KIND_ITERATIONS=$CH_BENCH_LEDGER_KIND_ITERATIONS '$CPP_BIN'" \
            || true
    else
        taskset -c 0 hyperfine \
            --warmup "$WARMUP" \
            --runs "$RUNS" \
            --export-json "$RESULTS_DIR/${mode}-compare.json" \
            --command-name "raw:$mode" \
            "env CH_BENCH_MODES=$mode CH_BENCH_LEDGER_POINT_ITERATIONS=$CH_BENCH_LEDGER_POINT_ITERATIONS CH_BENCH_LEDGER_HAS_ITERATIONS=$CH_BENCH_LEDGER_HAS_ITERATIONS CH_BENCH_LEDGER_KIND_ITERATIONS=$CH_BENCH_LEDGER_KIND_ITERATIONS '$RAW_BIN'" \
            --command-name "async:$mode" \
            "env CH_BENCH_MODES=$mode CH_BENCH_LEDGER_POINT_ITERATIONS=$CH_BENCH_LEDGER_POINT_ITERATIONS CH_BENCH_LEDGER_HAS_ITERATIONS=$CH_BENCH_LEDGER_HAS_ITERATIONS CH_BENCH_LEDGER_KIND_ITERATIONS=$CH_BENCH_LEDGER_KIND_ITERATIONS '$ASYNC_BIN'" \
            || true
    fi

    env CH_BENCH_MODES="$mode" "$RAW_BIN" \
        > "$RESULTS_DIR/${mode}-raw.log" 2>&1 || true
    env CH_BENCH_MODES="$mode" "$ASYNC_BIN" \
        > "$RESULTS_DIR/${mode}-async.log" 2>&1 || true
    if [[ -x "$CPP_BIN" ]]; then
        env CH_BENCH_MODES="$mode" "$CPP_BIN" \
            > "$RESULTS_DIR/${mode}-cpp.log" 2>&1 || true
    fi
}

run_pair_raw_async() {
    local mode="$1"
    echo ">>> hyperfine pair raw+async (no C++): $mode"
    taskset -c 0 hyperfine \
        --warmup "$WARMUP" \
        --runs "$RUNS" \
        --export-json "$RESULTS_DIR/${mode}-compare.json" \
        --command-name "raw:$mode" \
        "env CH_BENCH_MODES=$mode '$RAW_BIN'" \
        --command-name "async:$mode" \
        "env CH_BENCH_MODES=$mode '$ASYNC_BIN'" \
        || true

    env CH_BENCH_MODES="$mode" "$RAW_BIN" \
        > "$RESULTS_DIR/${mode}-raw.log" 2>&1 || true
    env CH_BENCH_MODES="$mode" "$ASYNC_BIN" \
        > "$RESULTS_DIR/${mode}-async.log" 2>&1 || true
}

for mode in "${SAMPLE_MODES_BOTH[@]}"; do
    run_triple "$mode"
done
for mode in "${SAMPLE_MODES_RAW_ONLY[@]}"; do
    run_pair_raw_async "$mode"
done
for mode in "${LEDGER_MODES[@]}"; do
    run_triple "$mode"
done

echo ">>> done. results in $RESULTS_DIR"
