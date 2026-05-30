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

// Server progress update. Wire layout (revision-gated, in source order):
//   UVarInt  read_rows                                   (always)
//   UVarInt  read_bytes                                  (always)
//   UVarInt  total_rows_to_read                          (always)
//   UVarInt  total_bytes_to_read   (>= 54_463 — DBMS_MIN_PROTOCOL_VERSION_WITH_TOTAL_BYTES_IN_PROGRESS)
//   UVarInt  written_rows          (>= 54_420 — DBMS_MIN_REVISION_WITH_CLIENT_WRITE_INFO)
//   UVarInt  written_bytes         (>= 54_420)
//   UVarInt  elapsed_ns            (>= 54_460 — DBMS_MIN_PROTOCOL_VERSION_WITH_SERVER_QUERY_TIME_IN_PROGRESS)
//
// Encoded under the negotiated revision; older servers omit fields,
// newer servers emit them in source-code order regardless of feature
// independence.
struct ClickHouseServerProgressPacket: Sendable, Equatable {

    static let revisionWithClientWriteInfo: UInt64 = 54_420
    static let revisionWithServerQueryTimeInProgress: UInt64 = 54_460
    static let revisionWithTotalBytesInProgress: UInt64 = 54_463

    let rows: UInt64
    let bytes: UInt64
    let totalRows: UInt64
    let totalBytes: RevisionGated<UInt64>
    let writtenRows: RevisionGated<UInt64>
    let writtenBytes: RevisionGated<UInt64>
    let elapsedNanoseconds: RevisionGated<UInt64>

    var publicProgress: ClickHouseProgress {
        ClickHouseProgress(
            rows: rows,
            bytes: bytes,
            totalRows: totalRows,
            writtenRows: writtenRows.asWriteCounter,
            writtenBytes: writtenBytes.asWriteCounter
        )
    }

    init(
        rows: UInt64,
        bytes: UInt64,
        totalRows: UInt64,
        totalBytes: RevisionGated<UInt64> = .unsupported,
        writtenRows: RevisionGated<UInt64> = .unsupported,
        writtenBytes: RevisionGated<UInt64> = .unsupported,
        elapsedNanoseconds: RevisionGated<UInt64> = .unsupported
    ) {
        self.rows = rows
        self.bytes = bytes
        self.totalRows = totalRows
        self.totalBytes = totalBytes
        self.writtenRows = writtenRows
        self.writtenBytes = writtenBytes
        self.elapsedNanoseconds = elapsedNanoseconds
    }

    func encode(into buffer: inout ByteBuffer, revision: UInt64) {
        buffer.writeClickHouseUVarInt(rows)
        buffer.writeClickHouseUVarInt(bytes)
        buffer.writeClickHouseUVarInt(totalRows)
        encodeRevisionedProgress(into: &buffer, revision: revision)
    }

    private func encodeRevisionedProgress(into buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= Self.revisionWithTotalBytesInProgress {
            buffer.writeClickHouseUVarInt(totalBytes.unwrapOrDefault(0))
        }
        encodeClientWriteInfo(into: &buffer, revision: revision)
        if revision >= Self.revisionWithServerQueryTimeInProgress {
            buffer.writeClickHouseUVarInt(elapsedNanoseconds.unwrapOrDefault(0))
        }
    }

    private func encodeClientWriteInfo(into buffer: inout ByteBuffer, revision: UInt64) {
        guard revision >= Self.revisionWithClientWriteInfo else { return }
        buffer.writeClickHouseUVarInt(writtenRows.unwrapOrDefault(0))
        buffer.writeClickHouseUVarInt(writtenBytes.unwrapOrDefault(0))
    }

    static func decode(from buffer: inout ByteBuffer, revision: UInt64) throws -> Self {
        let rows = try buffer.readClickHouseUVarInt()
        let bytes = try buffer.readClickHouseUVarInt()
        let totalRows = try buffer.readClickHouseUVarInt()
        let gated = try decodeGatedProgress(from: &buffer, revision: revision)
        return .init(
            rows: rows,
            bytes: bytes,
            totalRows: totalRows,
            totalBytes: gated.totalBytes,
            writtenRows: gated.writtenRows,
            writtenBytes: gated.writtenBytes,
            elapsedNanoseconds: gated.elapsedNs
        )
    }

    private struct GatedProgressFields {
        let totalBytes: RevisionGated<UInt64>
        let writtenRows: RevisionGated<UInt64>
        let writtenBytes: RevisionGated<UInt64>
        let elapsedNs: RevisionGated<UInt64>
    }

    private static func decodeGatedProgress(from buffer: inout ByteBuffer, revision: UInt64) throws -> GatedProgressFields {
        let totalBytes = try readGated(from: &buffer, gate: revision >= Self.revisionWithTotalBytesInProgress)
        let writtenRows = try readGated(from: &buffer, gate: revision >= Self.revisionWithClientWriteInfo)
        let writtenBytes = try readGated(from: &buffer, gate: revision >= Self.revisionWithClientWriteInfo)
        let elapsedNs = try readGated(from: &buffer, gate: revision >= Self.revisionWithServerQueryTimeInProgress)
        return GatedProgressFields(totalBytes: totalBytes, writtenRows: writtenRows, writtenBytes: writtenBytes, elapsedNs: elapsedNs)
    }

    private static func readGated(from buffer: inout ByteBuffer, gate: Bool) throws -> RevisionGated<UInt64> {
        guard gate else { return .unsupported }
        return .value(try buffer.readClickHouseUVarInt())
    }

}
