# Integration Tests

End-to-end tests that exercise the SwiftDX clients against real running
brokers. They are excluded from the default `swift test` run and skip
themselves when their broker environment is not configured.

## Running locally

The shared 3-node NATS cluster lives at
`Tooling/Compose/docker-compose.yml`. Start it, point the test suite at
any node, run the integration tests:

```bash
docker compose -f Tooling/Compose/docker-compose.yml --profile nats up -d
export NATS_TEST_HOST=localhost
export NATS_TEST_PORT=4222
swift test --filter DXJetStreamIntegration
```

Stop and clean up:

```bash
docker compose -f Tooling/Compose/docker-compose.yml --profile nats down -v
```

`Tooling/Compose/README.md` documents the cluster layout and how to add
further backends (ClickHouse, Redis, ...) alongside NATS.

## Environment variables

| Variable                | Required | Purpose                                       |
|-------------------------|----------|-----------------------------------------------|
| `NATS_TEST_HOST`        | yes      | Hostname for the NATS server under test.      |
| `NATS_TEST_PORT`        | no       | TCP port; defaults to 4222.                   |
| `NATS_TEST_CREDS_BASE64`| no       | Base64-encoded NATS credentials file for auth tests. |

When `NATS_TEST_HOST` is unset, the integration suite skips every test
case rather than failing. CI sets these variables explicitly for the
integration job; the default `swift test` run on a contributor's machine
does not need them.

## What is covered

| File                                       | Scenario                                                  |
|--------------------------------------------|-----------------------------------------------------------|
| `ConnectionIntegrationTests.swift`         | Connect, reconnect, close.                                |
| `AuthenticatedConnectionIntegrationTests.swift` | NATS credentials handshake.                          |
| `PublishIntegrationTests.swift`            | Publish single and batched messages.                      |
| `FetchIntegrationTests.swift`              | Pull-consumer fetch with acks.                            |
| `RequestReplyIntegrationTests.swift`       | Synchronous request/reply over the wire.                  |
| `StreamManagementIntegrationTests.swift`   | Create, configure, delete JetStream streams.              |
| `JetStreamClientIntegrationTests.swift`    | Full client lifecycle against a live server.              |
| `EndToEndIntegrationTests.swift`           | Publish + fetch + ack round-trip.                         |
