# SwiftDX Benchmarks

Localhost performance benchmarks for the libraries shipped in `swift-dx`.
Used to track throughput and latency regressions over time and to compare
against equivalent implementations in other ecosystems (Go, Rust, Java).

This is a **separate SwiftPM package** (not part of the main `swift-dx`
package) so it can apply release-build flags that would not be safe to
impose on downstream consumers of the libraries.

## Build Flags

The package applies the following release-mode flags:

- `-enforce-exclusivity=unchecked` — disables the dynamic-exclusivity
  checks in release builds, removing the per-access overhead.
- `-cross-module-optimization` — enables CMO across the package's
  modules, letting the optimizer specialize generics and inline across
  module boundaries.

These are appropriate for measuring upper-bound performance but are not
applied to the consumer-facing libraries.

## Available Benchmarks

### `JetStreamBenchmark`

Measures the `DXJetStream` client on three workloads:

- **Sync publish** — each publish awaits its `PublishAck` before the next.
  Models the worst-case per-message ack-bound throughput.
- **Pipelined publish** — multiple publishes in flight, acks awaited at
  the end of a batch. Models high-throughput publish pipelines.
- **Fetch batch** — pull-consumer fetches large batches of messages.
  Models throughput-oriented consumers.

Each workload reports messages/second and p50/p99/p999 latency.

## Running

You need a running NATS broker on `localhost:4222`. Use the docker-compose
cluster bundled in this repository:

```sh
cd ../Tooling/Compose
docker compose --profile nats up -d
cd ../../Benchmarks
```

Build with release flags and run:

```sh
swift build -c release --product JetStreamBenchmark
./.build/release/JetStreamBenchmark
```

The benchmark accepts environment variables to control workload parameters
(`NATS_PERF_PAYLOAD`, `NATS_PERF_BATCH`, etc.). See the source for the
full list.

## Layout

```
Benchmarks/
├── Package.swift                # separate SwiftPM package
└── Sources/
    └── JetStream/main.swift     # → JetStreamBenchmark
```

## Interpreting Results

Benchmark numbers are workload- and host-specific. The same benchmark on
two different machines will produce different absolute numbers. Use the
benchmark to detect **regressions** within a single host, not to compare
absolute performance across environments.

When investigating a regression, run the suspect commit and its parent
back-to-back on the same host, against the same broker, with the same
environment variables.
