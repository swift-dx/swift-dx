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

import Instrumentation
import Tracing

// Typed INSERT path: accepts any `Encodable` row model and lowers it
// to wire columns via `ClickHouseRowEncoder`. This is the layer the
// `ClickHouse` facade routes to — the facade adds nothing but the
// singleton lookup.
//
// Both methods open the `clickhouse.insert` operation span and
// delegate the wire write to the untraced columnar path
// (`writeColumns` / `insert(into:blockProvider:)`) so a typed insert
// produces exactly one span rather than nesting an `insert.columns`
// span inside it.
extension ClickHouseClient {

    public func insert<T: Encodable & Sendable>(into table: String, rows: [T], settings: [ClickHouseQuerySetting] = [], keyEncodingStrategy: ClickHouseKeyEncodingStrategy = .useDefaultKeys) async throws(ClickHouseError) {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.insert", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                span.attributes["db.operation.name"] = "INSERT"
                span.attributes["db.collection.name"] = table
                span.attributes["db.row.count"] = rows.count
                let entries = try ClickHouseRowEncoder(keyEncodingStrategy: keyEncodingStrategy).encode(rows)
                try await writeColumns(into: table, columns: entries, settings: settings)
            }
        }
    }

    public func insertStream<T: Encodable & Sendable>(into table: String, nextBatch: @Sendable () async throws -> ClickHouseRowBatchOutcome<T>, settings: [ClickHouseQuerySetting] = [], keyEncodingStrategy: ClickHouseKeyEncodingStrategy = .useDefaultKeys) async throws(ClickHouseError) {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.insert", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                span.attributes["db.operation.name"] = "INSERT"
                span.attributes["db.collection.name"] = table
                span.attributes["clickhouse.insert.kind"] = "stream"
                let encoder = ClickHouseRowEncoder(keyEncodingStrategy: keyEncodingStrategy)
                try await insert(
                    into: table,
                    blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
                        while true {
                            switch try await nextBatch() {
                            case .endOfStream:
                                return .endOfStream
                            case .batch(let batch):
                                if batch.isEmpty { continue }
                                return .batch(try encoder.encode(batch))
                            }
                        }
                    },
                    settings: settings
                )
            }
        }
    }

}
