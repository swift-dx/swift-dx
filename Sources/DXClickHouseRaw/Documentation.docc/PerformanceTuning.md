# Performance Tuning

How to extract the throughput `DXClickHouseRaw` is designed for. Covers
client-side settings, server-side knobs that affect the wire workload,
and host kernel parameters that matter once a single client saturates
a CPU core.

## Throughput model

The raw transport's performance ceiling is set by three factors, in
order of dominance for most workloads:

1. **Server-side execution time.** The server's wall-clock cost to
   resolve, plan, and execute the query. Always the dominant cost for
   non-trivial queries.
2. **Wire-format decode in the client.** Native-protocol parsing,
   columnar materialisation, and Codable bridging. Dominant for
   simple `SELECT … FROM small_table` reads at high rate.
3. **Async dispatch + pool serialisation.** Per-operation actor hop,
   `DispatchQueue` post, and `CheckedContinuation` resume. Dominant
   only for tiny operations (ping, single-row scalar) at very high
   rate.

Tuning targets each layer in turn. Do not chase (3) until (1) and (2)
are flat.

## Client-side tuning

### Use the streaming SELECT for large result sets

`select(_:as:)` returns an `AsyncThrowingStream` that the wire layer
fills one block at a time. The decoder parses one block, yields all
its rows into the stream, then waits for the consumer to drain before
parsing the next. Total client memory is bounded by one block's worth
of columnar data plus the in-flight Swift values.

`selectAll(_:as:)` materialises the whole result into an `[T]`. Faster
for small result sets (no per-row stream coordination) but linear in
result size. Use `selectAll` when the result is bounded and known
small; use `select` otherwise.

### Pool sizing

Default pool size is 16. The right size depends on:

- **Concurrent caller count.** If you serve N concurrent HTTP requests
  and each one issues at most one ClickHouse query, set
  `maxConnections` ≈ N (bounded by server-side `max_concurrent_queries`).
- **Server-side query concurrency.** ClickHouse limits concurrent
  queries via `max_concurrent_queries` (default 100). Setting
  `maxConnections` higher than that is wasted; the server queues the
  excess.
- **Query mix.** Long-running analytical queries hold a connection for
  seconds; many short point lookups recycle a connection thousands of
  times per second. Size for the worst case in the mix.

Set `minConnections` equal to your steady-state concurrent query
count to amortise handshake cost. The pool pre-opens that many
connections during `init`.

### Settings that change wire workload

Server-side settings affect what the client has to parse, not just
how fast the server executes. Pass them via
``RawClickHouseQuerySettings``:

```swift
let settings = RawClickHouseQuerySettings([
    RawClickHouseQuerySetting(name: "max_block_size", value: "65536"),
    RawClickHouseQuerySetting(name: "max_threads", value: "4"),
    RawClickHouseQuerySetting(name: "output_format_parallel_formatting", value: "0"),
])
```

- `max_block_size` (default 65,536): rows per Native block on the
  wire. Larger blocks amortise per-block decode overhead in the
  client. Set higher (262,144) for bulk reads, lower (8,192) for
  latency-sensitive reads.
- `max_threads`: how many threads the server uses per query. More
  threads = faster server execution = bytes hit the client faster.
  Bounded by server CPU contention.
- `network_compression_method = "lz4"`: enables LZ4 on the wire.
  Trades CPU for bandwidth. Useful over slow networks; usually
  counterproductive on localhost or fast LAN.

### Query parameters over string concatenation

Use ``RawClickHouseQueryParameters`` for runtime values:

```swift
let parameters = RawClickHouseQueryParameters([
    RawClickHouseQueryParameter(name: "since", value: "2025-01-01"),
    RawClickHouseQueryParameter(name: "kind", value: "purchase"),
])
let rows = try await client.selectAll(
    """
    SELECT id, payload FROM events
    WHERE event_date >= {since:Date} AND kind = {kind:String}
    """,
    as: Event.self,
    parameters: parameters
)
```

The server parses the value against the declared type, eliminating
injection risk. It also caches the query plan across calls with
different parameter values.

### Avoid the callback overloads at peak rate

`scalar(_:as:completion:)` and friends spin up a `Task` per call to
bridge the async core to the closure. Direct `async/await` is one
allocation cheaper per call; use the callbacks only at the integration
boundary with non-async code.

## Kernel-level knobs

Tune these once your client is CPU-bound on a single core or you see
sustained packet drops under load. The defaults are fine for most
deployments.

### Linux TCP buffers

```
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

These raise the per-socket receive and send buffer ceilings to 16 MB.
The raw transport does not call `setsockopt(SO_RCVBUF / SO_SNDBUF)`
directly; it relies on the kernel's autotuning, which is capped by
`*_max`. A 16 MB ceiling lets large block transfers proceed without
small-window throttling on high-RTT links.

### Linux ephemeral ports

```
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
```

Relevant when many short-lived connections cycle through the pool —
each `Configuration.maxConnectionLifetime` recycle consumes one
ephemeral port. A reduced `tcp_fin_timeout` (default 60) lets the
kernel reclaim TIME_WAIT slots faster.

### Linux file descriptors

```
ulimit -n 65536
```

Each pool connection holds one file descriptor. Pools with high
`maxConnections` plus the kernel's per-connection overhead can hit
the default `nofile` limit (1024 on most distros). Raise per-process
and per-systemd-unit.

### macOS

macOS development hosts rarely need TCP-buffer tuning, but the
file-descriptor limit applies the same way. Raise via
`launchctl limit maxfiles` for system-wide changes.

## Expected throughput

Numbers below come from benchmarks run against ClickHouse 26.5 on a
single-host loopback (`127.0.0.1:9000`) on a modern x86_64 server with
isolated CPU cores. Treat them as a sanity-check ceiling, not a
contract:

| Workload | Approximate ceiling per client connection |
|---|---|
| `ping` round-trip | ~50,000 / s |
| Single-row scalar SELECT | ~30,000 / s |
| Wide-row streaming SELECT (12 columns, mixed types) | several million rows / s |
| Codable INSERT (1 KB rows, batched) | hundreds of thousands of rows / s |
| Pre-encoded `insertNativeBlock` | bounded by network and server-side commit |

The pool scales close to linearly with `maxConnections` up to the
server's `max_concurrent_queries` ceiling. Beyond that, additional
connections queue server-side and add no throughput.

For workload-specific numbers, build the benchmark target and run it
against your own server hardware — published numbers from any other
deployment are guidance, not a guarantee.

## When throughput is below expectations

Run through these checks in order:

1. **Server-side query time.** Run the same query via `clickhouse-client`
   and compare. If the server itself is slow, the client cannot fix it.
2. **Block size.** Inspect `max_block_size` and confirm the server is
   shipping reasonably-sized blocks (`SELECT * FROM system.events
   WHERE event = 'SelectedBytes'` and divide).
3. **CPU pinning.** A single client connection is bottlenecked on one
   CPU core for parse + decode. Pin the client process and the server
   to different cores; check `top` for the bottleneck core.
4. **Codable decode cost.** If the wire ceiling is close to the
   single-row throughput but rows/s is far lower, the bottleneck is
   in the Codable decoder. Profile with `swift package -c release
   build` then `perf record`.
5. **Pool waits.** Check ``RawClickHouseConnectionPool/Stats/waiters``
   and ``RawClickHouseConnectionPool/Stats/acquireTimeouts``. A
   non-zero waiter count under steady-state load means `maxConnections`
   is too low for the offered concurrency.
6. **Network compression.** If the client is bandwidth-bound, enable
   `network_compression_method = "lz4"`. If CPU-bound, ensure it is
   disabled.
