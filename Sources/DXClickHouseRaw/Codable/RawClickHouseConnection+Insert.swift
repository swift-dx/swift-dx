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

// Low-level INSERT helpers layered on top of the sync RawClickHouseConnection.
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
//     `RawClickHouseBlockWriter`).
//   * `receiveEndOfStream(onProgress:)` drains step 5 and returns
//     the cumulative server-reported rows + bytes.
extension RawClickHouseConnection {

    public struct InsertSchemaColumn: Sendable, Equatable {

        public let name: String
        public let typeName: String

        public init(name: String, typeName: String) {
            self.name = name
            self.typeName = typeName
        }
    }

    public func receiveInsertSampleSchema() throws(RawClickHouseError) -> [InsertSchemaColumn] {
        var schema: [InsertSchemaColumn] = []
        var seenSample = false
        while !seenSample {
            let packetType = try readUVarIntInternal()
            switch packetType {
            case 1:
                schema = try parseSampleBlockHeaderInternal()
                seenSample = true
            case 2:
                let exception = try readExceptionPacketInternal()
                throw .queryFailed(serverException: exception)
            case 3:
                try skipProgressPacketInternal()
            case 6:
                try skipProfileInfoPacketInternal()
            case 10, 14:
                _ = try readStringInternal()
                try skipBlockInternal()
            case 11:
                _ = try readStringInternal()
                _ = try readStringInternal()
            case 17:
                _ = try readStringInternal()
            case 4:
                continue
            default:
                throw .protocolError(stage: "receiveInsertSampleSchema", message: "unexpected packet type \(packetType)")
            }
        }
        return schema
    }

    public func sendRawBytes(_ bytes: [UInt8]) throws(RawClickHouseError) {
        try sendAllWithReconnectInternal(bytes)
    }

    public func receiveEndOfStream(
        onProgress: (RawClickHouseProgress) -> Void = { _ in }
    ) throws(RawClickHouseError) -> (rows: UInt64, bytes: UInt64) {
        var writtenRows: UInt64 = 0
        var writtenBytes: UInt64 = 0
        while true {
            let packetType = try readUVarIntInternal()
            switch packetType {
            case 1, 7, 8:
                try skipDataBlockBodyInternal()
            case 2:
                let exception = try readExceptionPacketInternal()
                throw .queryFailed(serverException: exception)
            case 3:
                let progress = try readProgressPacketInternal()
                onProgress(progress)
                writtenRows = max(writtenRows, progress.writtenRows)
                writtenBytes = max(writtenBytes, progress.writtenBytes)
            case 5:
                return (writtenRows, writtenBytes)
            case 6:
                try skipProfileInfoPacketInternal()
            case 10, 14:
                _ = try readStringInternal()
                try skipBlockInternal()
            case 11:
                _ = try readStringInternal()
                _ = try readStringInternal()
            case 17:
                _ = try readStringInternal()
            case 4:
                continue
            default:
                throw .protocolError(stage: "receiveEndOfStream", message: "unexpected packet type \(packetType)")
            }
        }
    }

    internal func skipDataBlockBodyInternal() throws(RawClickHouseError) {
        _ = try readStringInternal() // table name
        try skipBlockInternal()
    }
}
