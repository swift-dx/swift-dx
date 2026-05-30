# ``DXClickHouse``

A direct POSIX-socket ClickHouse client built around the Native binary
protocol. No NIO, no TLS, no event loop. The async surface is a thin
wrapper over a single serialised worker queue per connection, and a
pool over those connections.

## Overview

`DXClickHouse` is the lower of the two ClickHouse clients in SwiftDX.
It exists to keep one well-understood code path between Swift and the
ClickHouse Native protocol so the cost of every layer — wire framing,
columnar parsing, Codable bridging, async dispatch, connection pooling
— is measurable in isolation.

The public surface is small and composed of three layers:

- A synchronous transport (`ClickHouseConnection`) that owns a POSIX
  socket, performs the Native handshake, and serialises every request
  / response on the calling thread. Reconnection on transient I/O
  failures is built in and surfaces typed errors when the retry budget
  is exhausted.
- An async actor (`AsyncClickHouseConnection`) that owns a private
  `DispatchQueue` worker, posts each request onto it, and bridges
  completion through a `CheckedContinuation`. Per-block streaming is
  exposed via `AsyncThrowingStream`.
- A typed Codable façade (``ClickHouseClient``) plus a connection
  pool (``ClickHouseConnectionPool``) for production traffic. The
  client offers SQL execute, scalar reads, multi-row SELECT (streamed
  or fully collected), and columnar Codable INSERT.

Every operation that takes user-supplied SQL or row data is offered in
the canonical SwiftDX input forms — raw bytes, `String`, `Sequence`,
`AsyncSequence`, and `DXCallback` / `DXMessageHandler`. The performance
primitive is the raw bytes form; every other overload converts to the
primitive and delegates.

> Important: `DXClickHouse` is experimental. The wire transport
> works end-to-end against ClickHouse 26.5, and the typed Codable
> façade is exercised against the same workloads as `DXClickHouse`.
> Its public API may change as the two clients converge. For
> production traffic today, prefer ``DXClickHouse``.

## Topics

### Connecting

- ``ClickHouseClient``
- ``ClickHouseConnectionPool``
- ``AsyncClickHouseConnection``
- ``ClickHouseConnection``
- ``ClickHouseEndpoint``
- ``ReconnectionPolicy``

### Issuing queries

- ``ClickHouseQuerySettings``
- ``ClickHouseQuerySetting``
- ``ClickHouseQueryParameters``
- ``ClickHouseQueryParameter``

### Receiving results

- ``ClickHouseProgress``
- ``ClickHouseProfileInfo``
- ``ClickHouseProfileEvents``
- ``ClickHouseInsertSummary``
- ``ClickHouseTypedColumn``
- ``ClickHouseNamedColumn``
- ``ClickHouseNullable``

### Errors

- ``ClickHouseError``
- ``ClickHouseServerException``
- ``ClickHouseEndpointFailure``

### Guides

- <doc:Overloads>
- <doc:Lifecycle>
- <doc:PerformanceTuning>

## When to reach for this library

Reach for `DXClickHouse` when one of the following is true:

- You need to control the exact bytes and the exact thread on which
  socket I/O happens, with no NIO event loop in the middle.
- You are profiling the cost contribution of each layer — wire,
  Codable, async, pool — independently.
- You are running on a host where adding swift-nio to the dependency
  graph is not acceptable (resource-constrained sidecar, audit-bound
  build, etc.).

For every other case, ``DXClickHouse`` is the better choice today: it
offers the same typed Codable surface, the same overload set, and a
broader feature surface (TLS, observability hooks, multi-replica
routing) built on top of the same wire-format machinery this library
exercises.
