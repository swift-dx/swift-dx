# Local Dev Compose

Docker Compose layout for local development and integration testing.
Every service is gated by a Compose profile, so you bring up only the
backends you need.

## Quick start

```bash
# 3-node NATS JetStream cluster
docker compose -f Tooling/Compose/docker-compose.yml --profile nats up -d

# everything that is wired up
docker compose -f Tooling/Compose/docker-compose.yml --profile all up -d

# stop and remove containers (keeps data volumes)
docker compose -f Tooling/Compose/docker-compose.yml --profile nats down

# full teardown including volumes
docker compose -f Tooling/Compose/docker-compose.yml --profile nats down -v
```

`docker compose ... up` with no `--profile` starts nothing, by design.
Selection is always explicit.

## NATS cluster

Three NATS 2.10 nodes forming a single JetStream cluster named
`swift-dx`. Each node runs from its own configuration file under
`nats/` and persists JetStream state to a named Docker volume.

| Node    | Container        | Client port | Monitor port | Cluster port |
|---------|------------------|-------------|--------------|--------------|
| `nats1` | `swift-dx-nats1` | `4222`      | `8222`       | `6222` (internal) |
| `nats2` | `swift-dx-nats2` | `4223`      | `8223`       | `6222` (internal) |
| `nats3` | `swift-dx-nats3` | `4224`      | `8224`       | `6222` (internal) |

Cluster routes (`6222`) are reachable only on the internal
`swift-dx` Docker network. Clients connect on the published client
ports (`4222`, `4223`, `4224`).

Verify cluster health after `up`:

```bash
curl -s http://localhost:8222/jsz | jq '.cluster'
```

Each node should report the same cluster name and the same three peers.

### Running the integration test suite

The DXJetStream integration suite skips itself unless `NATS_TEST_HOST`
is set. Point it at any node:

```bash
docker compose -f Tooling/Compose/docker-compose.yml --profile nats up -d
export NATS_TEST_HOST=localhost
export NATS_TEST_PORT=4222
swift test --filter DXJetStreamIntegration
```

To exercise a different node, change `NATS_TEST_PORT` to `4223` or
`4224`.

## ClickHouse

One ClickHouse server (`clickhouse/clickhouse-server:26.5-alpine`),
auto-creates a `test` database. The `default` user is used with an
empty password — fine for local development, never for anything
network-reachable.

| Node          | Container               | Native TCP | HTTP   |
|---------------|-------------------------|------------|--------|
| `clickhouse1` | `swift-dx-clickhouse1`  | `9000`     | `8123` |

The native TCP port (`9000`) is what `DXClickHouse` talks to. The HTTP
port (`8123`) is exposed for `clickhouse-client`-style probes and the
`/ping` healthcheck.

Verify after `up`:

```bash
curl -s http://localhost:8123/ping     # expects "Ok."
```

### Running the integration test suite

The DXClickHouse integration suite skips itself unless
`CH_INTEGRATION_HOST` is set:

```bash
docker compose -f Tooling/Compose/docker-compose.yml --profile clickhouse up -d
export CH_INTEGRATION_HOST=localhost
export CH_INTEGRATION_PORT=9000
export CH_INTEGRATION_USER=default
export CH_INTEGRATION_PASSWORD=
export CH_INTEGRATION_DATABASE=test
swift test --filter DXClickHouseIntegration
```

The multi-node suite (`CH_INTEGRATION_HOST_2`), TLS suite
(`CH_TLS_HOST`, `CH_TLS_CA_PATH`, …), and slow-loris suite stay
skipped until those env vars are also set; the single-node profile
above is enough for the main integration matrix.

## Adding another service (Redis, Postgres, …)

Each new service follows the same shape as the existing ones:

1. Add a folder under `Tooling/Compose/` for the service's
   configuration (e.g. `redis/redis.conf`).
2. Add a service block to `docker-compose.yml` with:
   - a dedicated `container_name` prefixed `swift-dx-`,
   - `profiles: ["<service>", "all"]`,
   - the `swift-dx` network,
   - a healthcheck on the service's own readiness endpoint,
   - a named volume for any persistent state.
3. Update the table in this README with the new ports.

Subset selection works out of the box once profiles are wired up:

```bash
# NATS + ClickHouse together
docker compose -f Tooling/Compose/docker-compose.yml \
  --profile nats --profile clickhouse up -d

# everything
docker compose -f Tooling/Compose/docker-compose.yml --profile all up -d
```

## Files

```
Tooling/Compose/
├── docker-compose.yml       # service definitions, profile-gated
├── README.md                # this file
└── nats/
    ├── nats1.conf
    ├── nats2.conf
    └── nats3.conf
```
