//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Typed factories for the ClickHouse server settings most commonly
// used by SDK callers. Each factory eliminates a class of stringly-
// typed bug at the call site (typo in setting name, wrong unit, wrong
// boolean encoding) without losing the flexibility to pass arbitrary
// settings via `ClickHouseQuerySetting.init`.
//
// Wire encoding follows ClickHouse's documented format:
//   - integers: decimal string ("1024")
//   - booleans: "0" / "1"
//   - enums: lowercase identifier (e.g., "deny", "allow_alter")
//
// The factory list is intentionally short — only settings the SDK has
// been observed to use (or that frequently appear in production
// pipelines). Adding more is a one-line addition; the goal is to make
// the common path type-safe, not to mirror every server flag.
public extension ClickHouseQuerySetting {

    // Maximum number of rows per Data block on SELECT. The server
    // splits the result set into blocks of at most this many rows.
    // Common production values: 65_536 (server default), 8_192 for
    // low-latency pipelines, 1_024 for slow-consumer back-pressure
    // tests.
    static func maxBlockSize(_ rows: Int) -> Self {
        .init(name: "max_block_size", value: String(rows))
    }

    // Server-side query timeout. The query is killed and an Exception
    // packet is returned if execution exceeds this many seconds. The
    // SDK surfaces it as `serverException` with a TIMEOUT_EXCEEDED
    // code.
    static func maxExecutionTimeSeconds(_ seconds: Int) -> Self {
        .init(name: "max_execution_time", value: String(seconds))
    }

    // Server-side memory cap for one query. The server kills the
    // query and returns an Exception when its allocator hits this
    // limit. Bytes.
    static func maxMemoryUsageBytes(_ bytes: Int) -> Self {
        .init(name: "max_memory_usage", value: String(bytes))
    }

    // Maximum threads the server will use to execute one query.
    // 0 (the server default) lets it auto-scale.
    static func maxThreads(_ count: Int) -> Self {
        .init(name: "max_threads", value: String(count))
    }

    // Hard cap on result rows. The server kills the query (or
    // truncates the result, depending on overflow_mode) when the
    // count is reached.
    static func maxResultRows(_ rows: Int) -> Self {
        .init(name: "max_result_rows", value: String(rows))
    }

    // INSERT side: enable server-side batching. The server queues
    // small inserts and flushes them in a coalesced batch. Pair with
    // `waitForAsyncInsert(true)` for deterministic completion or
    // `waitForAsyncInsert(false)` for fire-and-forget semantics.
    static func asyncInsert(_ enabled: Bool) -> Self {
        .init(name: "async_insert", value: enabled ? "1" : "0")
    }

    // INSERT side: when async_insert is on, controls whether the
    // client's INSERT call awaits the server-side flush. true gives
    // a deterministic completion signal (use for tests / strict
    // pipelines); false returns as soon as the data is queued
    // server-side.
    static func waitForAsyncInsert(_ enabled: Bool) -> Self {
        .init(name: "wait_for_async_insert", value: enabled ? "1" : "0")
    }

    // INSERT side: how long the client waits for the server-side
    // flush before timing out, in seconds. Only meaningful when
    // wait_for_async_insert is on.
    static func waitForAsyncInsertTimeoutSeconds(_ seconds: Int) -> Self {
        .init(name: "wait_for_async_insert_timeout", value: String(seconds))
    }

    // Per-block ceiling on `sleepEachRow` and similar test/benchmark
    // helpers. Bumped above the default in tests that deliberately
    // sleep server-side to exercise mid-query cancellation or
    // timeout paths.
    static func functionSleepMaxMicrosecondsPerBlock(_ microseconds: Int) -> Self {
        .init(name: "function_sleep_max_microseconds_per_block", value: String(microseconds))
    }

    // Read-only enforcement at the connection level.
    //   .readWrite     - 0: full SELECT/INSERT/DDL.
    //   .readOnly      - 1: SELECT only; no INSERT, no DDL, no SET.
    //   .readOnlyWithSettingChanges - 2: SELECT plus SET for the
    //     session.
    static func readonly(_ mode: ReadonlyMode) -> Self {
        .init(name: "readonly", value: String(mode.rawValue))
    }

    // INSERT side: deduplicate inserted blocks against a server-side
    // window. Each Data block's content is hashed; blocks whose hash
    // matches an entry already inserted within the dedup window are
    // dropped. Used by retried INSERTs to avoid duplicate commits
    // when a network blip masked a successful first attempt.
    static func insertDeduplicate(_ enabled: Bool) -> Self {
        .init(name: "insert_deduplicate", value: enabled ? "1" : "0")
    }

    // SELECT side: cap how many rows the server scans for the query.
    // Exceeding the cap raises a TOO_MANY_ROWS exception before the
    // result is assembled. Useful as a "blast radius" guard on user-
    // supplied filters that might select more than expected.
    static func maxRowsToRead(_ rows: Int64) -> Self {
        .init(name: "max_rows_to_read", value: String(rows))
    }

    // SELECT side: cap how many bytes the server reads to satisfy
    // the query. Companion to `maxRowsToRead` for byte-bounded plans.
    static func maxBytesToRead(_ bytes: Int64) -> Self {
        .init(name: "max_bytes_to_read", value: String(bytes))
    }

    // SELECT side: cap result size in bytes (any single result block).
    // Companion to `maxResultRows` for byte-based result truncation.
    static func maxResultBytes(_ bytes: Int64) -> Self {
        .init(name: "max_result_bytes", value: String(bytes))
    }

    // SELECT side: per-shard send budget for distributed queries.
    // Distinct from `maxExecutionTimeSeconds` which bounds the end-to-
    // end wall clock.
    static func sendTimeoutSeconds(_ seconds: Int) -> Self {
        .init(name: "send_timeout", value: String(seconds))
    }

    static func receiveTimeoutSeconds(_ seconds: Int) -> Self {
        .init(name: "receive_timeout", value: String(seconds))
    }

    // Whether the server should emit `Log` packets during query
    // execution. `.none` elides them entirely, saving network round-
    // trips; the higher levels surface progressively more diagnostic
    // detail.
    static func sendLogsLevel(_ level: ClickHouseLogLevel) -> Self {
        .init(name: "send_logs_level", value: level.rawValue)
    }

    // Behavior when `max_result_*` thresholds are crossed. `.throw`
    // raises an exception; `.break` truncates the result and stops.
    static func resultOverflowMode(_ mode: ClickHouseOverflowMode) -> Self {
        .init(name: "result_overflow_mode", value: mode.rawValue)
    }

    enum ReadonlyMode: Int, Sendable, CaseIterable {

        case readWrite = 0
        case readOnly = 1
        case readOnlyWithSettingChanges = 2

    }

}
