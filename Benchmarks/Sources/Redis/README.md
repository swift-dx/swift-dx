<!--
===----------------------------------------------------------------------===
This source file is part of the SwiftDX open source project

Copyright (c) 2026 SwiftDX Contributors
Licensed under Apache License v2.0. See LICENSE for license information.

SPDX-License-Identifier: Apache-2.0
===----------------------------------------------------------------------===
-->

# RedisBenchmark

Microbenchmark harness for the `DXRedis` client. Runs one or more named modes
against a live Redis 8+ instance and prints one summary line per mode in the
`[REDIS PERF SWIFT]` namespace so a parser can pick it up alongside the
reference C harness (`[REDIS PERF C]`).

## Running

Start a Redis server (see `Tooling/Compose`, `docker compose --profile redis up -d`),
then:

```bash
cd Benchmarks
swift build -c release --product RedisBenchmark
REDIS_BENCH_HOST=127.0.0.1 .build/release/RedisBenchmark
```

## Configuration

All configuration is via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `REDIS_BENCH_HOST` | `127.0.0.1` | server host |
| `REDIS_BENCH_PORT` | `6379` | server port |
| `REDIS_BENCH_PASSWORD` | (none) | password; enables AUTH when set |
| `REDIS_BENCH_DATABASE` | `0` | logical database index |
| `REDIS_BENCH_KEYS` | `1000000` | total keys per throughput mode |
| `REDIS_BENCH_PIPELINE` | `10000` | commands per pipelined round trip |
| `REDIS_BENCH_VALUE_BYTES` | `16` | value size in bytes |
| `REDIS_BENCH_CONCURRENCY` | `8` | tasks/connections for the concurrent mode |
| `REDIS_BENCH_LATENCY_ITERATIONS` | `10000` | single-op latency samples |
| `REDIS_BENCH_MODES` | full matrix | comma-separated mode list |

## Modes

| Mode | What it measures |
|---|---|
| `set_batches` | one pipelined `SET` batch at sizes 1 / 100 / 100k / 1M |
| `set_pipelined` | total keys written via `setPipelined` in pipeline-sized chunks |
| `mset` | total keys written via atomic `MSET` in chunks |
| `get_pipelined` | total keys read via pipelined `GET` |
| `mget` | total keys read via `MGET` |
| `set_concurrent` | `concurrency` tasks writing in parallel through the pool |
| `latency_set` / `latency_get` | single-op p50/p95/p99/mean latency in microseconds |

Keys and values are generated before the timed section so the measurement
isolates the client and network from key formatting, matching the C harness.

## Comparing against C

`Tooling/run-redis-comparison.sh` builds and runs this harness, the reference
hiredis benchmark, and `redis-benchmark`, all against the same server with the
same `REDIS_BENCH_*` configuration. See `Tooling/redis-cpp/README.md`.
