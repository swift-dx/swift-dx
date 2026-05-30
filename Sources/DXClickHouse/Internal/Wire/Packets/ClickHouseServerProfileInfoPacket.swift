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

import NIOCore

// Server profile info, sent at the end of a query stream. Wire layout
// (in source-code order, not field-min-rev order):
//   UVarInt  rows
//   UVarInt  blocks
//   UVarInt  bytes
//   Bool     applied_limit
//   UVarInt  rows_before_limit
//   Bool     calculated_rows_before_limit  (always true since 23.x;
//                                           server-side it's an
//                                           obsolete sentinel)
//   Bool     has_applied_aggregation       (>= 54_469)
//   UVarInt  rows_before_aggregation       (>= 54_469)
struct ClickHouseServerProfileInfoPacket: Sendable, Equatable {

    static let revisionWithRowsBeforeAggregation: UInt64 = 54_469

    let rows: UInt64
    let blocks: UInt64
    let bytes: UInt64
    let appliedLimit: Bool
    let rowsBeforeLimit: UInt64
    let calculatedRowsBeforeLimit: Bool
    let appliedAggregation: RevisionGated<Bool>
    let rowsBeforeAggregation: RevisionGated<UInt64>

    init(
        rows: UInt64,
        blocks: UInt64,
        bytes: UInt64,
        appliedLimit: Bool,
        rowsBeforeLimit: UInt64,
        calculatedRowsBeforeLimit: Bool,
        appliedAggregation: RevisionGated<Bool> = .unsupported,
        rowsBeforeAggregation: RevisionGated<UInt64> = .unsupported
    ) {
        self.rows = rows
        self.blocks = blocks
        self.bytes = bytes
        self.appliedLimit = appliedLimit
        self.rowsBeforeLimit = rowsBeforeLimit
        self.calculatedRowsBeforeLimit = calculatedRowsBeforeLimit
        self.appliedAggregation = appliedAggregation
        self.rowsBeforeAggregation = rowsBeforeAggregation
    }

    func encode(into buffer: inout ByteBuffer, revision: UInt64 = 0) {
        buffer.writeClickHouseUVarInt(rows)
        buffer.writeClickHouseUVarInt(blocks)
        buffer.writeClickHouseUVarInt(bytes)
        buffer.writeClickHouseBool(appliedLimit)
        buffer.writeClickHouseUVarInt(rowsBeforeLimit)
        buffer.writeClickHouseBool(calculatedRowsBeforeLimit)
        if revision >= Self.revisionWithRowsBeforeAggregation {
            buffer.writeClickHouseBool(appliedAggregation.unwrapOrDefault(false))
            buffer.writeClickHouseUVarInt(rowsBeforeAggregation.unwrapOrDefault(0))
        }
    }

    static func decode(from buffer: inout ByteBuffer, revision: UInt64 = 0) throws -> Self {
        let rows = try buffer.readClickHouseUVarInt()
        let blocks = try buffer.readClickHouseUVarInt()
        let bytes = try buffer.readClickHouseUVarInt()
        let appliedLimit = try buffer.readClickHouseBool()
        let rowsBeforeLimit = try buffer.readClickHouseUVarInt()
        let calculatedRowsBeforeLimit = try buffer.readClickHouseBool()
        let (appliedAggregation, rowsBeforeAggregation) = try decodeAggregation(from: &buffer, revision: revision)
        return .init(
            rows: rows,
            blocks: blocks,
            bytes: bytes,
            appliedLimit: appliedLimit,
            rowsBeforeLimit: rowsBeforeLimit,
            calculatedRowsBeforeLimit: calculatedRowsBeforeLimit,
            appliedAggregation: appliedAggregation,
            rowsBeforeAggregation: rowsBeforeAggregation
        )
    }

    private static func decodeAggregation(from buffer: inout ByteBuffer, revision: UInt64) throws -> (RevisionGated<Bool>, RevisionGated<UInt64>) {
        guard revision >= Self.revisionWithRowsBeforeAggregation else {
            return (.unsupported, .unsupported)
        }
        let applied = try buffer.readClickHouseBool()
        let rows = try buffer.readClickHouseUVarInt()
        return (.value(applied), .value(rows))
    }

}
