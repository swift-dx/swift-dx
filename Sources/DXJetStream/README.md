<!--
===----------------------------------------------------------------------===
This source file is part of the SwiftDX open source project

Copyright (c) 2026 SwiftDX Contributors
Licensed under Apache License v2.0. See LICENSE for license information.

SPDX-License-Identifier: Apache-2.0
===----------------------------------------------------------------------===
-->

# DXJetStream

Swift native NATS JetStream client. NIO transport, NKey credentials,
pipelined publish, pull-based fetch.

## Quick start

```swift
import DXJetStream

let configuration = JetStreamConfiguration(endpoint: NatsEndpoint(host: "localhost"))
try await JetStream.withClient(configuration) { client in
    let stream = try StreamName("ORDERS")
    let subject = try Subject("orders.created")
    let consumer = try ConsumerName("orders_worker")
    try await client.ensure(stream, subject: subject)
    try await client.ensure(consumer, on: stream, ackWait: .seconds(30))
    try await client.publish(to: subject, payloads: [Array("hello".utf8)])
}
```

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swift-dx/swift-dx", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(
        name: "MyService",
        dependencies: [
            .product(name: "DXJetStream", package: "swift-dx"),
        ]
    ),
]
```

```swift
import DXJetStream
```

## Core concepts

### Transport

`DXJetStream` speaks the NATS client protocol over SwiftNIO. Each
`JetStreamClient` owns one `NIOAsyncChannel` to a single broker. Cluster
peers are discovered server-side via the NATS `INFO` frame, so the
configured ``NatsEndpoint`` can be any reachable cluster member; the
broker advertises the rest of the topology after the handshake.

### Streams and consumers

NATS JetStream is a publish/subscribe layer with server-side persistence.
A `Stream` captures one or more subjects into a durable log; a `Consumer`
is a server-side cursor over a stream that hands work to clients on
demand. `DXJetStream` exposes both as named, validated value types
(``StreamName``, ``ConsumerName``, ``Subject``) so invalid identifiers
fail at the call site with a typed ``JetStreamError`` rather than later
on the wire.

`JetStreamStreamAdmin.ensure(_:subject:)` creates the stream if missing,
updates it if present, and is idempotent. The same shape applies to
`JetStreamConsumerAdmin.ensure(_:on:configuration:)` for consumers.
Deletion goes through `delete(_:)`.

### Publish

`JetStreamPublisher` ships two flavours of publish: an `async` form that
waits for the broker's `+PUB ACK` for every message in the batch
(`publish(to:payloads:)`), and an `enqueue` form that returns a
``PublishHandle`` whose `wait()` resolves when the broker has acked.
The handle form supports pipelining many batches onto one connection
without waiting for the previous batch to drain.

The ``NatsOutgoingMessage`` overload carries optional headers and a
``NatsMessageDedup`` instruction so callers can opt into the broker's
`Nats-Msg-Id` deduplication window.

### Pull-based fetch

`DXJetStream` exposes pull consumers only. Each `fetch(from:for:needsPayload:)`
call returns a long-lived ``FetchStream`` bound to one server-side
consumer; subsequent `requestAndAwait(batch:expires:wait:)` calls reuse
the same subscription, send a pull request, and collect replies until
the batch is full, the server expires it (408), or the server reports
"no messages" (404). Pass `needsPayload: false` to suppress payload
materialisation when only headers and reply subjects are needed.

The continuous overload `messages(from:for:options:)` returns an
`AsyncThrowingStream<NatsMessage, Error>` that pulls new batches as the
consumer drains, with back-pressure naturally applied by async iteration.
A callback-style variant takes a ``DXMessageHandler`` instead.

### Ack policy

Server-side ``ConsumerConfiguration`` selects how the broker treats
acknowledgement: ``AckPolicy/explicit`` (each message acked
individually, the default), ``AckPolicy/all`` (acking message N also
acks every earlier in-flight message), or ``AckPolicy/none`` (the
broker does not track acks at all). On the client side, `ack(_:)` acks
one ``NatsMessage`` and `acknowledge(replies:)` acks a batch of reply
subjects collected from a prior `FetchStream.Result`.

### Credentials

NATS authenticates via NKeys: an Ed25519 keypair where the public
NKey identifies the user and the private seed signs a per-connection
nonce. The canonical container is a `.creds` file produced by the
`nsc` CLI. ``NatsCredentialsSource`` covers the common ways enterprise
deployments hand the creds payload to a running process: in-memory
``NatsCredentials``, an inline base64 string, or an environment
variable populated by a secret manager. The handshake resolves the
source only at connect time, so a missing or malformed value surfaces
as a connection error that names the failing source.

## Usage patterns

### Ad-hoc (scripts, jobs, tests)

Short-lived script-style usage. Open a client, run work, close it.

```swift
import DXJetStream

let client = try await JetStream.connect(JetStreamConfiguration(
    endpoint: NatsEndpoint(host: "nats", port: 4222),
    credentials: .base64Environment(variable: "NATS_CREDS_B64")
))
try await client.publish(to: try Subject("orders.created"), payloads: payloads)
await client.close()
```

Or with a scoped helper that always closes the client, even on throw:

```swift
try await JetStream.withClient(configuration) { client in
    try await client.publish(to: try Subject("orders.created"), payloads: payloads)
}
```

### Service-lifecycle (production services)

`JetStream.connect(_:)` returns `any JetStreamClient & Service`, so the
client plugs directly into `swift-service-lifecycle`. The service runs
the broker connection in the background and joins the surrounding
`ServiceGroup`'s graceful-shutdown signal handling.

```swift
import DXJetStream
import ServiceLifecycle

let client = try await JetStream.connect(JetStreamConfiguration(
    endpoint: NatsEndpoint(host: "nats", port: 4222),
    credentials: .base64Environment(variable: "NATS_CREDS_B64"),
    logger: .standard(label: "orders.jetstream"),
    eventLoopGroup: MultiThreadedEventLoopGroup.singleton
))

let group = ServiceGroup(services: [client, httpService], logger: logger)
try await group.run()

// From a request handler:
try await client.publish(to: try Subject("orders.created"), payloads: payloads)
```

The configuration accepts an externally-owned `EventLoopGroup` so the
service shares one NIO thread pool across every swift-server library in
the process.

## Operations and overloads

Every operation that accepts payload data is offered in raw `[UInt8]`
form (the performance primitive) and in higher-level forms that
delegate to it. Continuous reads are offered as `AsyncThrowingStream`
and as a ``DXMessageHandler`` callback. No NIO `ByteBuffer` overload is
exposed on the public surface today; the wire layer accepts byte
slices and shapes them into `ByteBuffer` internally.

### `publish` — synchronous publish

Sends a batch and awaits every `+PUB ACK` before returning.

```swift
try await client.publish(to: subject, payloads: [Array("hello".utf8)])

// With headers, dedup, and per-message metadata
try await client.publish(to: subject, messages: [
    NatsOutgoingMessage(
        dedup: .dedupId("order-42"),
        headers: [NatsHeader(name: "X-Tenant", value: "acme")],
        payload: Array(json.utf8)
    )
])
```

### `enqueue` — pipelined publish

Returns a ``PublishHandle`` without waiting. The caller pipelines many
batches onto one connection, then awaits each handle's `wait()` at the
end of the window.

```swift
var handles: [PublishHandle] = []
for batch in batches {
    handles.append(client.enqueue(to: subject, payloads: batch))
}
for handle in handles {
    try await handle.wait()
}
```

The `enqueue(to:messages:)` overload accepts ``NatsOutgoingMessage``
values so dedup IDs and headers ride alongside pipelined publishes.

### `fetch` — pull batch with explicit await

Opens a long-lived ``FetchStream`` against a server-side consumer.
Reuse the same handle for every pull on that consumer.

```swift
let stream = try await client.fetch(from: streamName, for: consumerName, needsPayload: true)
defer { Task { await client.close(stream) } }

let result = try await stream.requestAndAwait(batch: 100, expires: .seconds(5), wait: .fill)
for payload in result.payloads {
    handle(payload)
}
client.acknowledge(replies: result.replies)
```

``FetchWait`` selects throughput vs latency: ``FetchWait/fill`` waits
for the full batch (or 404/408), ``FetchWait/anyAvailable`` returns as
soon as one message lands, ``FetchWait/atLeast(_:)`` waits for a
specific minimum.

### `messages` — continuous async stream

Wraps `fetch` in a loop that re-issues pulls as the buffer drains.
Iterate with `for try await` and apply back-pressure by simply pausing
iteration.

```swift
for try await message in client.messages(from: streamName, for: consumerName) {
    handle(message)
    client.ack(message)
}
```

The overload that takes ``PullOptions`` (`batch`, `expires`, `wait`)
tunes round-trip behaviour for high-throughput streams.

### `messages` with `DXMessageHandler`

Closure-friendly alternative for callers who prefer event-driven
delivery or who bridge into non-async contexts. Returns a
``SubscriptionHandle`` whose `cancel()` ends iteration.

```swift
let subscription = client.messages(from: streamName, for: consumerName, handler: orderHandler)
defer { subscription.cancel() }
```

`DXMessageHandler` ships in `DXCore`. The handler receives
``NatsMessage`` values on `receive(_:)` and typed
``JetStreamError`` values on `receive(error:)`.

### `request` — request/reply

One round-trip request to a NATS subject, returning the reply as a
``NatsMessage``. Useful for service-style request handlers that listen
on a JetStream-backed subject.

```swift
let reply = try await client.request(at: try Subject("orders.lookup"), payload: idBytes)
```

### `ensure` / `delete` — admin

Stream and consumer admin lives on `JetStreamStreamAdmin` and
`JetStreamConsumerAdmin`. Both are idempotent.

```swift
try await client.ensure(streamName, subject: subject, storage: .file)
try await client.ensure(consumerName, on: streamName, configuration: .standard())
try await client.delete(streamName)
```

`ConsumerConfiguration.standard()` is a 30-second ackWait, explicit
ack policy, 1,000 max ack pending, any-subject filter, unlimited
delivery attempts. Override per field for custom shapes.

### `ack` / `acknowledge` — message acknowledgement

`ack(_:)` acks a single ``NatsMessage`` (its `reply` subject is the
ack inbox). `acknowledge(replies:)` acks an entire batch by replaying
the `replies` array a prior `FetchStream.Result` returned. Both forms
fire-and-forget; the broker does not respond to `ACK` frames.

## Configuration reference

### `JetStreamConfiguration`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `endpoint` | `NatsEndpoint` | (required) | NATS broker the client dials. Cluster peers are discovered server-side. |
| `credentials` | `NatsCredentialsSource` | `.anonymous` | Authentication source. ``anonymous`` for unauthenticated brokers, ``literal(_:)``, ``base64String(_:)``, or ``base64Environment(variable:)`` for credential delivery. |
| `logger` | `NatsLogger` | `.silent` | Sink for connection, publish, and fetch lifecycle events. Use `NatsLogger.standard(label:)` to forward to a `swift-log` `Logger`. |
| `eventLoopGroup` | `any EventLoopGroup` | private group | NIO event-loop group running network I/O. The convenience initialiser creates a private group sized by `expectedConnections`. The explicit `eventLoopGroup:` initialiser accepts an externally-owned group; ownership stays with the caller. |

### `NatsEndpoint`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | `String` | (required) | DNS name or IP of the NATS broker. |
| `port` | `Int` | `4222` | TCP port. `4222` is the standard NATS client port. |

### `ConsumerConfiguration`

| Field | Type | Standard | Description |
|-------|------|----------|-------------|
| `ackWait` | `TimeSpan` | `.seconds(30)` | Time the broker waits for an `ACK` before redelivery. |
| `ackPolicy` | `AckPolicy` | `.explicit` | `.explicit`, `.all`, or `.none`. |
| `maxAckPending` | `Int` | `1_000` | Cap on simultaneously unacked messages held by this consumer. |
| `subjectFilter` | `SubjectMatch` | `.any` | `.any` for the whole stream, or `.pattern(Subject)` for a subject filter. |
| `deliveryAttemptLimit` | `DeliveryAttemptLimit` | `.unlimited` | `.unlimited` or `.max(Int)`. After the cap, the broker dead-letters the message. |

### `PullOptions`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `batch` | `Int` | `100` | Maximum messages a single pull request will accept. |
| `expires` | `TimeSpan` | `.seconds(5)` | Server-side deadline before the pull request expires with a 408 status. |
| `wait` | `FetchWait` | `.anyAvailable` | `.fill`, `.anyAvailable`, or `.atLeast(Int)`. Selects throughput vs latency. |

## Error handling

``JetStreamError`` is the single typed error enum surfaced by every
public operation. Adding a case is a SemVer-breaking change because
exhaustive `switch` statements downstream stop compiling — that is
intentional.

| Case | Fires when | Recovery |
|------|-----------|----------|
| `invalidStreamName(String)` | ``StreamName`` initialiser rejected the input. | Fix the call-site string; allowed set is ASCII letters, digits, `-`, `_`, non-empty, max 255. |
| `invalidConsumerName(String)` | ``ConsumerName`` initialiser rejected the input. | Same allowed set as stream names. |
| `invalidSubject(String)` | ``Subject`` initialiser rejected the input. | Dot-separated tokens of `[A-Za-z0-9_\-$]`, no leading/trailing/double dots. |
| `notConnected` | An operation was called on a closed or never-opened client. | Open a fresh client via `JetStream.connect(_:)`. |
| `connectionFailed(reason:)` | TCP open or initial handshake failed before the NATS `+OK`. | Verify endpoint, network reachability, broker liveness. |
| `handshakeFailed(reason:)` | NATS `INFO`/`CONNECT` handshake completed transport but the broker rejected authentication or the protocol negotiation. | Inspect reason; usually a credentials mismatch or unsupported broker version. |
| `protocolError(reason:)` | An inbound frame violated the NATS framing contract. | Broker bug or transport corruption. Reconnect; surface the reason for operator triage. |
| `serverError(reason:)` | Broker returned `-ERR`. | Application-level — invalid subject, permission denied, slow consumer. The reason carries the broker's text. |
| `publishAckError(reason:)` | The broker returned a JetStream `+PUB NAK` or error payload instead of `+PUB ACK`. | Stream or schema issue; the reason carries the broker's diagnostic. |
| `publishTimedOut` | A publish handle never received its `+PUB ACK`. | Retry or reconnect. The publish may have committed server-side; pair with ``NatsMessageDedup/dedupId(_:)`` for at-least-once with deduplication. |
| `fetchStatus(code:)` | A pull returned a non-OK status. `404` is "no messages", `408` is "request expired". Both are normal flow-control signals on idle consumers. | Treat as empty result and pull again. |
| `fetchClosedBeforeCompletion` | A ``FetchStream`` was closed (by `close(_:)` or by the connection going away) while a pull was parked. | Open a fresh fetch stream after reconnect. |
| `credentialsEnvironmentMissing(variable:)` | ``base64Environment(variable:)`` resolved at connect time but the environment variable was empty or unset. | Set the variable; the case names which one. |
| `credentialsBase64Invalid(reason:)` | The credentials payload was not valid base64. | Re-encode the `.creds` file. |
| `credentialsJwtMissing` | The decoded creds file did not contain a `-----BEGIN NATS USER JWT-----` block. | Use a file produced by `nsc generate creds`. |
| `credentialsSeedMissing` | The decoded creds file did not contain a `-----BEGIN USER NKEY SEED-----` block. | Same as above. |
| `credentialsSeedInvalid(reason:)` | The NKey seed failed its checksum or prefix check. | Regenerate the user; the seed is corrupt. |
| `credentialsSignatureFailed(reason:)` | Ed25519 signing over the broker nonce raised. | Operational diagnostic — the reason carries the underlying crypto error. |
| `credentialsNonceMissing` | The broker advertised `auth_required` but did not send a nonce in `INFO`. | Broker misconfiguration; report to operators. |
| `transportError(reason:)` | Generic NIO transport failure not covered above. | The reason carries the underlying error description; reconnect on the next call. |

## Performance characteristics

The benchmark binary in `Benchmarks/Sources/JetStream/main.swift` drives
two modes against a localhost broker: pipelined publish and pull-based
fetch. Both modes report p50/p95/p99/p999 latency in microseconds and
sustained throughput. Environment variables (`NATS_PERF_PUBLISH_MESSAGES`,
`NATS_PERF_PUBLISH_BATCHES`, `NATS_PERF_PUBLISH_PIPELINE`,
`NATS_PERF_FETCH_BATCHES`, `NATS_PERF_PAYLOAD_BYTES`, …) tune the
workload shape; defaults are 100k messages, 1k per batch, 8-deep
pipeline, 64-byte payloads.

The publish path uses pipelined enqueue: many batches are written to
the NIO channel without waiting for the previous batch's `+PUB ACK`, so
throughput is bounded by the broker's ack pipeline rather than by
client round-trip time. The fetch path issues `PullOptions` requests
against one long-lived `FetchStream`, so per-pull latency is one
broker round-trip plus the time to drain `batch` messages from the
inbound buffer.

Numbers vary with hardware, broker storage mode (`.file` vs `.memory`),
message size, and consumer ack pattern. The bench harness is the
reproducible source.

## Documentation

The DocC documentation for every public symbol is inline in the
sources. Generate it with:

```bash
swift package generate-documentation --target DXJetStream
```

Worked examples ship under `Examples/Sources/JetStream/`:

- `PublishAndFetch/main.swift` — minimum-viable publish, fetch, ack.
- `TestingPatterns/main.swift` — patterns for mocking
  ``JetStreamClient`` in unit tests and exercising against a live
  broker in integration tests.
