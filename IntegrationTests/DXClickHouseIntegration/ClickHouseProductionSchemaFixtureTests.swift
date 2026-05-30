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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOPosix
import Testing

@Suite(
    "ClickHouse production-schema fixtures",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseProductionSchemaFixtureTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static let fixtureDatabase = "test_fixtures"

    private static func uniqueTable(_ suffix: String) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        return "\(fixtureDatabase).\(suffix)_\(token)"
    }

    private static func configuration(eventLoopGroup: EventLoopGroup) -> ClickHouseClient.Configuration {
        .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            eventLoopGroup: eventLoopGroup
        )
    }

    @Test("raw_kinesis_otel — full production column shape round-trips through Codable insert + decoded read")
    func rawKinesisOtelRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("raw_kinesis_otel")
        try await client.execute("""
            CREATE TABLE \(table) (
              event_ts             DateTime64(9, 'Pacific/Auckland'),
              kinesis_arrival_ts   DateTime64(9, 'Pacific/Auckland'),
              consumer_received_ts DateTime64(9, 'Pacific/Auckland'),
              kinesis_stream_name  LowCardinality(String),
              kinesis_shard_id     LowCardinality(String),
              kinesis_partition_key String,
              kinesis_sequence_number String,
              env                  Enum8('production' = 1, 'staging' = 2, 'development' = 3),
              payload_format       LowCardinality(String) DEFAULT 'otlp_json',
              payload              String
            ) ENGINE = MergeTree
            ORDER BY (kinesis_shard_id, kinesis_sequence_number)
            """)

        struct Row: Codable, Equatable, Sendable {

            let eventTs: Int64
            let kinesisArrivalTs: Int64
            let consumerReceivedTs: Int64
            let kinesisStreamName: String
            let kinesisShardId: String
            let kinesisPartitionKey: String
            let kinesisSequenceNumber: String
            let env: String
            let payloadFormat: String
            let payload: String

        }

        let inputRows: [Row] = [
            .init(
                eventTs: 1_700_000_000_000_000_001,
                kinesisArrivalTs: 1_700_000_000_111_111_111,
                consumerReceivedTs: 1_700_000_000_222_222_222,
                kinesisStreamName: "ledger-events-production",
                kinesisShardId: "shardId-000000000000",
                kinesisPartitionKey: "pk-1",
                kinesisSequenceNumber: "49600000000000000000000000000000000000000000000000000000",
                env: "production",
                payloadFormat: "otlp_json",
                payload: #"{"k":"v"}"#
            ),
            .init(
                eventTs: 1_700_000_001_500_000_000,
                kinesisArrivalTs: 1_700_000_001_600_000_000,
                consumerReceivedTs: 1_700_000_001_700_000_000,
                kinesisStreamName: "ledger-events-production",
                kinesisShardId: "shardId-000000000001",
                kinesisPartitionKey: "pk-2",
                kinesisSequenceNumber: "49600000000000000000000000000000000000000000000000000001",
                env: "staging",
                payloadFormat: "otlp_json",
                payload: #"{"k":"v2"}"#
            ),
        ]

        try await client.insert(into: table, columns: [
            .init(name: "event_ts", values: .dateTime64Nanoseconds(inputRows.map { ClickHouseNanoseconds($0.eventTs) }, precision: 9)),
            .init(name: "kinesis_arrival_ts", values: .dateTime64Nanoseconds(inputRows.map { ClickHouseNanoseconds($0.kinesisArrivalTs) }, precision: 9)),
            .init(name: "consumer_received_ts", values: .dateTime64Nanoseconds(inputRows.map { ClickHouseNanoseconds($0.consumerReceivedTs) }, precision: 9)),
            .init(name: "kinesis_stream_name", values: .string(inputRows.map(\.kinesisStreamName))),
            .init(name: "kinesis_shard_id", values: .string(inputRows.map(\.kinesisShardId))),
            .init(name: "kinesis_partition_key", values: .string(inputRows.map(\.kinesisPartitionKey))),
            .init(name: "kinesis_sequence_number", values: .string(inputRows.map(\.kinesisSequenceNumber))),
            .init(name: "env", values: .string(inputRows.map(\.env))),
            .init(name: "payload_format", values: .string(inputRows.map(\.payloadFormat))),
            .init(name: "payload", values: .string(inputRows.map(\.payload))),
        ])

        let storedCount = try await client.scalarInt64("SELECT toInt64(count()) FROM \(table)")
        #expect(storedCount == Int64(inputRows.count))

        let decoded: [Row] = try await client.query(
            Row.self,
            from: "SELECT event_ts, kinesis_arrival_ts, consumer_received_ts, kinesis_stream_name, kinesis_shard_id, kinesis_partition_key, kinesis_sequence_number, env, payload_format, payload FROM \(table) ORDER BY kinesis_sequence_number",
            keyDecodingStrategy: .convertFromSnakeCase
        )
        #expect(decoded == inputRows)

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("cursor projection — kinesis_shard_id (LowCardinality(String)) + max(sequence) decodes into a String/String Codable struct")
    func cursorProjectionLowCardinalityDecodes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("cursor")
        try await client.execute("""
            CREATE TABLE \(table) (
              kinesis_shard_id        LowCardinality(String),
              kinesis_sequence_number String
            ) ENGINE = MergeTree ORDER BY kinesis_shard_id
            """)

        struct ShardRow: Codable, Sendable {

            let kinesisShardId: String
            let kinesisSequenceNumber: String

        }
        try await client.insert(
            into: table,
            rows: [
                ShardRow(kinesisShardId: "shardId-000000000000", kinesisSequenceNumber: "seq-1"),
                ShardRow(kinesisShardId: "shardId-000000000001", kinesisSequenceNumber: "seq-2"),
                ShardRow(kinesisShardId: "shardId-000000000000", kinesisSequenceNumber: "seq-3"),
            ],
            keyEncodingStrategy: .convertToSnakeCase
        )

        struct Cursor: Codable, Equatable, Sendable {

            let kinesisShardId: String
            let lastSequence: String

        }
        let cursors: [Cursor] = try await client.query(
            Cursor.self,
            from: "SELECT kinesis_shard_id, max(kinesis_sequence_number) AS last_sequence FROM \(table) GROUP BY kinesis_shard_id ORDER BY kinesis_shard_id",
            keyDecodingStrategy: .convertFromSnakeCase
        )
        #expect(cursors == [
            .init(kinesisShardId: "shardId-000000000000", lastSequence: "seq-3"),
            .init(kinesisShardId: "shardId-000000000001", lastSequence: "seq-2"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("Enum8 column projects as String — matching server-side enum label, not the raw Int8")
    func enum8ColumnDecodesAsLabel() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("enum8")
        try await client.execute("""
            CREATE TABLE \(table) (
              id  Int64,
              env Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree ORDER BY id
            """)

        struct Row: Codable, Equatable, Sendable {

            let id: Int64
            let env: String

        }
        let inputs: [Row] = [
            .init(id: 1, env: "production"),
            .init(id: 2, env: "staging"),
            .init(id: 3, env: "development"),
            .init(id: 4, env: "production"),
        ]
        try await client.insert(into: table, rows: inputs)

        let decoded: [Row] = try await client.query(
            Row.self,
            from: "SELECT id, env FROM \(table) ORDER BY id"
        )
        #expect(decoded == inputs)

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("LowCardinality(String) round-trips through a Codable struct's plain String field")
    func lowCardinalityStringRoundTripsAsString() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("low_card")
        try await client.execute("""
            CREATE TABLE \(table) (
              id  Int64,
              tag LowCardinality(String)
            ) ENGINE = MergeTree ORDER BY id
            """)

        struct Row: Codable, Equatable, Sendable {

            let id: Int64
            let tag: String

        }
        let inputs: [Row] = [
            .init(id: 1, tag: "NZ"),
            .init(id: 2, tag: "AU"),
            .init(id: 3, tag: "NZ"),
        ]
        try await client.insert(into: table, rows: inputs)

        let decoded: [Row] = try await client.query(
            Row.self,
            from: "SELECT id, tag FROM \(table) ORDER BY id"
        )
        #expect(decoded == inputs)

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver logs insert via columnar API against the production DDL (Map(LowCardinality(String), String) target) — the consumer pattern in TelemetryLogRepository")
    func silverLogsColumnarInsertRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("logs")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId        LowCardinality(String),
              KinesisSequenceNumber String,
              RecordIndex           UInt32,
              Version               DateTime64(9, 'Pacific/Auckland') DEFAULT now64(9, 'Pacific/Auckland'),
              Timestamp             DateTime64(9, 'Pacific/Auckland'),
              TimestampDate         Date DEFAULT toDate(Timestamp),
              TimestampTime         DateTime DEFAULT toDateTime(Timestamp),
              TraceId               String,
              SpanId                String,
              TraceFlags            UInt8,
              SeverityText          LowCardinality(String),
              SeverityNumber        UInt8,
              ServiceName           LowCardinality(String),
              Body                  String,
              ResourceSchemaUrl     LowCardinality(String),
              ResourceAttributes    Map(LowCardinality(String), String),
              ScopeSchemaUrl        LowCardinality(String),
              ScopeName             LowCardinality(String),
              ScopeVersion          LowCardinality(String),
              ScopeAttributes       Map(LowCardinality(String), String),
              LogAttributes         Map(LowCardinality(String), String),
              Env                   Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])),
            .init(name: "RecordIndex", values: .uint32([0, 1])),
            .init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "TraceId", values: .string(["t1", "t2"])),
            .init(name: "SpanId", values: .string(["s1", "s2"])),
            .init(name: "TraceFlags", values: .uint8([0, 1])),
            .init(name: "SeverityText", values: .string(["INFO", "ERROR"])),
            .init(name: "SeverityNumber", values: .uint8([9, 17])),
            .init(name: "ServiceName", values: .string(["svc-a", "svc-b"])),
            .init(name: "Body", values: .string(["hello", "world"])),
            .init(name: "ResourceSchemaUrl", values: .string(["", ""])),
            .init(name: "ResourceAttributes", values: .mapStringString([["host": "h1"], ["host": "h2"]])),
            .init(name: "ScopeSchemaUrl", values: .string(["", ""])),
            .init(name: "ScopeName", values: .string(["scope-a", "scope-b"])),
            .init(name: "ScopeVersion", values: .string(["1", "1"])),
            .init(name: "ScopeAttributes", values: .mapStringString([[:], [:]])),
            .init(name: "LogAttributes", values: .mapStringString([["k": "v"], [:]])),
            .init(name: "Env", values: .string(["production", "staging"])),
        ])

        struct LogRow: Codable, Equatable, Sendable {

            let KinesisShardId: String
            let KinesisSequenceNumber: String
            let TraceId: String
            let SeverityText: String
            let ServiceName: String
            let Body: String
            let Env: String

        }
        let decoded: [LogRow] = try await client.query(
            LogRow.self,
            from: "SELECT KinesisShardId, KinesisSequenceNumber, TraceId, SeverityText, ServiceName, Body, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(KinesisShardId: "shardId-000000000000", KinesisSequenceNumber: "seq-1", TraceId: "t1", SeverityText: "INFO", ServiceName: "svc-a", Body: "hello", Env: "production"),
            .init(KinesisShardId: "shardId-000000000001", KinesisSequenceNumber: "seq-2", TraceId: "t2", SeverityText: "ERROR", ServiceName: "svc-b", Body: "world", Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver metrics_histogram against the production DDL — Array(UInt64) BucketCounts + Array(Float64) ExplicitBounds round-trip through the columnar insert and the Codable read")
    func silverMetricsHistogramRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("metrics_histogram")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId         LowCardinality(String),
              KinesisSequenceNumber  String,
              RecordIndex            UInt32,
              Timestamp              DateTime64(9, 'Pacific/Auckland'),
              StartTimestamp         DateTime64(9, 'Pacific/Auckland'),
              MetricName             LowCardinality(String),
              MetricDescription      String,
              MetricUnit             LowCardinality(String),
              ServiceName            LowCardinality(String),
              Count                  UInt64,
              Sum                    Float64,
              BucketCounts           Array(UInt64),
              ExplicitBounds         Array(Float64),
              Min                    Float64,
              Max                    Float64,
              Flags                  UInt32,
              AggregationTemporality Int32,
              ResourceSchemaUrl      LowCardinality(String),
              ResourceAttributes     Map(LowCardinality(String), String),
              ScopeName              LowCardinality(String),
              ScopeVersion           LowCardinality(String),
              Attributes             Map(LowCardinality(String), String),
              Env                    Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        let bucketCounts: [[UInt64]] = [[1, 2, 3, 4], [10, 20, 30]]
        let explicitBounds: [[Double]] = [[0.5, 1.0, 2.0], [1.0, 10.0]]
        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])),
            .init(name: "RecordIndex", values: .uint32([0, 1])),
            .init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "StartTimestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "MetricName", values: .string(["http.latency", "db.query.duration"])),
            .init(name: "MetricDescription", values: .string(["HTTP latency", "DB query"])),
            .init(name: "MetricUnit", values: .string(["ms", "ms"])),
            .init(name: "ServiceName", values: .string(["svc-a", "svc-b"])),
            .init(name: "Count", values: .uint64([10, 60])),
            .init(name: "Sum", values: .float64([1.5, 99.5])),
            .init(name: "BucketCounts", values: .arrayOfUInt64(bucketCounts)),
            .init(name: "ExplicitBounds", values: .arrayOfFloat64(explicitBounds)),
            .init(name: "Min", values: .float64([0.1, 0.5])),
            .init(name: "Max", values: .float64([100.0, 99.5])),
            .init(name: "Flags", values: .uint32([0, 0])),
            .init(name: "AggregationTemporality", values: .int32([1, 2])),
            .init(name: "ResourceSchemaUrl", values: .string(["", ""])),
            .init(name: "ResourceAttributes", values: .mapStringString([["host": "h1"], [:]])),
            .init(name: "ScopeName", values: .string(["scope-a", "scope-b"])),
            .init(name: "ScopeVersion", values: .string(["1", "1"])),
            .init(name: "Attributes", values: .mapStringString([["m": "v"], [:]])),
            .init(name: "Env", values: .string(["production", "staging"])),
        ])

        struct HistogramRow: Codable, Equatable, Sendable {

            let MetricName: String
            let Count: UInt64
            let Sum: Double
            let BucketCounts: [UInt64]
            let ExplicitBounds: [Double]
            let Env: String

        }
        let decoded: [HistogramRow] = try await client.query(
            HistogramRow.self,
            from: "SELECT MetricName, Count, Sum, BucketCounts, ExplicitBounds, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(MetricName: "http.latency", Count: 10, Sum: 1.5, BucketCounts: [1, 2, 3, 4], ExplicitBounds: [0.5, 1.0, 2.0], Env: "production"),
            .init(MetricName: "db.query.duration", Count: 60, Sum: 99.5, BucketCounts: [10, 20, 30], ExplicitBounds: [1.0, 10.0], Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver traces against the production DDL — Array(LowCardinality(String)) and Array(DateTime64(9)) parallel-array nested columns round-trip through the columnar insert and a Codable read")
    func silverTracesRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("traces")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId        LowCardinality(String),
              KinesisSequenceNumber String,
              RecordIndex           UInt32,
              Timestamp             DateTime64(9, 'Pacific/Auckland'),
              TraceId               String,
              SpanId                String,
              ParentSpanId          String,
              TraceState            String,
              SpanName              LowCardinality(String),
              SpanKind              LowCardinality(String),
              ServiceName           LowCardinality(String),
              Duration              UInt64,
              StatusCode            LowCardinality(String),
              StatusMessage         String,
              ResourceSchemaUrl     LowCardinality(String),
              ResourceAttributes    Map(LowCardinality(String), String),
              ScopeName             LowCardinality(String),
              ScopeVersion          LowCardinality(String),
              SpanAttributes        Map(LowCardinality(String), String),
              `Events.Timestamp`    Array(DateTime64(9, 'Pacific/Auckland')),
              `Events.Name`         Array(LowCardinality(String)),
              `Events.Attributes`   Array(Map(LowCardinality(String), String)),
              `Links.TraceId`       Array(String),
              `Links.SpanId`        Array(String),
              `Links.TraceState`    Array(String),
              `Links.Attributes`    Array(Map(LowCardinality(String), String)),
              Env                   Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        var columns: [ClickHouseColumnEntry] = []
        columns.reserveCapacity(20)
        columns.append(.init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])))
        columns.append(.init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])))
        columns.append(.init(name: "RecordIndex", values: .uint32([0, 1])))
        columns.append(.init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)))
        columns.append(.init(name: "TraceId", values: .string(["trace-a", "trace-b"])))
        columns.append(.init(name: "SpanId", values: .string(["span-a", "span-b"])))
        columns.append(.init(name: "ParentSpanId", values: .string(["", "span-a"])))
        columns.append(.init(name: "TraceState", values: .string(["", ""])))
        columns.append(.init(name: "SpanName", values: .string(["GET /a", "POST /b"])))
        columns.append(.init(name: "SpanKind", values: .string(["SPAN_KIND_SERVER", "SPAN_KIND_CLIENT"])))
        columns.append(.init(name: "ServiceName", values: .string(["svc-a", "svc-b"])))
        columns.append(.init(name: "Duration", values: .uint64([1_500_000, 2_500_000])))
        columns.append(.init(name: "StatusCode", values: .string(["OK", "ERROR"])))
        columns.append(.init(name: "StatusMessage", values: .string(["", "boom"])))
        columns.append(.init(name: "ResourceSchemaUrl", values: .string(["", ""])))
        columns.append(.init(name: "ResourceAttributes", values: .mapStringString([["host": "h1"], [:]])))
        columns.append(.init(name: "ScopeName", values: .string(["scope-a", "scope-b"])))
        columns.append(.init(name: "ScopeVersion", values: .string(["1", "1"])))
        columns.append(.init(name: "SpanAttributes", values: .mapStringString([["k": "v"], [:]])))
        columns.append(.init(name: "Env", values: .string(["production", "staging"])))
        try await client.insert(into: table, columns: columns)

        struct SpanRow: Codable, Equatable, Sendable {

            let TraceId: String
            let SpanName: String
            let SpanKind: String
            let ServiceName: String
            let Duration: UInt64
            let StatusCode: String
            let Env: String

        }
        let decoded: [SpanRow] = try await client.query(
            SpanRow.self,
            from: "SELECT TraceId, SpanName, SpanKind, ServiceName, Duration, StatusCode, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(TraceId: "trace-a", SpanName: "GET /a", SpanKind: "SPAN_KIND_SERVER", ServiceName: "svc-a", Duration: 1_500_000, StatusCode: "OK", Env: "production"),
            .init(TraceId: "trace-b", SpanName: "POST /b", SpanKind: "SPAN_KIND_CLIENT", ServiceName: "svc-b", Duration: 2_500_000, StatusCode: "ERROR", Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver metrics_summary against the production DDL — Nested(ValueAtQuantiles) parallel-array group + Codable read with [Double] fields")
    func silverMetricsSummaryRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("metrics_summary")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId             LowCardinality(String),
              KinesisSequenceNumber      String,
              RecordIndex                UInt32,
              Timestamp                  DateTime64(9, 'Pacific/Auckland'),
              StartTimestamp             DateTime64(9, 'Pacific/Auckland'),
              MetricName                 LowCardinality(String),
              MetricDescription          String,
              MetricUnit                 LowCardinality(String),
              ServiceName                LowCardinality(String),
              Count                      UInt64,
              Sum                        Float64,
              `ValueAtQuantiles.Quantile` Array(Float64),
              `ValueAtQuantiles.Value`    Array(Float64),
              Flags                      UInt32,
              ResourceSchemaUrl          LowCardinality(String),
              ResourceAttributes         Map(LowCardinality(String), String),
              ScopeName                  LowCardinality(String),
              ScopeVersion               LowCardinality(String),
              Attributes                 Map(LowCardinality(String), String),
              Env                        Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        let quantiles: [[Double]] = [[0.5, 0.9, 0.99], [0.5, 0.95]]
        let qvalues:   [[Double]] = [[10.0, 50.0, 99.0], [12.0, 95.0]]
        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])),
            .init(name: "RecordIndex", values: .uint32([0, 1])),
            .init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "StartTimestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "MetricName", values: .string(["http.duration", "db.latency"])),
            .init(name: "MetricDescription", values: .string(["", ""])),
            .init(name: "MetricUnit", values: .string(["ms", "ms"])),
            .init(name: "ServiceName", values: .string(["svc-a", "svc-b"])),
            .init(name: "Count", values: .uint64([100, 200])),
            .init(name: "Sum", values: .float64([1500.0, 9500.0])),
            .init(name: "ValueAtQuantiles.Quantile", values: .arrayOfFloat64(quantiles)),
            .init(name: "ValueAtQuantiles.Value", values: .arrayOfFloat64(qvalues)),
            .init(name: "Flags", values: .uint32([0, 0])),
            .init(name: "ResourceSchemaUrl", values: .string(["", ""])),
            .init(name: "ResourceAttributes", values: .mapStringString([[:], [:]])),
            .init(name: "ScopeName", values: .string(["scope-a", "scope-b"])),
            .init(name: "ScopeVersion", values: .string(["1", "1"])),
            .init(name: "Attributes", values: .mapStringString([[:], [:]])),
            .init(name: "Env", values: .string(["production", "staging"])),
        ])

        struct SummaryRow: Codable, Equatable, Sendable {

            let MetricName: String
            let Count: UInt64
            let Sum: Double
            let valueAtQuantilesQuantile: [Double]
            let valueAtQuantilesValue: [Double]
            let Env: String

            enum CodingKeys: String, CodingKey {

                case MetricName
                case Count
                case Sum
                case valueAtQuantilesQuantile = "ValueAtQuantiles.Quantile"
                case valueAtQuantilesValue = "ValueAtQuantiles.Value"
                case Env

            }

        }
        let decoded: [SummaryRow] = try await client.query(
            SummaryRow.self,
            from: "SELECT MetricName, Count, Sum, `ValueAtQuantiles.Quantile`, `ValueAtQuantiles.Value`, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(MetricName: "http.duration", Count: 100, Sum: 1500.0, valueAtQuantilesQuantile: [0.5, 0.9, 0.99], valueAtQuantilesValue: [10.0, 50.0, 99.0], Env: "production"),
            .init(MetricName: "db.latency", Count: 200, Sum: 9500.0, valueAtQuantilesQuantile: [0.5, 0.95], valueAtQuantilesValue: [12.0, 95.0], Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("raw_kinesis_otel insert via the exact TelemetryEventRepository pattern against the production DDL — bronze hot path with materialized lag columns and partition-by env+ingestion month")
    func rawKinesisOtelProductionInsertRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("raw_kinesis_otel")
        try await client.execute("""
            CREATE TABLE \(table) (
              event_ts                    DateTime64(9, 'Pacific/Auckland'),
              kinesis_arrival_ts          DateTime64(9, 'Pacific/Auckland'),
              consumer_received_ts        DateTime64(9, 'Pacific/Auckland'),
              ingestion_ts                DateTime64(9, 'Pacific/Auckland') DEFAULT now64(9, 'Pacific/Auckland'),
              event_to_kinesis_lag_ms     Int32 MATERIALIZED toInt32(dateDiff('millisecond', event_ts, kinesis_arrival_ts)),
              kinesis_to_consumer_lag_ms  Int32 MATERIALIZED toInt32(dateDiff('millisecond', kinesis_arrival_ts, consumer_received_ts)),
              consumer_to_ingest_lag_ms   Int32 MATERIALIZED toInt32(dateDiff('millisecond', consumer_received_ts, ingestion_ts)),
              event_to_ingest_lag_ms      Int32 MATERIALIZED toInt32(dateDiff('millisecond', event_ts, ingestion_ts)),
              kinesis_stream_name         LowCardinality(String),
              kinesis_shard_id            LowCardinality(String),
              kinesis_partition_key       String,
              kinesis_sequence_number     String,
              env                         Enum8('production' = 1, 'staging' = 2, 'development' = 3),
              payload_format              LowCardinality(String) DEFAULT 'otlp_json',
              payload                     String,
              payload_size_bytes          UInt32 MATERIALIZED length(payload)
            ) ENGINE = MergeTree
            PARTITION BY (env, toYYYYMM(ingestion_ts))
            ORDER BY (kinesis_shard_id, kinesis_sequence_number)
            """)

        struct InputEvent: Sendable {

            let eventTs: Int64
            let kinesisArrivalTs: Int64
            let consumerReceivedTs: Int64
            let kinesisStreamName: String
            let kinesisShardId: String
            let kinesisPartitionKey: String
            let kinesisSequenceNumber: String
            let env: String
            let payloadFormat: String
            let payload: String

        }
        let events: [InputEvent] = [
            .init(eventTs: 1_700_000_000_000_000_001, kinesisArrivalTs: 1_700_000_000_111_111_111, consumerReceivedTs: 1_700_000_000_222_222_222, kinesisStreamName: "ledger-events-production", kinesisShardId: "shardId-000000000000", kinesisPartitionKey: "pk-1", kinesisSequenceNumber: "49600000000000000000000000000000000000000000000000000001", env: "production", payloadFormat: "otlp_json", payload: #"{"a":1}"#),
            .init(eventTs: 1_700_000_001_500_000_000, kinesisArrivalTs: 1_700_000_001_600_000_000, consumerReceivedTs: 1_700_000_001_700_000_000, kinesisStreamName: "ledger-events-production", kinesisShardId: "shardId-000000000001", kinesisPartitionKey: "pk-2", kinesisSequenceNumber: "49600000000000000000000000000000000000000000000000000002", env: "staging", payloadFormat: "otlp_json", payload: #"{"b":2}"#),
        ]
        try await client.insert(into: table, columns: [
            .init(name: "event_ts", values: .dateTime64Nanoseconds(events.map { ClickHouseNanoseconds($0.eventTs) }, precision: 9)),
            .init(name: "kinesis_arrival_ts", values: .dateTime64Nanoseconds(events.map { ClickHouseNanoseconds($0.kinesisArrivalTs) }, precision: 9)),
            .init(name: "consumer_received_ts", values: .dateTime64Nanoseconds(events.map { ClickHouseNanoseconds($0.consumerReceivedTs) }, precision: 9)),
            .init(name: "kinesis_stream_name", values: .string(events.map(\.kinesisStreamName))),
            .init(name: "kinesis_shard_id", values: .string(events.map(\.kinesisShardId))),
            .init(name: "kinesis_partition_key", values: .string(events.map(\.kinesisPartitionKey))),
            .init(name: "kinesis_sequence_number", values: .string(events.map(\.kinesisSequenceNumber))),
            .init(name: "env", values: .string(events.map(\.env))),
            .init(name: "payload_format", values: .string(events.map(\.payloadFormat))),
            .init(name: "payload", values: .string(events.map(\.payload))),
        ])

        let count = try await client.scalarInt64("SELECT toInt64(count()) FROM \(table)")
        #expect(count == 2)
        let nonZeroMaterialized = try await client.scalarInt64("""
            SELECT toInt64(count())
            FROM \(table)
            WHERE event_to_kinesis_lag_ms > 0
              AND payload_size_bytes > 0
            """)
        #expect(nonZeroMaterialized == 2,
                "MATERIALIZED columns must compute from inserted Int64-ticks DateTime64 values; non-zero values prove the wire→server conversion produced sane DateTime64s")

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver metrics_exponential_histogram against production DDL — two non-Nested parallel Array(UInt64) bucket columns + signed Int32 offsets that include negative values")
    func silverMetricsExponentialHistogramRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("metrics_exp_hist")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId         LowCardinality(String),
              KinesisSequenceNumber  String,
              RecordIndex            UInt32,
              Timestamp              DateTime64(9, 'Pacific/Auckland'),
              StartTimestamp         DateTime64(9, 'Pacific/Auckland'),
              MetricName             LowCardinality(String),
              ServiceName            LowCardinality(String),
              Count                  UInt64,
              Sum                    Float64,
              Scale                  Int32,
              ZeroCount              UInt64,
              PositiveOffset         Int32,
              PositiveBucketCounts   Array(UInt64),
              NegativeOffset         Int32,
              NegativeBucketCounts   Array(UInt64),
              Min                    Float64,
              Max                    Float64,
              Flags                  UInt32,
              AggregationTemporality Int32,
              ResourceSchemaUrl      LowCardinality(String),
              ResourceAttributes     Map(LowCardinality(String), String),
              ScopeName              LowCardinality(String),
              ScopeVersion           LowCardinality(String),
              Attributes             Map(LowCardinality(String), String),
              Env                    Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])),
            .init(name: "RecordIndex", values: .uint32([0, 1])),
            .init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "StartTimestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "MetricName", values: .string(["http.duration", "io.latency"])),
            .init(name: "ServiceName", values: .string(["svc-a", "svc-b"])),
            .init(name: "Count", values: .uint64([100, 0])),
            .init(name: "Sum", values: .float64([1500.0, 0.0])),
            .init(name: "Scale", values: .int32([3, -2])),
            .init(name: "ZeroCount", values: .uint64([5, 0])),
            .init(name: "PositiveOffset", values: .int32([-7, 12])),
            .init(name: "PositiveBucketCounts", values: .arrayOfUInt64([[10, 20, 30, 40], []])),
            .init(name: "NegativeOffset", values: .int32([-3, 0])),
            .init(name: "NegativeBucketCounts", values: .arrayOfUInt64([[5, 5], []])),
            .init(name: "Min", values: .float64([0.001, 0.0])),
            .init(name: "Max", values: .float64([999.0, 0.0])),
            .init(name: "Flags", values: .uint32([0, 0])),
            .init(name: "AggregationTemporality", values: .int32([1, 2])),
            .init(name: "ResourceSchemaUrl", values: .string(["", ""])),
            .init(name: "ResourceAttributes", values: .mapStringString([[:], [:]])),
            .init(name: "ScopeName", values: .string(["scope-a", "scope-b"])),
            .init(name: "ScopeVersion", values: .string(["1", "1"])),
            .init(name: "Attributes", values: .mapStringString([[:], [:]])),
            .init(name: "Env", values: .string(["production", "staging"])),
        ])

        struct ExpHistRow: Codable, Equatable, Sendable {

            let MetricName: String
            let Scale: Int32
            let PositiveOffset: Int32
            let PositiveBucketCounts: [UInt64]
            let NegativeOffset: Int32
            let NegativeBucketCounts: [UInt64]
            let Env: String

        }
        let decoded: [ExpHistRow] = try await client.query(
            ExpHistRow.self,
            from: "SELECT MetricName, Scale, PositiveOffset, PositiveBucketCounts, NegativeOffset, NegativeBucketCounts, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(MetricName: "http.duration", Scale: 3, PositiveOffset: -7, PositiveBucketCounts: [10, 20, 30, 40], NegativeOffset: -3, NegativeBucketCounts: [5, 5], Env: "production"),
            .init(MetricName: "io.latency", Scale: -2, PositiveOffset: 12, PositiveBucketCounts: [], NegativeOffset: 0, NegativeBucketCounts: [], Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver watermark — max(KinesisSequenceNumber) on an empty table decodes to empty String (not NULL/missing) so the Lookup<String>.notFound branch in TelemetrySilverWatermark is reachable")
    func silverWatermarkEmptyTableReturnsEmptyString() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("watermark")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId        LowCardinality(String),
              KinesisSequenceNumber String
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber)
            """)

        struct MaxRow: Codable, Equatable, Sendable {

            let maxSeq: String

        }

        let empty: [MaxRow] = try await client.query(
            MaxRow.self,
            from: "SELECT max(KinesisSequenceNumber) AS max_seq FROM \(table) WHERE KinesisShardId = 'shard-000'",
            keyDecodingStrategy: .convertFromSnakeCase
        )
        #expect(empty.count == 1, "max() aggregate always yields one row even with zero input rows")
        #expect(empty.first?.maxSeq == "", "max(String) on empty input returns empty string, not NULL")

        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shard-000", "shard-000"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-5"])),
        ])
        let populated: [MaxRow] = try await client.query(
            MaxRow.self,
            from: "SELECT max(KinesisSequenceNumber) AS max_seq FROM \(table) WHERE KinesisShardId = 'shard-000'",
            keyDecodingStrategy: .convertFromSnakeCase
        )
        #expect(populated.first?.maxSeq == "seq-5")

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver metrics_sum against the production DDL — Bool IsMonotonic + Int32 AggregationTemporality round-trip through Codable")
    func silverMetricsSumRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("metrics_sum")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId         LowCardinality(String),
              KinesisSequenceNumber  String,
              RecordIndex            UInt32,
              Timestamp              DateTime64(9, 'Pacific/Auckland'),
              StartTimestamp         DateTime64(9, 'Pacific/Auckland'),
              MetricName             LowCardinality(String),
              ServiceName            LowCardinality(String),
              Value                  Float64,
              Flags                  UInt32,
              AggregationTemporality Int32,
              IsMonotonic            Bool,
              ResourceSchemaUrl      LowCardinality(String),
              ResourceAttributes     Map(LowCardinality(String), String),
              ScopeName              LowCardinality(String),
              ScopeVersion           LowCardinality(String),
              Attributes             Map(LowCardinality(String), String),
              Env                    Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])),
            .init(name: "RecordIndex", values: .uint32([0, 1])),
            .init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "StartTimestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "MetricName", values: .string(["http.requests", "memory.bytes"])),
            .init(name: "ServiceName", values: .string(["svc-a", "svc-b"])),
            .init(name: "Value", values: .float64([42.5, 1024.0])),
            .init(name: "Flags", values: .uint32([0, 0])),
            .init(name: "AggregationTemporality", values: .int32([1, 2])),
            .init(name: "IsMonotonic", values: .bool([true, false])),
            .init(name: "ResourceSchemaUrl", values: .string(["", ""])),
            .init(name: "ResourceAttributes", values: .mapStringString([[:], [:]])),
            .init(name: "ScopeName", values: .string(["scope-a", "scope-b"])),
            .init(name: "ScopeVersion", values: .string(["1", "1"])),
            .init(name: "Attributes", values: .mapStringString([[:], [:]])),
            .init(name: "Env", values: .string(["production", "staging"])),
        ])

        struct SumRow: Codable, Equatable, Sendable {

            let MetricName: String
            let Value: Double
            let AggregationTemporality: Int32
            let IsMonotonic: Bool
            let Env: String

        }
        let decoded: [SumRow] = try await client.query(
            SumRow.self,
            from: "SELECT MetricName, Value, AggregationTemporality, IsMonotonic, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(MetricName: "http.requests", Value: 42.5, AggregationTemporality: 1, IsMonotonic: true, Env: "production"),
            .init(MetricName: "memory.bytes", Value: 1024.0, AggregationTemporality: 2, IsMonotonic: false, Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("silver metrics_gauge against the production DDL — last untested silver consumer, Float64 Value + Map(LowCardinality(String), String) Attributes")
    func silverMetricsGaugeRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("metrics_gauge")
        try await client.execute("""
            CREATE TABLE \(table) (
              KinesisShardId        LowCardinality(String),
              KinesisSequenceNumber String,
              RecordIndex           UInt32,
              Timestamp             DateTime64(9, 'Pacific/Auckland'),
              StartTimestamp        DateTime64(9, 'Pacific/Auckland'),
              MetricName            LowCardinality(String),
              MetricDescription     String,
              MetricUnit            LowCardinality(String),
              ServiceName           LowCardinality(String),
              Value                 Float64,
              Flags                 UInt32,
              ResourceSchemaUrl     LowCardinality(String),
              ResourceAttributes    Map(LowCardinality(String), String),
              ScopeName             LowCardinality(String),
              ScopeVersion          LowCardinality(String),
              Attributes            Map(LowCardinality(String), String),
              Env                   Enum8('production' = 1, 'staging' = 2, 'development' = 3)
            ) ENGINE = MergeTree
            ORDER BY (KinesisShardId, KinesisSequenceNumber, RecordIndex)
            """)

        let ts = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        try await client.insert(into: table, columns: [
            .init(name: "KinesisShardId", values: .string(["shardId-000000000000", "shardId-000000000001"])),
            .init(name: "KinesisSequenceNumber", values: .string(["seq-1", "seq-2"])),
            .init(name: "RecordIndex", values: .uint32([0, 1])),
            .init(name: "Timestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "StartTimestamp", values: .dateTime64Nanoseconds([ts, ts], precision: 9)),
            .init(name: "MetricName", values: .string(["cpu.utilization", "memory.free_ratio"])),
            .init(name: "MetricDescription", values: .string(["", ""])),
            .init(name: "MetricUnit", values: .string(["%", "%"])),
            .init(name: "ServiceName", values: .string(["svc-a", "svc-b"])),
            .init(name: "Value", values: .float64([0.42, 0.83])),
            .init(name: "Flags", values: .uint32([0, 0])),
            .init(name: "ResourceSchemaUrl", values: .string(["", ""])),
            .init(name: "ResourceAttributes", values: .mapStringString([["host": "h1"], [:]])),
            .init(name: "ScopeName", values: .string(["scope-a", "scope-b"])),
            .init(name: "ScopeVersion", values: .string(["1", "1"])),
            .init(name: "Attributes", values: .mapStringString([["region": "ap-southeast-2"], [:]])),
            .init(name: "Env", values: .string(["production", "staging"])),
        ])

        struct GaugeRow: Codable, Equatable, Sendable {

            let MetricName: String
            let Value: Double
            let Attributes: [String: String]
            let Env: String

        }
        let decoded: [GaugeRow] = try await client.query(
            GaugeRow.self,
            from: "SELECT MetricName, Value, Attributes, Env FROM \(table) ORDER BY KinesisSequenceNumber"
        )
        #expect(decoded == [
            .init(MetricName: "cpu.utilization", Value: 0.42, Attributes: ["region": "ap-southeast-2"], Env: "production"),
            .init(MetricName: "memory.free_ratio", Value: 0.83, Attributes: [:], Env: "staging"),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

    @Test("bronze read projection — SELECT kinesis_shard_id, kinesis_sequence_number, env, payload FROM raw_kinesis_otel decodes into DLBronzeRowForProjection (LowCardinality(String) + Enum8 + String)")
    func bronzeReadProjectionRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }
        try await client.execute("CREATE DATABASE IF NOT EXISTS \(Self.fixtureDatabase)")

        let table = Self.uniqueTable("bronze_proj")
        try await client.execute("""
            CREATE TABLE \(table) (
              event_ts                DateTime64(9, 'Pacific/Auckland'),
              kinesis_arrival_ts      DateTime64(9, 'Pacific/Auckland'),
              consumer_received_ts    DateTime64(9, 'Pacific/Auckland'),
              kinesis_stream_name     LowCardinality(String),
              kinesis_shard_id        LowCardinality(String),
              kinesis_partition_key   String,
              kinesis_sequence_number String,
              env                     Enum8('production' = 1, 'staging' = 2, 'development' = 3),
              payload_format          LowCardinality(String) DEFAULT 'otlp_json',
              payload                 String
            ) ENGINE = MergeTree
            ORDER BY (kinesis_shard_id, kinesis_sequence_number)
            """)

        let shardIds = ["shardId-000000000000", "shardId-000000000001", "shardId-000000000000"]
        let sequenceNumbers = ["seq-1", "seq-2", "seq-3"]
        let envs = ["production", "staging", "production"]
        let payloads = [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#]
        let now = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        try await client.insert(into: table, columns: [
            .init(name: "event_ts", values: .dateTime64Nanoseconds(Array(repeating: now, count: 3), precision: 9)),
            .init(name: "kinesis_arrival_ts", values: .dateTime64Nanoseconds(Array(repeating: now, count: 3), precision: 9)),
            .init(name: "consumer_received_ts", values: .dateTime64Nanoseconds(Array(repeating: now, count: 3), precision: 9)),
            .init(name: "kinesis_stream_name", values: .string(Array(repeating: "stream", count: 3))),
            .init(name: "kinesis_shard_id", values: .string(shardIds)),
            .init(name: "kinesis_partition_key", values: .string(Array(repeating: "pk", count: 3))),
            .init(name: "kinesis_sequence_number", values: .string(sequenceNumbers)),
            .init(name: "env", values: .string(envs)),
            .init(name: "payload_format", values: .string(Array(repeating: "otlp_json", count: 3))),
            .init(name: "payload", values: .string(payloads)),
        ])

        struct Row: Codable, Equatable, Sendable {

            let kinesisShardId: String
            let kinesisSequenceNumber: String
            let env: String
            let payload: String

        }
        let decoded: [Row] = try await client.query(
            Row.self,
            from: "SELECT kinesis_shard_id, kinesis_sequence_number, env, payload FROM \(table) WHERE kinesis_shard_id = 'shardId-000000000000' AND kinesis_sequence_number > '' ORDER BY kinesis_sequence_number LIMIT 100",
            keyDecodingStrategy: .convertFromSnakeCase
        )

        #expect(decoded == [
            .init(kinesisShardId: "shardId-000000000000", kinesisSequenceNumber: "seq-1", env: "production", payload: #"{"a":1}"#),
            .init(kinesisShardId: "shardId-000000000000", kinesisSequenceNumber: "seq-3", env: "production", payload: #"{"c":3}"#),
        ])

        try await client.execute("DROP TABLE \(table)")
    }

}
