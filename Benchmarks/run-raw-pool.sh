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
# Runner for ClickHouseRawPoolBenchmark: pool throughput, single-conn
# baseline, acquire microbench, and a deadlock-stress sweep at high
# tasks-per-connection contention. Writes per-trial logs into
# results/raw-pool/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ROOT="$REPO_ROOT/Benchmarks"
POOL_BIN="$BENCH_ROOT/.build/release/ClickHouseRawPoolBenchmark"
CPP_BIN="$BENCH_ROOT/Tooling/cpp-bench/build/dx_clickhouse_cpp_bench"
RESULTS_DIR="${RESULTS_DIR:-$BENCH_ROOT/results/raw-pool}"

if [[ ! -x "$POOL_BIN" ]]; then
    echo "error: pool bench binary not found at $POOL_BIN" >&2
    echo "       run: cd Benchmarks && swift build --product ClickHouseRawPoolBenchmark -c release" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

export CH_BENCH_POOL_TASKS="${CH_BENCH_POOL_TASKS:-100}"
export CH_BENCH_POOL_MAX="${CH_BENCH_POOL_MAX:-8}"
export CH_BENCH_POOL_MIN="${CH_BENCH_POOL_MIN:-1}"
export CH_BENCH_POOL_ACQUIRE_ITERATIONS="${CH_BENCH_POOL_ACQUIRE_ITERATIONS:-200000}"

# Reset the insert target so each run starts from an empty table; the
# bench writes 100 rows per run and the rows are persistent.
if command -v curl >/dev/null 2>&1; then
    curl -s "http://${CH_BENCH_HOST:-localhost}:8123/" --data "DROP TABLE IF EXISTS test.pool_inserts" >/dev/null || true
fi

RUNS=${RUNS:-3}

for run in $(seq 1 "$RUNS"); do
    echo ">>> pool bench run $run/$RUNS (tasks=$CH_BENCH_POOL_TASKS pool_max=$CH_BENCH_POOL_MAX)"
    CH_BENCH_MODES=pool_acquire_overhead,single_select_raw_async,concurrent_select_raw_pool,single_insert_raw_async,concurrent_insert_raw_pool \
        "$POOL_BIN" 2>&1 | tee "$RESULTS_DIR/run-${run}.log"
done

echo ">>> scaling sweep (pool_max=1,2,4,8,16)"
for size in 1 2 4 8 16; do
    CH_BENCH_POOL_MAX=$size CH_BENCH_MODES=concurrent_select_raw_pool \
        "$POOL_BIN" 2>&1 | tee "$RESULTS_DIR/scaling-pool-${size}.log" | grep -E '(concurrent_select|OK no|FAIL)'
done

echo ">>> deadlock stress (500 tasks vs 4 conns, 5 trials)"
for trial in $(seq 1 5); do
    CH_BENCH_POOL_TASKS=500 CH_BENCH_POOL_MAX=4 CH_BENCH_MODES=concurrent_select_raw_pool \
        "$POOL_BIN" 2>&1 | tee "$RESULTS_DIR/stress-trial-${trial}.log" | grep -E '(concurrent_select|final_stats|OK no|FAIL)'
done

if [[ -x "$CPP_BIN" ]]; then
    echo ">>> C++ single-thread reference (100 sequential point lookups)"
    CH_BENCH_LEDGER_POINT_ITERATIONS=100 CH_BENCH_MODES=ledger_point_lookup_by_id \
        "$CPP_BIN" 2>&1 | tee "$RESULTS_DIR/cpp-reference.log"
fi

echo ">>> done. results in $RESULTS_DIR"
