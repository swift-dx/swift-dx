# Lifecycle and Fault Handling

How connections open, fail, retry, recycle, and shut down across the
raw transport, the async wrapper, and the pool.

## The three layers

`DXClickHouseRaw` exposes three connection objects, each adding one
concern over the previous layer:

1. ``RawClickHouseConnection`` — synchronous, owns the POSIX socket
   and the arena, performs the Native handshake, applies the
   reconnection policy.
2. ``AsyncRawClickHouseConnection`` — wraps a single
   `RawClickHouseConnection` behind a serial `DispatchQueue` worker
   and a Swift `actor`. One outstanding request at a time.
3. ``RawClickHouseConnectionPool`` — owns N
   `AsyncRawClickHouseConnection` instances, hands them out one per
   concurrent caller, and applies idle-TTL, max-lifetime, and
   preflight-ping eviction.

The Codable façade ``RawClickHouseClient`` builds directly on layer 1
with its own private worker queue; the pool wraps layer 2. Pick the
layer you need:

- Single long-lived application connection: ``RawClickHouseClient``.
- Concurrent traffic with bounded parallelism: ``RawClickHouseConnectionPool``.
- Custom orchestration where you own the lifecycle:
  ``AsyncRawClickHouseConnection`` directly.

## Connection establishment

`init` does the full handshake before returning:

1. DNS resolution and TCP `connect` to `host:port`.
2. Hello packet exchange, including the negotiated protocol revision.
3. Population of ``RawClickHouseConnection/ServerInfo`` from the
   server's response.

A handshake failure surfaces as
`RawClickHouseError.connectionFailed(reason:)`. The connection object
is not created; nothing to clean up.

```swift
do {
    let client = try await RawClickHouseClient(
        host: "clickhouse.example.test",
        port: 9000,
        user: "service",
        password: secret,
        database: "analytics"
    )
} catch let error as RawClickHouseError {
    logger.error("ClickHouse connect failed: \(error.description)")
    throw error
}
```

## Reconnection policy

Each connection carries a ``ReconnectionPolicy``. Defaults: 5 attempts,
initial backoff 100ms, doubling, capped at 5s. To disable reconnection
entirely, pass ``ReconnectionPolicy/disabled``.

```swift
let policy = ReconnectionPolicy(
    maxAttempts: 10,
    initialBackoff: .milliseconds(50),
    maxBackoff: .seconds(2)
)
let connection = try await AsyncRawClickHouseConnection(
    host: host,
    port: port,
    reconnectionPolicy: policy
)
```

The connection layer applies the policy on the **send side** of a
query. If `sendQuery` fails with a transient I/O error (`EPIPE`,
`ECONNRESET`, or an unexpected mid-stream EOF that closed the socket
on the previous receive), the connection re-opens, re-handshakes, and
replays the send transparently. Receive-side failures cannot be
replayed because the server has already begun streaming a result; the
caller sees a typed `socketIOFailed` or `unexpectedEOF` error for the
in-flight query, but the next `sendQuery` works against a fresh socket
without manual recovery.

When the retry budget is exhausted, the layer throws
`RawClickHouseError.reconnectExhausted(attempts:)`.

## Pool semantics

``RawClickHouseConnectionPool`` is the production entry point for
concurrent ClickHouse traffic. A single instance owns up to
``RawClickHouseConnectionPool/Configuration/maxConnections`` underlying
connections and hands them out one per caller via
``RawClickHouseConnectionPool/withConnection(_:)``.

```swift
let pool = try await RawClickHouseConnectionPool(
    configuration: .init(
        endpoints: [
            RawEndpoint(host: "ch-1.example.test", port: 9000),
            RawEndpoint(host: "ch-2.example.test", port: 9000),
            RawEndpoint(host: "ch-3.example.test", port: 9000),
        ],
        user: "service",
        password: secret,
        database: "analytics",
        minConnections: 4,
        maxConnections: 32,
        acquireTimeout: .seconds(10),
        idleConnectionTTL: .seconds(300),
        maxConnectionLifetime: .seconds(3600),
        preflightPing: true,
        evictionInterval: .seconds(30)
    )
)
```

### Acquisition

`withConnection` returns the first available idle connection. If none
is idle and `inUse + idle < maxConnections`, the pool opens a new one.
Otherwise the caller suspends in an FIFO waiter queue.

If no connection becomes available within
``RawClickHouseConnectionPool/Configuration/acquireTimeout``, the
caller's task resumes with
``RawClickHouseConnectionPool/Failure/acquireTimedOut(after:)``.

### Multi-endpoint failover

When the pool needs to open a fresh connection, it walks the
configured `endpoints` array in round-robin order. Each unreachable
endpoint is recorded as a ``RawEndpointFailure`` and counted in
``RawClickHouseConnectionPool/Stats/endpointFailovers``. Only when
every endpoint refuses in one rotation does the pool surface
``RawClickHouseConnectionPool/Failure/allEndpointsFailed(failures:)``.

The pool does not currently mark endpoints as "down" between attempts;
each new acquisition starts the round-robin at the next index from the
previous successful open. A repeatedly-failing endpoint will be
attempted again on every cycle. This is intentional for the current
design — the pool has no health-check loop independent of the
acquire path — and is one of the surfaces planned for convergence
with ``DXClickHouse``.

### Idle eviction

A background sweep runs every
``RawClickHouseConnectionPool/Configuration/evictionInterval``. Each
idle connection is checked against two thresholds:

- **Idle TTL** (``RawClickHouseConnectionPool/Configuration/idleConnectionTTL``):
  closed if it has been unused for longer than this duration.
- **Max lifetime** (``RawClickHouseConnectionPool/Configuration/maxConnectionLifetime``):
  closed regardless of activity once it has been open for longer than
  this duration. Use this to recycle TLS sessions, server-side
  resources, or memory.

A connection that fails either check is also evicted at acquire time
before being handed out — the background sweep is a cleanup pass, not
the only line of defence.

### Preflight ping

With ``RawClickHouseConnectionPool/Configuration/preflightPing`` set
to `true`, every acquisition of a recycled idle connection round-trips
a Ping → Pong before handing it to the caller. A failing ping is
counted in ``RawClickHouseConnectionPool/Stats/evictedByPreflight``;
the pool discards the connection and opens a fresh one (subject to
the same multi-endpoint failover walk).

Preflight ping is the recommended setting when the network path
between the client and the server passes through a stateful middlebox
(load balancer, NAT, firewall) that can silently drop long-idle TCP
sessions.

### Statistics

``RawClickHouseConnectionPool/stats()`` returns a
``RawClickHouseConnectionPool/Stats`` snapshot. Useful counters:

- `idleConnections` / `inUseConnections` / `waiters`: current
  utilisation.
- `openedTotal` / `closedTotal`: lifetime open / close totals.
- `leasesGranted` / `leasesReleased`: lifetime acquire / release
  counts; a sustained gap indicates leaked acquisitions.
- `acquireTimeouts`: callers that gave up waiting.
- `evictedByIdleTTL` / `evictedByLifetime` / `evictedByPreflight`:
  why connections were thrown away; surface as separate counters in
  your metrics pipeline.
- `endpointFailovers`: number of times the pool walked past a
  non-responding endpoint during failover.

## Shutdown

Both the client and the pool expose `close()`. After `close()`:

- New operations on a closed ``RawClickHouseClient`` will throw via
  the wire layer because the socket is gone.
- New `withConnection` calls on a closed ``RawClickHouseConnectionPool``
  throw ``RawClickHouseConnectionPool/Failure/poolClosed``.
- Pending pool waiters are resumed with `poolClosed`.

The pool's background eviction task is cancelled during shutdown.
Outstanding connections held by in-flight `withConnection` bodies are
not forcefully closed — they are released back into the pool, which
closes them on receipt because `isShutdown == true`. Wait for
in-flight work to finish before treating shutdown as complete.

```swift
await pool.close()
```

## Error taxonomy

``RawClickHouseError`` is the single typed error returned by every
public throwing API. Treat each case explicitly:

| Case | Cause | Response |
|---|---|---|
| `connectionFailed(reason:)` | TCP / DNS / handshake refused | Retry on a different endpoint or alert. |
| `socketIOFailed(errno:syscall:)` | `send`/`recv` returned -1 mid-operation | Already retried per policy. Surface to caller. |
| `unexpectedEOF(bytesExpected:)` | Server closed mid-stream | Already retried per policy. Surface to caller. |
| `protocolError(stage:message:)` | Wire bytes violated framing | Bug; capture stage + message and report. |
| `queryFailed(serverException:)` | Server returned a structured Exception | Route on `serverException.code`. |
| `reconnectExhausted(attempts:)` | Retry budget exhausted on send | Bubble up; this is the layer's loudest signal. |
| `endpointsExhausted(failures:)` | Every endpoint rejected an open | Aggregate `failures` for diagnostics. |

`queryFailed` is the only case where the server told you what went
wrong in its own vocabulary. Decode the embedded
``RawClickHouseServerException`` to get the numeric code (stable
across ClickHouse versions), the named code (e.g. `UNKNOWN_TABLE`),
the message, and any chained nested exceptions.
