// C++ comparison harness for DXClickHouse benchmark parity.
//
// Mirrors the modes in Benchmarks/Sources/ClickHouse/main.swift so that
// throughput numbers can be compared apples-to-apples between the Swift
// client and the reference C++ client (ClickHouse/clickhouse-cpp).
//
// Output lines are in the [CH PERF CPP] namespace, matching the
// [CH PERF SWIFT] format produced by the Swift bench so a CI parser
// can ingest both uniformly.

#include <clickhouse/client.h>
#include <clickhouse/columns/array.h>
#include <clickhouse/columns/date.h>
#include <clickhouse/columns/lowcardinality.h>
#include <clickhouse/columns/map.h>
#include <clickhouse/columns/numeric.h>
#include <clickhouse/columns/string.h>
#include <clickhouse/columns/tuple.h>
#include <clickhouse/columns/uuid.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace clickhouse;

std::string env_string(const char* key, const std::string& fallback) {
    const char* raw = std::getenv(key);
    if (raw == nullptr || std::strlen(raw) == 0) {
        return fallback;
    }
    return std::string(raw);
}

int env_int(const char* key, int fallback) {
    const char* raw = std::getenv(key);
    if (raw == nullptr || std::strlen(raw) == 0) {
        return fallback;
    }
    try {
        return std::stoi(raw);
    } catch (...) {
        return fallback;
    }
}

struct Config {
    std::string host;
    int port;
    std::string user;
    std::string password;
    std::string database;
    int row_count;
    int block_row_count;
    int concurrency;
    int latency_iterations;
    int latency_small_batch_rows;
    std::vector<std::string> modes;
    std::string run_suffix;
    int real_events_rows;
    int real_logs_rows;
    int real_fixture_block;
    std::string real_database;
    std::string sample_events_table;
    std::string sample_logs_table;
    int real_filter_iterations;
    int real_decode_iterations;
    int ledger_rows;
    int ledger_unique_ids;
    int ledger_kinds;
    int ledger_point_iterations;
    int ledger_has_iterations;
    int ledger_kind_iterations;
    int ledger_bulk_rows;
    int ledger_stream_iterations;
    int ledger_stream_rows;
    std::string ledger_database;
    std::string ledger_table;
    std::string ledger_writes_table;
};

std::vector<std::string> split_csv(const std::string& raw) {
    std::vector<std::string> out;
    std::stringstream stream(raw);
    std::string token;
    while (std::getline(stream, token, ',')) {
        size_t start = token.find_first_not_of(" \t");
        size_t end = token.find_last_not_of(" \t");
        if (start == std::string::npos) continue;
        out.emplace_back(token.substr(start, end - start + 1));
    }
    return out;
}

std::string make_run_suffix() {
    std::random_device device;
    std::mt19937_64 rng(device());
    std::uniform_int_distribution<uint64_t> dist;
    uint64_t value = dist(rng);
    char buffer[17];
    std::snprintf(buffer, sizeof(buffer), "%016lx", static_cast<unsigned long>(value));
    return std::string(buffer, 8);
}

Config load_config() {
    Config cfg;
    cfg.host = env_string("CH_BENCH_HOST", "localhost");
    cfg.port = env_int("CH_BENCH_PORT", 9000);
    cfg.user = env_string("CH_BENCH_USER", "default");
    cfg.password = env_string("CH_BENCH_PASSWORD", "");
    cfg.database = env_string("CH_BENCH_DATABASE", "test");
    cfg.row_count = env_int("CH_BENCH_ROWS", 1000000);
    cfg.block_row_count = env_int("CH_BENCH_BLOCK", 100000);
    cfg.concurrency = std::max(1, env_int("CH_BENCH_CONCURRENCY", 8));
    cfg.latency_iterations = env_int("CH_BENCH_LATENCY_ITERATIONS", 10000);
    cfg.latency_small_batch_rows = env_int("CH_BENCH_LATENCY_SMALL_BATCH", 100);
    cfg.modes = split_csv(env_string(
        "CH_BENCH_MODES",
        "insert_bulk_columnar,select_bulk_columnar,insert_lc_map,select_lc_map"
    ));
    cfg.run_suffix = make_run_suffix();
    cfg.real_events_rows = env_int("CH_BENCH_EVENTS_ROWS", 10000000);
    cfg.real_logs_rows = env_int("CH_BENCH_LOGS_ROWS", 1000000);
    cfg.real_fixture_block = env_int("CH_BENCH_FIXTURE_BLOCK", 200000);
    cfg.real_database = env_string("CH_BENCH_SAMPLE_DATABASE", "bench_sample");
    cfg.sample_events_table = cfg.real_database + ".events_" + std::to_string(cfg.real_events_rows / 1000000) + "M";
    cfg.sample_logs_table = cfg.real_database + ".logs_" + std::to_string(cfg.real_logs_rows / 1000000) + "M";
    cfg.real_filter_iterations = std::max(1, env_int("CH_BENCH_SAMPLE_FILTER_ITERATIONS", 1));
    cfg.real_decode_iterations = std::max(1, env_int("CH_BENCH_SAMPLE_DECODE_ITERATIONS", 5));
    cfg.ledger_rows = env_int("CH_BENCH_LEDGER_ROWS", 10000000);
    cfg.ledger_unique_ids = std::max(1, env_int("CH_BENCH_LEDGER_UNIQUE_IDS", 100000));
    cfg.ledger_kinds = std::max(1, env_int("CH_BENCH_LEDGER_KINDS", 2000));
    cfg.ledger_point_iterations = std::max(1, env_int("CH_BENCH_LEDGER_POINT_ITERATIONS", 1000));
    cfg.ledger_has_iterations = std::max(1, env_int("CH_BENCH_LEDGER_HAS_ITERATIONS", 1000));
    cfg.ledger_kind_iterations = std::max(1, env_int("CH_BENCH_LEDGER_KIND_ITERATIONS", 100));
    cfg.ledger_bulk_rows = std::max(1, env_int("CH_BENCH_LEDGER_BULK_ROWS", 100000));
    cfg.ledger_stream_iterations = std::max(1, env_int("CH_BENCH_LEDGER_STREAM_ITERATIONS", 1000));
    cfg.ledger_stream_rows = std::max(1, env_int("CH_BENCH_LEDGER_STREAM_ROWS", 10));
    cfg.ledger_database = env_string("CH_BENCH_LEDGER_DATABASE", "bench_ledgers");
    cfg.ledger_table = cfg.ledger_database + ".ledger_" + std::to_string(cfg.ledger_rows / 1000000) + "M";
    cfg.ledger_writes_table = cfg.ledger_database + ".ledger_writes";
    return cfg;
}

ClientOptions client_options(const Config& cfg) {
    return ClientOptions()
        .SetHost(cfg.host)
        .SetPort(cfg.port)
        .SetUser(cfg.user)
        .SetPassword(cfg.password)
        .SetDefaultDatabase(cfg.database)
        .SetPingBeforeQuery(false);
}

std::unique_ptr<Client> connect(const Config& cfg) {
    return std::make_unique<Client>(client_options(cfg));
}

std::string table_name(const Config& cfg, const std::string& kind) {
    return cfg.database + ".bench_cpp_" + kind + "_" + cfg.run_suffix;
}

double elapsed_seconds(std::chrono::steady_clock::time_point start) {
    auto now = std::chrono::steady_clock::now();
    auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(now - start).count();
    return static_cast<double>(nanos) / 1e9;
}

int64_t elapsed_microseconds(std::chrono::steady_clock::time_point start) {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::microseconds>(now - start).count();
}

int rate(int count, double seconds) {
    if (seconds <= 0.0) return 0;
    return static_cast<int>(static_cast<double>(count) / seconds);
}

void summary(const std::string& mode, int rows, double seconds, const std::string& extra = "") {
    char elapsed_buf[32];
    std::snprintf(elapsed_buf, sizeof(elapsed_buf), "%.3f", seconds);
    std::cout << "[CH PERF CPP] " << mode
              << " rows=" << rows
              << " elapsed=" << elapsed_buf << "s"
              << " rate=" << rate(rows, seconds) << "/s";
    if (!extra.empty()) {
        std::cout << " " << extra;
    }
    std::cout << std::endl;
}

void execute(Client& client, const std::string& statement) {
    Query query(statement);
    client.Execute(query);
}

void drop_if_exists(Client& client, const std::string& table) {
    execute(client, "DROP TABLE IF EXISTS " + table);
}

Block build_bulk_block(int block_start, int block_end) {
    auto column_id = std::make_shared<ColumnUInt64>();
    auto column_tag = std::make_shared<ColumnString>();
    auto column_value = std::make_shared<ColumnFloat64>();
    auto column_ts = std::make_shared<ColumnDateTime>();
    for (int index = block_start; index < block_end; ++index) {
        column_id->Append(static_cast<uint64_t>(index));
        column_tag->Append("tag-" + std::to_string(index % 100));
        column_value->Append(static_cast<double>(index) * 0.5);
        column_ts->Append(1700000000);
    }
    Block block;
    block.AppendColumn("id", column_id);
    block.AppendColumn("tag", column_tag);
    block.AppendColumn("value", column_value);
    block.AppendColumn("ts", column_ts);
    return block;
}

void seed_bulk_table(Client& client, const Config& cfg, const std::string& table) {
    drop_if_exists(client, table);
    execute(client,
        "CREATE TABLE " + table +
        " (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id");
    int total_blocks = (cfg.row_count + cfg.block_row_count - 1) / cfg.block_row_count;
    for (int block_index = 0; block_index < total_blocks; ++block_index) {
        int block_start = block_index * cfg.block_row_count;
        int block_end = std::min(block_start + cfg.block_row_count, cfg.row_count);
        Block block = build_bulk_block(block_start, block_end);
        client.Insert(table, block);
    }
}

void run_insert_bulk_columnar(Client& client, const Config& cfg) {
    std::string table = table_name(cfg, "col");
    drop_if_exists(client, table);
    execute(client,
        "CREATE TABLE " + table +
        " (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id");
    int total_blocks = (cfg.row_count + cfg.block_row_count - 1) / cfg.block_row_count;
    auto start = std::chrono::steady_clock::now();
    for (int block_index = 0; block_index < total_blocks; ++block_index) {
        int block_start = block_index * cfg.block_row_count;
        int block_end = std::min(block_start + cfg.block_row_count, cfg.row_count);
        Block block = build_bulk_block(block_start, block_end);
        client.Insert(table, block);
    }
    double seconds = elapsed_seconds(start);
    drop_if_exists(client, table);
    summary("insert_bulk_columnar", cfg.row_count, seconds,
            "block_rows=" + std::to_string(cfg.block_row_count));
}

void run_select_bulk_columnar(Client& client, const Config& cfg) {
    std::string table = table_name(cfg, "sel_col");
    seed_bulk_table(client, cfg, table);
    int observed = 0;
    auto start = std::chrono::steady_clock::now();
    client.Select("SELECT id, tag, value, ts FROM " + table,
        [&observed](const Block& block) {
            observed += static_cast<int>(block.GetRowCount());
        }
    );
    double seconds = elapsed_seconds(start);
    drop_if_exists(client, table);
    summary("select_bulk_columnar", observed, seconds);
}

using AttributesMapColumn = ColumnMapT<ColumnLowCardinalityT<ColumnString>, ColumnString>;

Block build_lc_map_block(int block_start, int block_end) {
    auto column_id = std::make_shared<ColumnUInt64>();
    auto column_env = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_attributes = std::make_shared<AttributesMapColumn>(
        std::make_shared<ColumnLowCardinalityT<ColumnString>>(),
        std::make_shared<ColumnString>());

    static const char* environments[] = {"production", "staging", "development"};
    for (int index = block_start; index < block_end; ++index) {
        column_id->Append(static_cast<uint64_t>(index));
        column_env->Append(std::string(environments[index % 3]));
        std::map<std::string, std::string> value;
        value["service"] = std::string("svc-") + std::to_string(index % 16);
        value["region"] = "ap-southeast-2";
        column_attributes->Append(value);
    }
    Block block;
    block.AppendColumn("id", column_id);
    block.AppendColumn("env", column_env);
    block.AppendColumn("attributes", column_attributes);
    return block;
}

void create_lc_map_table(Client& client, const std::string& table) {
    drop_if_exists(client, table);
    execute(client,
        "CREATE TABLE " + table + " ("
        " id UInt64,"
        " env LowCardinality(String),"
        " attributes Map(LowCardinality(String), String)"
        ") ENGINE = MergeTree ORDER BY id");
}

void run_insert_lc_map(Client& client, const Config& cfg) {
    std::string table = table_name(cfg, "lc");
    create_lc_map_table(client, table);
    int total_blocks = (cfg.row_count + cfg.block_row_count - 1) / cfg.block_row_count;
    auto start = std::chrono::steady_clock::now();
    for (int block_index = 0; block_index < total_blocks; ++block_index) {
        int block_start = block_index * cfg.block_row_count;
        int block_end = std::min(block_start + cfg.block_row_count, cfg.row_count);
        Block block = build_lc_map_block(block_start, block_end);
        client.Insert(table, block);
    }
    double seconds = elapsed_seconds(start);
    drop_if_exists(client, table);
    summary("insert_lc_map", cfg.row_count, seconds,
            "block_rows=" + std::to_string(cfg.block_row_count));
}

void seed_lc_map_table(Client& client, const Config& cfg, const std::string& table) {
    create_lc_map_table(client, table);
    int total_blocks = (cfg.row_count + cfg.block_row_count - 1) / cfg.block_row_count;
    for (int block_index = 0; block_index < total_blocks; ++block_index) {
        int block_start = block_index * cfg.block_row_count;
        int block_end = std::min(block_start + cfg.block_row_count, cfg.row_count);
        Block block = build_lc_map_block(block_start, block_end);
        client.Insert(table, block);
    }
}

void run_select_lc_map(Client& client, const Config& cfg) {
    std::string table = table_name(cfg, "sel_lc");
    seed_lc_map_table(client, cfg, table);
    int observed = 0;
    auto start = std::chrono::steady_clock::now();
    client.Select("SELECT id, env, attributes FROM " + table + " ORDER BY id",
        [&observed](const Block& block) {
            observed += static_cast<int>(block.GetRowCount());
        }
    );
    double seconds = elapsed_seconds(start);
    drop_if_exists(client, table);
    summary("select_lc_map", observed, seconds);
}

int64_t percentile(const std::vector<int64_t>& sorted, double fraction) {
    if (sorted.empty()) return 0;
    int last_index = static_cast<int>(sorted.size()) - 1;
    int position = static_cast<int>(std::lround(static_cast<double>(last_index) * fraction));
    if (position < 0) position = 0;
    if (position > last_index) position = last_index;
    return sorted[position];
}

void latency_summary(const std::string& mode, std::vector<int64_t> samples) {
    std::sort(samples.begin(), samples.end());
    int64_t p50 = percentile(samples, 0.50);
    int64_t p95 = percentile(samples, 0.95);
    int64_t p99 = percentile(samples, 0.99);
    int64_t max_value = samples.empty() ? 0 : samples.back();
    int64_t total = 0;
    for (int64_t s : samples) total += s;
    int64_t mean = samples.empty() ? 0 : total / static_cast<int64_t>(samples.size());
    std::cout << "[CH PERF CPP] " << mode
              << " iterations=" << samples.size()
              << " p50=" << p50 << "us"
              << " p95=" << p95 << "us"
              << " p99=" << p99 << "us"
              << " max=" << max_value << "us"
              << " mean=" << mean << "us"
              << std::endl;
}

void run_latency_single_insert(Client& client, const Config& cfg) {
    std::string table = table_name(cfg, "lat_ins");
    drop_if_exists(client, table);
    execute(client,
        "CREATE TABLE " + table + " (id UInt64, value Float64) ENGINE = MergeTree ORDER BY id");
    std::vector<int64_t> samples;
    samples.reserve(cfg.latency_iterations);
    for (int iteration = 0; iteration < cfg.latency_iterations; ++iteration) {
        auto column_id = std::make_shared<ColumnUInt64>();
        auto column_value = std::make_shared<ColumnFloat64>();
        column_id->Append(static_cast<uint64_t>(iteration));
        column_value->Append(static_cast<double>(iteration) * 0.5);
        Block block;
        block.AppendColumn("id", column_id);
        block.AppendColumn("value", column_value);
        auto start = std::chrono::steady_clock::now();
        client.Insert(table, block);
        samples.push_back(elapsed_microseconds(start));
    }
    drop_if_exists(client, table);
    latency_summary("latency_single_insert", std::move(samples));
}

void run_latency_single_select(Client& client, const Config& cfg) {
    std::vector<int64_t> samples;
    samples.reserve(cfg.latency_iterations);
    for (int iteration = 0; iteration < cfg.latency_iterations; ++iteration) {
        auto start = std::chrono::steady_clock::now();
        client.Select("SELECT toInt64(1)",
            [](const Block& block) { (void)block.GetRowCount(); }
        );
        samples.push_back(elapsed_microseconds(start));
    }
    latency_summary("latency_single_select", std::move(samples));
}

struct ConcurrentTaskResult {
    int rows;
    double elapsed;
};

int median_rate(const std::vector<ConcurrentTaskResult>& results) {
    if (results.empty()) return 0;
    std::vector<int> per_task;
    per_task.reserve(results.size());
    for (const auto& result : results) {
        per_task.push_back(rate(result.rows, result.elapsed));
    }
    std::sort(per_task.begin(), per_task.end());
    size_t middle = per_task.size() / 2;
    if (per_task.size() % 2 == 0) {
        return (per_task[middle - 1] + per_task[middle]) / 2;
    }
    return per_task[middle];
}

void concurrent_summary(const std::string& mode, const std::vector<ConcurrentTaskResult>& results, double wall_seconds) {
    int total_rows = 0;
    for (const auto& result : results) total_rows += result.rows;
    int aggregate = rate(total_rows, wall_seconds);
    int per_task_median = median_rate(results);
    char wall_buf[32];
    std::snprintf(wall_buf, sizeof(wall_buf), "%.3f", wall_seconds);
    std::cout << "[CH PERF CPP] " << mode
              << " tasks=" << results.size()
              << " total_rows=" << total_rows
              << " elapsed=" << wall_buf << "s"
              << " aggregate=" << aggregate << "/s"
              << " per_task_median=" << per_task_median << "/s"
              << std::endl;
}

void run_concurrent_insert_throughput(Client& client, const Config& cfg) {
    std::string table = table_name(cfg, "cc_ins");
    drop_if_exists(client, table);
    execute(client,
        "CREATE TABLE " + table +
        " (id UInt64, tag String, value Float64, ts DateTime) ENGINE = MergeTree ORDER BY id");

    int rows_per_task = cfg.row_count / cfg.concurrency;
    std::vector<std::thread> threads;
    std::vector<ConcurrentTaskResult> results(cfg.concurrency);
    auto wall_start = std::chrono::steady_clock::now();

    for (int task_index = 0; task_index < cfg.concurrency; ++task_index) {
        threads.emplace_back([task_index, rows_per_task, &cfg, &table, &results]() {
            auto thread_client = connect(cfg);
            int range_start = task_index * rows_per_task;
            int range_end = range_start + rows_per_task;
            int total_blocks = (rows_per_task + cfg.block_row_count - 1) / cfg.block_row_count;
            auto task_start = std::chrono::steady_clock::now();
            for (int block_index = 0; block_index < total_blocks; ++block_index) {
                int block_start = range_start + block_index * cfg.block_row_count;
                int block_end = std::min(block_start + cfg.block_row_count, range_end);
                Block block = build_bulk_block(block_start, block_end);
                thread_client->Insert(table, block);
            }
            results[task_index] = ConcurrentTaskResult{rows_per_task, elapsed_seconds(task_start)};
        });
    }
    for (auto& thread : threads) thread.join();
    double wall_seconds = elapsed_seconds(wall_start);
    drop_if_exists(client, table);
    concurrent_summary("concurrent_insert_throughput", results, wall_seconds);
}

void real_summary(const std::string& mode, int rows, double seconds,
                  int64_t first_byte_microseconds, int64_t total_decode_microseconds,
                  const std::string& extra = "") {
    char elapsed_buf[32];
    std::snprintf(elapsed_buf, sizeof(elapsed_buf), "%.3f", seconds);
    std::cout << "[CH PERF CPP] " << mode
              << " rows=" << rows
              << " elapsed=" << elapsed_buf << "s"
              << " rate=" << rate(rows, seconds) << "/s"
              << " first_byte_us=" << first_byte_microseconds
              << " total_decode_us=" << total_decode_microseconds;
    if (!extra.empty()) {
        std::cout << " " << extra;
    }
    std::cout << std::endl;
}

std::string real_payload(int index) {
    std::string head = "p" + std::to_string(index) + "-";
    const int target = 200;
    if (static_cast<int>(head.size()) >= target) {
        return head.substr(0, target);
    }
    std::string filler = (index % 7 == 0) ? "abc" : "xyz";
    std::string result = head;
    while (static_cast<int>(result.size()) + static_cast<int>(filler.size()) <= target) {
        result += filler;
    }
    if (static_cast<int>(result.size()) < target) {
        result.append(target - result.size(), 'z');
    }
    return result;
}

static const char* kRealEventTypes[] = {"click", "view", "purchase", "scroll", "hover", "submit"};

Block build_real_events_block(int block_start, int block_end) {
    auto column_id = std::make_shared<ColumnUInt64>();
    auto column_user_id = std::make_shared<ColumnUInt64>();
    auto column_event_type = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_value = std::make_shared<ColumnFloat64>();
    auto column_payload = std::make_shared<ColumnString>();
    auto column_ts = std::make_shared<ColumnDateTime64>(9);
    const int64_t base_nanos = 1700000000000000000LL;
    for (int index = block_start; index < block_end; ++index) {
        column_id->Append(static_cast<uint64_t>(index));
        column_user_id->Append(static_cast<uint64_t>(index % 1000000));
        column_event_type->Append(std::string(kRealEventTypes[index % 6]));
        column_value->Append(static_cast<double>(index % 10000) * 0.5);
        column_payload->Append(real_payload(index));
        column_ts->Append(base_nanos + static_cast<int64_t>(index) * 1000LL);
    }
    Block block;
    block.AppendColumn("id", column_id);
    block.AppendColumn("user_id", column_user_id);
    block.AppendColumn("event_type", column_event_type);
    block.AppendColumn("value", column_value);
    block.AppendColumn("payload", column_payload);
    block.AppendColumn("ts", column_ts);
    return block;
}

Block build_real_logs_block(int block_start, int block_end) {
    auto column_id = std::make_shared<ColumnUInt64>();
    auto column_attributes = std::make_shared<AttributesMapColumn>(
        std::make_shared<ColumnLowCardinalityT<ColumnString>>(),
        std::make_shared<ColumnString>());
    for (int index = block_start; index < block_end; ++index) {
        column_id->Append(static_cast<uint64_t>(index));
        std::map<std::string, std::string> value;
        value["service"] = std::string("svc-") + std::to_string(index % 64);
        value["region"] = "ap-southeast-2";
        value["level"] = (index % 4 == 0) ? std::string("warn") : std::string("info");
        column_attributes->Append(value);
    }
    Block block;
    block.AppendColumn("id", column_id);
    block.AppendColumn("attributes", column_attributes);
    return block;
}

void run_real_benchsetup(Client& client, const Config& cfg) {
    auto start = std::chrono::steady_clock::now();
    execute(client, "DROP DATABASE IF EXISTS " + cfg.real_database);
    execute(client, "CREATE DATABASE " + cfg.real_database);
    execute(client,
        "CREATE TABLE " + cfg.sample_events_table + " ("
        " id UInt64,"
        " user_id UInt64,"
        " event_type LowCardinality(String),"
        " value Float64,"
        " payload String,"
        " ts DateTime64(9)"
        ") ENGINE = MergeTree ORDER BY (user_id, ts)");
    execute(client,
        "CREATE TABLE " + cfg.sample_logs_table + " ("
        " id UInt64,"
        " attributes Map(LowCardinality(String), String)"
        ") ENGINE = MergeTree ORDER BY id");

    int events_blocks = (cfg.real_events_rows + cfg.real_fixture_block - 1) / cfg.real_fixture_block;
    for (int block_index = 0; block_index < events_blocks; ++block_index) {
        int block_start = block_index * cfg.real_fixture_block;
        int block_end = std::min(block_start + cfg.real_fixture_block, cfg.real_events_rows);
        Block block = build_real_events_block(block_start, block_end);
        client.Insert(cfg.sample_events_table, block);
    }
    int logs_blocks = (cfg.real_logs_rows + cfg.real_fixture_block - 1) / cfg.real_fixture_block;
    for (int block_index = 0; block_index < logs_blocks; ++block_index) {
        int block_start = block_index * cfg.real_fixture_block;
        int block_end = std::min(block_start + cfg.real_fixture_block, cfg.real_logs_rows);
        Block block = build_real_logs_block(block_start, block_end);
        client.Insert(cfg.sample_logs_table, block);
    }

    uint64_t events_count = 0;
    client.Select("SELECT count() FROM " + cfg.sample_events_table,
        [&events_count](const Block& block) {
            if (block.GetRowCount() == 0) return;
            auto column = block[0]->As<ColumnUInt64>();
            if (column != nullptr) events_count = column->At(0);
        }
    );
    uint64_t logs_count = 0;
    client.Select("SELECT count() FROM " + cfg.sample_logs_table,
        [&logs_count](const Block& block) {
            if (block.GetRowCount() == 0) return;
            auto column = block[0]->As<ColumnUInt64>();
            if (column != nullptr) logs_count = column->At(0);
        }
    );
    double seconds = elapsed_seconds(start);
    char elapsed_buf[32];
    std::snprintf(elapsed_buf, sizeof(elapsed_buf), "%.3f", seconds);
    std::cout << "[CH PERF CPP] benchsetup"
              << " events_table=" << cfg.sample_events_table
              << " events_rows=" << events_count
              << " logs_table=" << cfg.sample_logs_table
              << " logs_rows=" << logs_count
              << " elapsed=" << elapsed_buf << "s"
              << std::endl;
    if (static_cast<int>(events_count) != cfg.real_events_rows) {
        throw std::runtime_error("events row count mismatch");
    }
    if (static_cast<int>(logs_count) != cfg.real_logs_rows) {
        throw std::runtime_error("logs row count mismatch");
    }
}

struct RealRunResult {
    int rows;
    double seconds;
    int64_t first_byte_microseconds;
    int64_t decode_microseconds;
};

RealRunResult execute_real_select(Client& client, const std::string& sql, bool measure_decode) {
    int observed = 0;
    int64_t first_byte = 0;
    int64_t decode_microseconds = 0;
    auto start = std::chrono::steady_clock::now();
    client.Select(sql,
        [&](const Block& block) {
            if (first_byte == 0) {
                first_byte = elapsed_microseconds(start);
            }
            if (measure_decode) {
                auto decode_start = std::chrono::steady_clock::now();
                int row_count = static_cast<int>(block.GetRowCount());
                size_t cols = block.GetColumnCount();
                for (int row_index = 0; row_index < row_count; ++row_index) {
                    for (size_t col_index = 0; col_index < cols; ++col_index) {
                        auto column = block[col_index];
                        if (auto u = column->As<ColumnUInt64>()) {
                            volatile uint64_t v = u->At(row_index); (void)v;
                        } else if (auto d = column->As<ColumnFloat64>()) {
                            volatile double v = d->At(row_index); (void)v;
                        } else if (auto s = column->As<ColumnString>()) {
                            volatile size_t v = s->At(row_index).size(); (void)v;
                        }
                    }
                }
                observed += row_count;
                decode_microseconds += elapsed_microseconds(decode_start);
            } else {
                observed += static_cast<int>(block.GetRowCount());
            }
        }
    );
    return RealRunResult{observed, elapsed_seconds(start), first_byte, decode_microseconds};
}

void run_real_select_orderby_limit(Client& client, const Config& cfg) {
    std::string sql = "SELECT id, user_id, event_type, value, payload, ts FROM " + cfg.sample_events_table
                    + " WHERE event_type = 'click' ORDER BY ts DESC LIMIT 100000";
    auto result = execute_real_select(client, sql, true);
    real_summary("select_orderby_limit", result.rows, result.seconds,
                 result.first_byte_microseconds, result.decode_microseconds);
}

void run_real_select_groupby(Client& client, const Config& cfg) {
    std::string sql = "SELECT user_id, count(*) AS c FROM " + cfg.sample_events_table
                    + " GROUP BY user_id ORDER BY c DESC LIMIT 10000";
    auto result = execute_real_select(client, sql, true);
    real_summary("select_groupby", result.rows, result.seconds,
                 result.first_byte_microseconds, result.decode_microseconds);
}

void run_real_select_where_in(Client& client, const Config& cfg) {
    std::string sql = "SELECT id, user_id, ts, value FROM " + cfg.sample_events_table
                    + " WHERE user_id IN (SELECT number FROM numbers(1, 100000))";
    auto result = execute_real_select(client, sql, true);
    real_summary("select_where_in", result.rows, result.seconds,
                 result.first_byte_microseconds, result.decode_microseconds);
}

void run_real_select_full_scan_proj(Client& client, const Config& cfg) {
    std::string sql = "SELECT id, ts, value FROM " + cfg.sample_events_table;
    auto result = execute_real_select(client, sql, true);
    real_summary("select_full_scan_proj", result.rows, result.seconds,
                 result.first_byte_microseconds, result.decode_microseconds);
}

void run_real_select_lc_aggregation(Client& client, const Config& cfg) {
    std::string sql = "SELECT event_type, avg(value) AS avg_value FROM " + cfg.sample_events_table
                    + " GROUP BY event_type";
    auto result = execute_real_select(client, sql, true);
    real_summary("select_lc_aggregation", result.rows, result.seconds,
                 result.first_byte_microseconds, result.decode_microseconds);
}

void run_real_select_string_filter(Client& client, const Config& cfg) {
    std::string sql = "SELECT count(*) AS matched FROM " + cfg.sample_events_table
                    + " WHERE payload LIKE '%abc%'";
    uint64_t matched = 0;
    int64_t first_byte = 0;
    int64_t decode_microseconds = 0;
    auto start = std::chrono::steady_clock::now();
    client.Select(sql,
        [&](const Block& block) {
            if (first_byte == 0) {
                first_byte = elapsed_microseconds(start);
            }
            auto decode_start = std::chrono::steady_clock::now();
            if (block.GetRowCount() > 0) {
                auto column = block[0]->As<ColumnUInt64>();
                if (column != nullptr) matched = column->At(0);
            }
            decode_microseconds += elapsed_microseconds(decode_start);
        }
    );
    double seconds = elapsed_seconds(start);
    real_summary("select_string_filter", 1, seconds, first_byte, decode_microseconds,
                 "matched=" + std::to_string(matched));
}

void run_real_select_decode_only(Client& client, const Config& cfg) {
    std::string sql = "SELECT id, ts, value FROM " + cfg.sample_events_table;
    // Warm the page cache.
    client.Select(sql, [](const Block& block) { (void)block.GetRowCount(); });

    std::vector<int64_t> samples;
    samples.reserve(cfg.real_decode_iterations);
    int last_rows = 0;
    int64_t last_first_byte = 0;
    int64_t last_decode = 0;
    for (int iteration = 0; iteration < cfg.real_decode_iterations; ++iteration) {
        auto result = execute_real_select(client, sql, true);
        samples.push_back(static_cast<int64_t>(result.seconds * 1e6));
        last_rows = result.rows;
        last_first_byte = result.first_byte_microseconds;
        last_decode = result.decode_microseconds;
    }
    std::sort(samples.begin(), samples.end());
    int64_t median = samples[samples.size() / 2];
    double median_seconds = static_cast<double>(median) / 1e6;
    real_summary("select_decode_only", last_rows, median_seconds, last_first_byte, last_decode,
                 "iterations=" + std::to_string(cfg.real_decode_iterations));
}

void run_real_select_wire_only_count(Client& client, const Config& cfg) {
    std::string sql = "SELECT id, user_id, event_type, value, payload, ts FROM " + cfg.sample_events_table;
    auto result = execute_real_select(client, sql, false);
    real_summary("select_wire_only_count", result.rows, result.seconds,
                 result.first_byte_microseconds, 0);
}

std::string ledger_entity_id(int index) {
    std::string raw = std::to_string(index);
    if (static_cast<int>(raw.size()) >= 44) return raw.substr(0, 44);
    return std::string(44 - raw.size(), '0') + raw;
}

std::string ledger_entity_kind(int index) {
    std::string raw = std::to_string(index);
    if (static_cast<int>(raw.size()) >= 4) return raw.substr(0, 4);
    return std::string(4 - raw.size(), '0') + raw;
}

void ledger_latency_summary(const std::string& mode, std::vector<int64_t> samples, const std::string& extra = "") {
    std::sort(samples.begin(), samples.end());
    int64_t p50 = percentile(samples, 0.50);
    int64_t p95 = percentile(samples, 0.95);
    int64_t p99 = percentile(samples, 0.99);
    int64_t max_value = samples.empty() ? 0 : samples.back();
    int64_t total = 0;
    for (int64_t s : samples) total += s;
    int64_t mean = samples.empty() ? 0 : total / static_cast<int64_t>(samples.size());
    std::cout << "[CH PERF CPP] " << mode
              << " iterations=" << samples.size()
              << " p50_us=" << p50
              << " p95_us=" << p95
              << " p99_us=" << p99
              << " max_us=" << max_value
              << " mean_us=" << mean;
    if (!extra.empty()) {
        std::cout << " " << extra;
    }
    std::cout << std::endl;
}

void run_ledger_benchsetup(Client& client, const Config& cfg) {
    auto start = std::chrono::steady_clock::now();
    execute(client, "DROP DATABASE IF EXISTS " + cfg.ledger_database);
    execute(client, "CREATE DATABASE " + cfg.ledger_database);
    execute(client,
        "CREATE TABLE " + cfg.ledger_table + " ("
        "record_id UUID,"
        "entity_id FixedString(44),"
        "entity_refs Array(FixedString(44)),"
        "entity_ref_kinds Array(FixedString(4)),"
        "entity_kind LowCardinality(FixedString(4)),"
        "aggregate_domain LowCardinality(FixedString(3)),"
        "aggregate_subdomain LowCardinality(FixedString(1)),"
        "record_type LowCardinality(String),"
        "payload JSON,"
        "encryption LowCardinality(String),"
        "region LowCardinality(String),"
        "participant_ids Array(FixedString(44)),"
        "system_actor_ids Array(LowCardinality(String)),"
        "created_at DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),"
        "valid_until DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),"
        "published_at DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),"
        "received_at DateTime64(9, 'Pacific/Auckland') CODEC(Delta(8), ZSTD(1)),"
        "is_deleted UInt8 DEFAULT 0"
        ") ENGINE = MergeTree "
        "ORDER BY (entity_kind, entity_id, created_at, record_id) "
        "PARTITION BY (region, toYYYYMM(created_at))");
    execute(client,
        "CREATE TABLE " + cfg.ledger_writes_table + " ("
        "record_id UUID,"
        "entity_id String,"
        "entity_refs Array(String),"
        "entity_ref_kinds Array(String),"
        "entity_kind LowCardinality(String),"
        "aggregate_domain LowCardinality(String),"
        "aggregate_subdomain LowCardinality(String),"
        "record_type LowCardinality(String),"
        "payload String,"
        "encryption LowCardinality(String),"
        "region LowCardinality(String),"
        "participant_ids Array(String),"
        "system_actor_ids Array(String),"
        "created_at DateTime64(9),"
        "valid_until DateTime64(9),"
        "published_at DateTime64(9),"
        "received_at DateTime64(9),"
        "is_deleted UInt8 DEFAULT 0"
        ") ENGINE = MergeTree "
        "ORDER BY (entity_kind, entity_id, created_at, record_id) "
        "PARTITION BY (region, toYYYYMM(created_at))");
    std::string populate =
        "INSERT INTO " + cfg.ledger_table + " "
        "SELECT "
        "generateUUIDv4() AS record_id,"
        "toFixedString(leftPad(toString(number % " + std::to_string(cfg.ledger_unique_ids) + "), 44, '0'), 44) AS entity_id,"
        "arrayMap(x -> toFixedString(leftPad(toString(x), 44, '0'), 44), range(toUInt32((number * 7) % 9))) AS entity_refs,"
        "arrayMap(x -> toFixedString(leftPad(toString(x % 16), 4, '0'), 4), range(toUInt32((number * 7) % 9))) AS entity_ref_kinds,"
        "toFixedString(leftPad(toString(number % " + std::to_string(cfg.ledger_kinds) + "), 4, '0'), 4) AS entity_kind,"
        "toFixedString(['agg', 'doc', 'usr', 'evt'][1 + number % 4], 3) AS aggregate_domain,"
        "toFixedString(['a','b','c','d','e','f','g','h'][1 + number % 8], 1) AS aggregate_subdomain,"
        "['Created','Updated','Deleted','Archived'][1 + number % 4] AS record_type,"
        "toJSONString(map('x', toInt64(number), 'y', concat('v', toString(number % 13)), 'z', toFloat64(number) * 0.5, 'a', toString(arrayMap(i -> toInt64(i), range(2))), 'b', '{}')) AS payload,"
        "['none','aes256','gcm'][1 + number % 3] AS encryption,"
        "['nz','au','gb','zz'][1 + number % 4] AS region,"
        "arrayMap(x -> toFixedString(leftPad(toString(x + (number % 1000)), 44, '0'), 44), range(toUInt32((number * 3) % 5))) AS participant_ids,"
        "arrayMap(x -> concat('svc-', toString(x)), range(toUInt32((number * 2) % 3))) AS system_actor_ids,"
        "toDateTime64(1700000000.0 + number * 0.001, 9, 'Pacific/Auckland') AS created_at,"
        "toDateTime64(1700000000.0 + number * 0.001 + 3600, 9, 'Pacific/Auckland') AS valid_until,"
        "toDateTime64(1700000000.0 + number * 0.001 + 1, 9, 'Pacific/Auckland') AS published_at,"
        "toDateTime64(1700000000.0 + number * 0.001 + 2, 9, 'Pacific/Auckland') AS received_at,"
        "toUInt8(0) AS is_deleted "
        "FROM numbers(" + std::to_string(cfg.ledger_rows) + ")";
    execute(client, populate);
    uint64_t ledger_count = 0;
    client.Select("SELECT count() FROM " + cfg.ledger_table,
        [&ledger_count](const Block& block) {
            if (block.GetRowCount() == 0) return;
            auto column = block[0]->As<ColumnUInt64>();
            if (column != nullptr) ledger_count = column->At(0);
        }
    );
    double seconds = elapsed_seconds(start);
    char elapsed_buf[32];
    std::snprintf(elapsed_buf, sizeof(elapsed_buf), "%.3f", seconds);
    std::cout << "[CH PERF CPP] ledger_benchsetup"
              << " ledger_table=" << cfg.ledger_table
              << " ledger_rows=" << ledger_count
              << " writes_table=" << cfg.ledger_writes_table
              << " elapsed=" << elapsed_buf << "s"
              << std::endl;
    if (static_cast<int>(ledger_count) != cfg.ledger_rows) {
        throw std::runtime_error("ledger ledger row count mismatch");
    }
}

int64_t ledger_scalar_count(Client& client, const std::string& sql) {
    int64_t result = 0;
    client.Select(sql,
        [&result](const Block& block) {
            if (block.GetRowCount() == 0) return;
            auto column = block[0]->As<ColumnUInt64>();
            if (column != nullptr) result = static_cast<int64_t>(column->At(0));
        }
    );
    return result;
}

void run_ledger_point_lookup_by_id(Client& client, const Config& cfg) {
    std::vector<int64_t> samples;
    samples.reserve(cfg.ledger_point_iterations);
    int64_t matched_total = 0;
    for (int iteration = 0; iteration < cfg.ledger_point_iterations; ++iteration) {
        std::string id = ledger_entity_id(iteration % cfg.ledger_unique_ids);
        std::string sql = "SELECT count() FROM " + cfg.ledger_table
                        + " WHERE entity_id = '" + id + "'";
        auto start = std::chrono::steady_clock::now();
        int64_t count = ledger_scalar_count(client, sql);
        samples.push_back(elapsed_microseconds(start));
        matched_total += count;
    }
    ledger_latency_summary("ledger_point_lookup_by_id", std::move(samples),
                               "matched_total=" + std::to_string(matched_total));
}

void run_ledger_has_refs(Client& client, const Config& cfg) {
    std::vector<int64_t> samples;
    samples.reserve(cfg.ledger_has_iterations);
    int64_t matched_total = 0;
    for (int iteration = 0; iteration < cfg.ledger_has_iterations; ++iteration) {
        std::string ref = ledger_entity_id(iteration % 8);
        std::string sql = "SELECT count() FROM " + cfg.ledger_table
                        + " WHERE has(entity_refs, '" + ref + "')";
        auto start = std::chrono::steady_clock::now();
        int64_t count = ledger_scalar_count(client, sql);
        samples.push_back(elapsed_microseconds(start));
        matched_total += count;
    }
    ledger_latency_summary("ledger_has_refs", std::move(samples),
                               "matched_total=" + std::to_string(matched_total));
}

void run_ledger_has_ref_kinds(Client& client, const Config& cfg) {
    std::vector<int64_t> samples;
    samples.reserve(cfg.ledger_has_iterations);
    int64_t matched_total = 0;
    for (int iteration = 0; iteration < cfg.ledger_has_iterations; ++iteration) {
        std::string kind = ledger_entity_kind(iteration % 16);
        std::string sql = "SELECT count() FROM " + cfg.ledger_table
                        + " WHERE has(entity_ref_kinds, '" + kind + "')";
        auto start = std::chrono::steady_clock::now();
        int64_t count = ledger_scalar_count(client, sql);
        samples.push_back(elapsed_microseconds(start));
        matched_total += count;
    }
    ledger_latency_summary("ledger_has_ref_kinds", std::move(samples),
                               "matched_total=" + std::to_string(matched_total));
}

void run_ledger_has_participants(Client& client, const Config& cfg) {
    std::vector<int64_t> samples;
    samples.reserve(cfg.ledger_has_iterations);
    int64_t matched_total = 0;
    for (int iteration = 0; iteration < cfg.ledger_has_iterations; ++iteration) {
        std::string actor = ledger_entity_id(iteration % 1000);
        std::string sql = "SELECT count() FROM " + cfg.ledger_table
                        + " WHERE has(participant_ids, '" + actor + "')";
        auto start = std::chrono::steady_clock::now();
        int64_t count = ledger_scalar_count(client, sql);
        samples.push_back(elapsed_microseconds(start));
        matched_total += count;
    }
    ledger_latency_summary("ledger_has_participants", std::move(samples),
                               "matched_total=" + std::to_string(matched_total));
}

void run_ledger_kind_slice(Client& client, const Config& cfg) {
    std::vector<int64_t> samples;
    samples.reserve(cfg.ledger_kind_iterations);
    int rows_total = 0;
    for (int iteration = 0; iteration < cfg.ledger_kind_iterations; ++iteration) {
        std::string kind = ledger_entity_kind(iteration % cfg.ledger_kinds);
        std::string sql = "SELECT entity_id, created_at FROM " + cfg.ledger_table
                        + " WHERE entity_kind = '" + kind + "' "
                          "ORDER BY created_at DESC LIMIT 1000";
        auto start = std::chrono::steady_clock::now();
        int observed_rows = 0;
        client.Select(sql,
            [&observed_rows](const Block& block) {
                observed_rows += static_cast<int>(block.GetRowCount());
            }
        );
        samples.push_back(elapsed_microseconds(start));
        rows_total += observed_rows;
    }
    ledger_latency_summary("ledger_kind_slice", std::move(samples),
                               "rows_total=" + std::to_string(rows_total));
}

Block ledger_build_writes_block(const Config& cfg, int block_start, int block_end) {
    auto column_record_id = std::make_shared<ColumnUUID>();
    auto column_entity_id = std::make_shared<ColumnString>();
    auto column_entity_refs = std::make_shared<ColumnArray>(std::make_shared<ColumnString>());
    auto column_entity_ref_kinds = std::make_shared<ColumnArray>(std::make_shared<ColumnString>());
    auto column_entity_kind = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_aggregate_domain = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_aggregate_subdomain = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_record_type = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_payload = std::make_shared<ColumnString>();
    auto column_encryption = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_region = std::make_shared<ColumnLowCardinalityT<ColumnString>>();
    auto column_participant_ids = std::make_shared<ColumnArray>(std::make_shared<ColumnString>());
    auto column_system_actor_ids = std::make_shared<ColumnArray>(std::make_shared<ColumnString>());
    auto column_created_at = std::make_shared<ColumnDateTime64>(9);
    auto column_valid_until = std::make_shared<ColumnDateTime64>(9);
    auto column_published_at = std::make_shared<ColumnDateTime64>(9);
    auto column_received_at = std::make_shared<ColumnDateTime64>(9);
    auto column_is_deleted = std::make_shared<ColumnUInt8>();

    static const char* domains[] = {"agg", "doc", "usr", "evt"};
    static const char* subdomains[] = {"a","b","c","d","e","f","g","h"};
    static const char* record_types[] = {"Created","Updated","Deleted","Archived"};
    static const char* encryptions[] = {"none","aes256","gcm"};
    static const char* regions[] = {"nz","au","gb","zz"};

    const int64_t base_nanos = 1700000000000000000LL;
    for (int index = block_start; index < block_end; ++index) {
        column_record_id->Append(UInt128(static_cast<uint64_t>(index), static_cast<uint64_t>(index) ^ 0x9E3779B97F4A7C15ULL));
        column_entity_id->Append(ledger_entity_id(index % cfg.ledger_unique_ids));
        int refs_length = static_cast<int>((static_cast<uint64_t>(index) * 7ULL) % 9ULL);
        std::vector<std::string> refs(refs_length);
        std::vector<std::string> refs_kinds(refs_length);
        for (int ref_index = 0; ref_index < refs_length; ++ref_index) {
            refs[ref_index] = ledger_entity_id(ref_index);
            refs_kinds[ref_index] = ledger_entity_kind(ref_index % 16);
        }
        column_entity_refs->AppendAsColumn(std::make_shared<ColumnString>(refs));
        column_entity_ref_kinds->AppendAsColumn(std::make_shared<ColumnString>(refs_kinds));
        column_entity_kind->Append(ledger_entity_kind(index % cfg.ledger_kinds));
        column_aggregate_domain->Append(std::string(domains[index % 4]));
        column_aggregate_subdomain->Append(std::string(subdomains[index % 8]));
        column_record_type->Append(std::string(record_types[index % 4]));
        std::string payload = "{\"x\":" + std::to_string(index)
                            + ",\"y\":\"v" + std::to_string(index % 13)
                            + "\",\"z\":" + std::to_string(static_cast<double>(index) * 0.5)
                            + ",\"a\":[0,1],\"b\":{}}";
        column_payload->Append(payload);
        column_encryption->Append(std::string(encryptions[index % 3]));
        column_region->Append(std::string(regions[index % 4]));
        int user_actors_length = static_cast<int>((static_cast<uint64_t>(index) * 3ULL) % 5ULL);
        std::vector<std::string> actors(user_actors_length);
        for (int actor_index = 0; actor_index < user_actors_length; ++actor_index) {
            actors[actor_index] = ledger_entity_id(actor_index + (index % 1000));
        }
        column_participant_ids->AppendAsColumn(std::make_shared<ColumnString>(actors));
        int system_actors_length = static_cast<int>((static_cast<uint64_t>(index) * 2ULL) % 3ULL);
        std::vector<std::string> system_actors(system_actors_length);
        for (int system_index = 0; system_index < system_actors_length; ++system_index) {
            system_actors[system_index] = std::string("svc-") + std::to_string(system_index);
        }
        column_system_actor_ids->AppendAsColumn(std::make_shared<ColumnString>(system_actors));
        int64_t occurred = base_nanos + static_cast<int64_t>(index) * 1000000LL;
        column_created_at->Append(occurred);
        column_valid_until->Append(occurred + 3600000000000LL);
        column_published_at->Append(occurred + 1000000000LL);
        column_received_at->Append(occurred + 2000000000LL);
        column_is_deleted->Append(static_cast<uint8_t>(0));
    }

    Block block;
    block.AppendColumn("record_id", column_record_id);
    block.AppendColumn("entity_id", column_entity_id);
    block.AppendColumn("entity_refs", column_entity_refs);
    block.AppendColumn("entity_ref_kinds", column_entity_ref_kinds);
    block.AppendColumn("entity_kind", column_entity_kind);
    block.AppendColumn("aggregate_domain", column_aggregate_domain);
    block.AppendColumn("aggregate_subdomain", column_aggregate_subdomain);
    block.AppendColumn("record_type", column_record_type);
    block.AppendColumn("payload", column_payload);
    block.AppendColumn("encryption", column_encryption);
    block.AppendColumn("region", column_region);
    block.AppendColumn("participant_ids", column_participant_ids);
    block.AppendColumn("system_actor_ids", column_system_actor_ids);
    block.AppendColumn("created_at", column_created_at);
    block.AppendColumn("valid_until", column_valid_until);
    block.AppendColumn("published_at", column_published_at);
    block.AppendColumn("received_at", column_received_at);
    block.AppendColumn("is_deleted", column_is_deleted);
    return block;
}

void run_ledger_bulk_insert(Client& client, const Config& cfg) {
    execute(client, "TRUNCATE TABLE " + cfg.ledger_writes_table);
    auto start = std::chrono::steady_clock::now();
    Block block = ledger_build_writes_block(cfg, 0, cfg.ledger_bulk_rows);
    client.Insert(cfg.ledger_writes_table, block);
    double seconds = elapsed_seconds(start);
    int64_t per_row_us = cfg.ledger_bulk_rows > 0
        ? static_cast<int64_t>(seconds * 1000000.0 / cfg.ledger_bulk_rows)
        : 0;
    char elapsed_buf[32];
    std::snprintf(elapsed_buf, sizeof(elapsed_buf), "%.3f", seconds);
    std::cout << "[CH PERF CPP] ledger_bulk_insert"
              << " rows=" << cfg.ledger_bulk_rows
              << " elapsed=" << elapsed_buf << "s"
              << " rate=" << rate(cfg.ledger_bulk_rows, seconds) << "/s"
              << " per_row_us=" << per_row_us
              << std::endl;
}

void run_ledger_stream_insert(Client& client, const Config& cfg) {
    execute(client, "TRUNCATE TABLE " + cfg.ledger_writes_table);
    std::vector<int64_t> samples;
    samples.reserve(cfg.ledger_stream_iterations);
    for (int iteration = 0; iteration < cfg.ledger_stream_iterations; ++iteration) {
        int block_start = iteration * cfg.ledger_stream_rows;
        int block_end = block_start + cfg.ledger_stream_rows;
        Block block = ledger_build_writes_block(cfg, block_start, block_end);
        auto start = std::chrono::steady_clock::now();
        client.Insert(cfg.ledger_writes_table, block);
        samples.push_back(elapsed_microseconds(start));
    }
    ledger_latency_summary("ledger_stream_insert", std::move(samples),
                               "rows_per_batch=" + std::to_string(cfg.ledger_stream_rows));
}

void run_one_mode(Client& client, const Config& cfg, const std::string& mode) {
    if (mode == "insert_bulk_columnar")            { run_insert_bulk_columnar(client, cfg); return; }
    if (mode == "select_bulk_columnar")            { run_select_bulk_columnar(client, cfg); return; }
    if (mode == "insert_lc_map")                   { run_insert_lc_map(client, cfg); return; }
    if (mode == "select_lc_map")                   { run_select_lc_map(client, cfg); return; }
    if (mode == "latency_single_insert")           { run_latency_single_insert(client, cfg); return; }
    if (mode == "latency_single_select")           { run_latency_single_select(client, cfg); return; }
    if (mode == "concurrent_insert_throughput")    { run_concurrent_insert_throughput(client, cfg); return; }
    if (mode == "benchsetup")                      { run_real_benchsetup(client, cfg); return; }
    if (mode == "select_orderby_limit")            { run_real_select_orderby_limit(client, cfg); return; }
    if (mode == "select_groupby")                  { run_real_select_groupby(client, cfg); return; }
    if (mode == "select_where_in")                 { run_real_select_where_in(client, cfg); return; }
    if (mode == "select_full_scan_proj")           { run_real_select_full_scan_proj(client, cfg); return; }
    if (mode == "select_lc_aggregation")           { run_real_select_lc_aggregation(client, cfg); return; }
    if (mode == "select_string_filter")            { run_real_select_string_filter(client, cfg); return; }
    if (mode == "select_decode_only")              { run_real_select_decode_only(client, cfg); return; }
    if (mode == "select_wire_only_count")          { run_real_select_wire_only_count(client, cfg); return; }
    if (mode == "ledger_benchsetup")           { run_ledger_benchsetup(client, cfg); return; }
    if (mode == "ledger_point_lookup_by_id")   { run_ledger_point_lookup_by_id(client, cfg); return; }
    if (mode == "ledger_has_refs")             { run_ledger_has_refs(client, cfg); return; }
    if (mode == "ledger_has_ref_kinds")       { run_ledger_has_ref_kinds(client, cfg); return; }
    if (mode == "ledger_has_participants")      { run_ledger_has_participants(client, cfg); return; }
    if (mode == "ledger_kind_slice")           { run_ledger_kind_slice(client, cfg); return; }
    if (mode == "ledger_bulk_insert")          { run_ledger_bulk_insert(client, cfg); return; }
    if (mode == "ledger_stream_insert")        { run_ledger_stream_insert(client, cfg); return; }
    std::cout << "[CH PERF CPP] unknown mode: " << mode << std::endl;
}

}  // namespace

int main() {
    Config cfg = load_config();
    std::string mode_list;
    for (size_t i = 0; i < cfg.modes.size(); ++i) {
        if (i > 0) mode_list += ",";
        mode_list += cfg.modes[i];
    }
    std::cout << "[CH PERF CPP] config host=" << cfg.host
              << " port=" << cfg.port
              << " database=" << cfg.database
              << " rows=" << cfg.row_count
              << " block_rows=" << cfg.block_row_count
              << " concurrency=" << cfg.concurrency
              << " modes=" << mode_list
              << " real_events_rows=" << cfg.real_events_rows
              << " sample_events_table=" << cfg.sample_events_table
              << " real_logs_rows=" << cfg.real_logs_rows
              << " sample_logs_table=" << cfg.sample_logs_table
              << " ledger_rows=" << cfg.ledger_rows
              << " ledger_table=" << cfg.ledger_table
              << " ledger_writes=" << cfg.ledger_writes_table
              << std::endl;

    auto client = connect(cfg);
    for (const auto& mode : cfg.modes) {
        try {
            run_one_mode(*client, cfg, mode);
        } catch (const std::exception& exception) {
            std::cout << "[CH PERF CPP] FAIL mode=" << mode
                      << " error=" << exception.what() << std::endl;
        } catch (...) {
            std::cout << "[CH PERF CPP] FAIL mode=" << mode
                      << " error=unknown" << std::endl;
        }
    }
    return 0;
}
