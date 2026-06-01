# DXPostgres benchmark

Microbenchmark harness for DXPostgres against a live PostgreSQL (or wire-compatible)
server. Build in release and select modes with `POSTGRES_BENCH_MODES`.

```bash
POSTGRES_BENCH_HOST=localhost POSTGRES_BENCH_PORT=5432 \
POSTGRES_BENCH_USER=dxpostgres POSTGRES_BENCH_PASSWORD=dxpostgres POSTGRES_BENCH_DB=dxpostgres \
POSTGRES_BENCH_ROWS=100000 POSTGRES_BENCH_CONCURRENCY=8 \
swift run -c release PostgresBenchmark
```

## Modes

| Mode | What it measures |
|------|------------------|
| `select_one` | Sequential point queries over the extended protocol (binary results, prepared-statement reuse). |
| `select_one_text` | Sequential point queries over the simple protocol (text results). |
| `insert` | Sequential single-row inserts in autocommit. |
| `insert_transaction` | The same inserts wrapped in one transaction (one commit). |
| `copy` | Bulk load via `COPY … FROM STDIN`. |
| `stream` | Streamed scan of a large `generate_series`, rows per second. |
| `select_concurrent` | Point queries spread across the connection pool. |
| `latency_select` | Per-operation point-query latency percentiles. |

## Notes

Each line is emitted in the `[POSTGRES PERF SWIFT]` namespace for uniform parsing
with the other DXSQLite/DXRedis/DXClickHouse harnesses. Sequential point-query
throughput is round-trip bound; `select_concurrent` shows how the pool scales
across connections. Autocommit `insert` is dominated by per-row commit fsync;
`insert_transaction` commits once for a large gain, and `copy` is faster still.
On a local Docker PostgreSQL 17 the write paths measured roughly 280 inserts/s
(autocommit), 8,400/s (single transaction), and 293,000/s (`COPY`) — so `COPY` is
the path for bulk-loading a dataset.
