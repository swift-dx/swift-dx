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

// Low-level INSERT helpers layered on top of the sync ClickHouseConnection.
//
// The native-protocol INSERT flow with no compression is:
//
//   1. Client sends Query packet (INSERT INTO table (cols...) FORMAT Native)
//   2. Server responds with one or more meta packets (TableColumns,
//      ProfileInfo, Progress, optionally Log/Timezone) followed by an
//      empty Data packet (the schema sample block: 0 rows, N columns
//      with names + ClickHouse type names). The empty sample block is
//      the signal that the server is ready to receive data.
//   3. Client sends one or more Data packets, each carrying a Block
//      with N columns matching the sample schema.
//   4. Client sends a final empty Data packet (0 columns, 0 rows) as
//      the end-of-data marker.
//   5. Server emits zero or more Progress / ProfileInfo packets, then
//      EndOfStream.
//
// This extension surfaces the three building blocks the typed
// Codable INSERT path needs without exposing the wire details:
//
//   * `receiveInsertSampleSchema()` drains step 2 and returns the
//     decoded `(columnName, columnType)` pairs.
//   * `sendRawBytes(_:)` writes an arbitrary pre-assembled packet
//     onto the socket (typically a Data packet built by
//     `ClickHouseBlockWriter`).
//   * `receiveEndOfStream(onProgress:)` drains step 5 and returns
//     the cumulative server-reported rows + bytes.
extension ClickHouseConnection {

    public struct InsertSchemaColumn: Sendable, Equatable {

        public let name: String
        public let typeName: String

        public init(name: String, typeName: String) {
            self.name = name
            self.typeName = typeName
        }
    }

    public func receiveInsertSampleSchema() throws(ClickHouseError) -> [InsertSchemaColumn] {
        try closingOnBrokenRead {
            var schema: [InsertSchemaColumn] = []
            var seenSample = false
            while !seenSample {
                let packetType = try readUVarIntInternal()
                seenSample = try handleSampleSchemaPacket(packetType: packetType, schema: &schema)
            }
            return schema
        }
    }

    private func handleSampleSchemaPacket(
        packetType: UInt64,
        schema: inout [InsertSchemaColumn]
    ) throws(ClickHouseError) -> Bool {
        switch packetType {
        case 1:
            schema = try parseSampleBlockHeaderInternal()
            return true
        case 2:
            throw .queryFailed(serverException: try readExceptionPacketInternal())
        case 4:
            return false
        default:
            try skipNonSchemaPacket(packetType: packetType, stage: "receiveInsertSampleSchema")
            return false
        }
    }

    private func skipNonSchemaPacket(packetType: UInt64, stage: String) throws(ClickHouseError) {
        switch packetType {
        case 3: try skipProgressPacketInternal()
        case 6: try skipProfileInfoPacketInternal()
        case 10, 14:
            _ = try readStringInternal()
            try skipBlockInternal()
        case 11:
            _ = try readStringInternal()
            _ = try readStringInternal()
        case 17:
            _ = try readStringInternal()
        default:
            throw .protocolError(stage: stage, message: "unexpected packet type \(packetType)")
        }
    }

    public func sendRawBytes(_ bytes: [UInt8]) throws(ClickHouseError) {
        try sendAllOnceInternal(bytes)
    }

    // Sends `first` immediately followed by `second` as a single contiguous
    // write, so the two cannot land in separate segments that a partial-read
    // peer could interleave with the next request.
    public func sendRawBytes(_ first: [UInt8], then second: [UInt8]) throws(ClickHouseError) {
        try sendAllVectoredInternal(first, second)
    }

    private enum EndOfStreamStep {
        case keepReading
        case finished(rows: UInt64, bytes: UInt64)
    }

    public func receiveEndOfStream(
        onProgress: (ClickHouseProgress) -> Void = { _ in }
    ) throws(ClickHouseError) -> (rows: UInt64, bytes: UInt64) {
        try closingOnBrokenRead {
            var writtenRows: UInt64 = 0
            var writtenBytes: UInt64 = 0
            while true {
                let packetType = try readUVarIntInternal()
                let step = try handleEndOfStreamPacket(
                    packetType: packetType,
                    writtenRows: &writtenRows,
                    writtenBytes: &writtenBytes,
                    onProgress: onProgress
                )
                if case .finished(let rows, let bytes) = step {
                    return (rows, bytes)
                }
            }
        }
    }

    private func handleEndOfStreamPacket(
        packetType: UInt64,
        writtenRows: inout UInt64,
        writtenBytes: inout UInt64,
        onProgress: (ClickHouseProgress) -> Void
    ) throws(ClickHouseError) -> EndOfStreamStep {
        switch packetType {
        case 1, 7, 8:
            try skipDataBlockBodyInternal()
            return .keepReading
        case 2:
            throw .queryFailed(serverException: try readExceptionPacketInternal())
        case 3:
            try absorbProgress(into: &writtenRows, bytes: &writtenBytes, onProgress: onProgress)
            return .keepReading
        case 5:
            return .finished(rows: writtenRows, bytes: writtenBytes)
        case 4:
            return .keepReading
        default:
            try skipNonSchemaPacket(packetType: packetType, stage: "receiveEndOfStream")
            return .keepReading
        }
    }

    private func absorbProgress(
        into writtenRows: inout UInt64,
        bytes writtenBytes: inout UInt64,
        onProgress: (ClickHouseProgress) -> Void
    ) throws(ClickHouseError) {
        let progress = try readProgressPacketInternal()
        onProgress(progress)
        // ClickHouse Progress packets carry the rows/bytes written since
        // the previous packet, not a running total, so a multi-block
        // INSERT reports its written count across several packets. Summing
        // is the only accumulation that yields the true total; taking the
        // maximum would collapse to the largest single increment.
        writtenRows += progress.writtenRows
        writtenBytes += progress.writtenBytes
    }

    internal func skipDataBlockBodyInternal() throws(ClickHouseError) {
        _ = try readStringInternal() // table name
        try skipBlockInternal()
    }
}
