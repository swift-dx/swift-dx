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

import Foundation
import NIOCore

// Column-major SELECT helpers. `selectColumns` streams one
// `ClickHouseSelectBlock` per Data packet on the wire, suitable for
// pipelines that process blocks as they arrive (low peak memory,
// each block freed before the next is decoded). `collectSelectColumns`
// materializes all blocks into an array, suitable for small result
// sets where the caller wants the full result up-front.
//
// Both surfaces sit BELOW the Codable-based `selectStream`/`query`
// path: that path goes through this layer internally. Reach for these
// when you need direct access to the typed `Values` enum (e.g., a
// column kind without a Codable representation) or when you want to
// process blocks in-place without per-row decoding.
extension ClickHouseClient {

    public func selectColumns(
        _ sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = { _ in }
    ) -> AsyncThrowingStream<ClickHouseSelectBlock, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await block in self.select(
                        sql, settings: settings, parameters: parameters, onProgress: onProgress
                    ) {
                        let publicBlock = try Self.toSelectBlock(block)
                        if case .terminated = continuation.yield(publicBlock) {
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func collectSelectColumns(
        _ sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = { _ in }
    ) async throws(ClickHouseError) -> [ClickHouseSelectBlock] {
        try await ClickHouseError.bridge {
            var collected: [ClickHouseSelectBlock] = []
            for try await block in selectColumns(
                sql, settings: settings, parameters: parameters, onProgress: onProgress
            ) {
                collected.append(block)
            }
            return collected
        }
    }

    static func toSelectBlock(_ block: ClickHouseBlock) throws -> ClickHouseSelectBlock {
        var publicColumns: [ClickHouseSelectColumn] = []
        publicColumns.reserveCapacity(block.columns.count)
        for namedColumn in block.columns {
            let publicColumn = try ClickHouseSelectColumn.from(
                name: namedColumn.name,
                internalColumn: namedColumn.column
            )
            publicColumns.append(publicColumn)
        }
        return ClickHouseSelectBlock(rowCount: block.rowCount, columns: publicColumns)
    }

    // Zero-allocation column-view projection of a SELECT result.
    // Emits one `ClickHouseBlockStringView` per Data packet, exposing
    // every block column whose spec has a registered view (String,
    // FixedString(N), Array(FixedString(N)), Map(String, String),
    // Map(LowCardinality(String), String)). Each view borrows from
    // the per-block arena and skips per-row Swift `String`
    // allocations. Columns whose spec is not view-supported are not
    // surfaced through this API — callers that need them should also
    // (or instead) consume `selectColumns`.
    //
    // Use when the consumer is filter-heavy or projection-heavy on
    // payload columns and most rows never need to materialise into an
    // owned `String`. For "decode every row into a struct" workloads
    // the standard `selectStream` / `selectColumns` paths remain
    // preferable.
    public func selectStringColumns(
        _ sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = { _ in }
    ) -> AsyncThrowingStream<ClickHouseBlockStringView, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamStringColumnsBlocks(
                        sql: sql, settings: settings, parameters: parameters,
                        onProgress: onProgress, continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamStringColumnsBlocks(
        sql: String,
        settings: [ClickHouseQuerySetting],
        parameters: [ClickHouseQueryParameter],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void,
        continuation: AsyncThrowingStream<ClickHouseBlockStringView, Error>.Continuation
    ) async throws {
        for try await block in self.select(
            sql, settings: settings, parameters: parameters, onProgress: onProgress
        ) {
            let projection = Self.toBlockStringView(block)
            if case .terminated = continuation.yield(projection) {
                return
            }
        }
        continuation.finish()
    }

    static func toBlockStringView(_ block: ClickHouseBlock) -> ClickHouseBlockStringView {
        var builder = BlockStringViewBuilder(columnCount: block.columns.count)
        for namedColumn in block.columns {
            builder.appendIfSupported(name: namedColumn.name, column: namedColumn.column)
        }
        return builder.finish(rowCount: block.rowCount)
    }

}

private struct BlockStringViewBuilder {

    var stringColumns: [ClickHouseStringColumnView] = []
    var fixedStringColumns: [ClickHouseFixedStringColumnView] = []
    var arrayOfFixedStringColumns: [ClickHouseArrayOfFixedStringColumnView] = []
    var mapStringStringColumns: [ClickHouseMapStringStringColumnView] = []

    init(columnCount: Int) {
        stringColumns.reserveCapacity(columnCount)
        fixedStringColumns.reserveCapacity(columnCount)
        arrayOfFixedStringColumns.reserveCapacity(columnCount)
        mapStringStringColumns.reserveCapacity(columnCount)
    }

    mutating func appendIfSupported(name: String, column: any ClickHouseColumn) {
        switch column.spec {
        case .string, .json: appendString(name: name, column: column)
        case .fixedString, .ipv6: appendFixedString(name: name, column: column)
        case .array: appendArray(name: name, column: column)
        case .map: appendMap(name: name, column: column)
        default: return
        }
    }

    private mutating func appendString(name: String, column: any ClickHouseColumn) {
        guard let stringColumn = column as? ClickHouseStringColumn, stringColumn.hasArena else { return }
        stringColumns.append(stringColumn.makeColumnView(name: name))
    }

    private mutating func appendFixedString(name: String, column: any ClickHouseColumn) {
        guard let fixedColumn = column as? ClickHouseFixedStringColumn, fixedColumn.hasArena else { return }
        fixedStringColumns.append(fixedColumn.makeColumnView(name: name))
    }

    private mutating func appendArray(name: String, column: any ClickHouseColumn) {
        guard let arrayColumn = column as? ClickHouseArrayColumn else { return }
        guard let inner = arrayColumn.inner as? ClickHouseFixedStringColumn, inner.hasArena else { return }
        arrayOfFixedStringColumns.append(.init(name: name, elementArena: inner.arenaHandle(), offsets: arrayColumn.offsets))
    }

    private mutating func appendMap(name: String, column: any ClickHouseColumn) {
        guard let mapColumn = column as? ClickHouseMapColumn else { return }
        guard let valueStrings = mapColumn.values as? ClickHouseStringColumn, valueStrings.hasArena else { return }
        let valueView = valueStrings.makeColumnView(name: name + "::value")
        appendMapWithStringValues(name: name, mapColumn: mapColumn, valueView: valueView)
    }

    private mutating func appendMapWithStringValues(
        name: String,
        mapColumn: ClickHouseMapColumn,
        valueView: ClickHouseStringColumnView
    ) {
        if let keyStrings = mapColumn.keys as? ClickHouseStringColumn, keyStrings.hasArena {
            let keyView = keyStrings.makeColumnView(name: name + "::key")
            mapStringStringColumns.append(.init(name: name, keyColumn: keyView, valueColumn: valueView, offsets: mapColumn.offsets))
        }
    }

    func finish(rowCount: Int) -> ClickHouseBlockStringView {
        ClickHouseBlockStringView(
            rowCount: rowCount,
            stringColumns: stringColumns,
            fixedStringColumns: fixedStringColumns,
            arrayOfFixedStringColumns: arrayOfFixedStringColumns,
            mapStringStringColumns: mapStringStringColumns
        )
    }

}
