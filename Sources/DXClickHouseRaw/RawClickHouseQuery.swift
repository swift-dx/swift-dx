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

// Synchronous Query packet builder. Builds the raw bytes for one
// SELECT into a single [UInt8] buffer. No NIO, no async; the caller
// hands the buffer to send().
//
// Wire layout (matching what Sources/DXClickHouse emits at the
// negotiated revision used by RawClickHouseConnection):
//
//   UVarInt packetType = 1 (Query)
//   String  queryID = ""
//   ClientInfo block (see encodeClientInfo)
//   String  settings terminator = ""
//   String  externallyGrantedRoles = ""  (revision >= 54472)
//   String  interserverSecret = ""        (revision >= 54441)
//   UVarInt stage = 2 (Complete)
//   UVarInt compression = 0
//   String  queryText
//   String  parameters terminator = ""    (revision >= 54459)
//   Empty Data packet to signal "no inline data follows":
//     UVarInt packetType = 2 (Data)
//     String  table = ""
//     BlockInfo: 1, 0, 2, -1 (int32 little-endian), 0
//     UVarInt columnCount = 0
//     UVarInt rowCount = 0
public enum RawClickHouseQueryBuilder {

    public static let revision: UInt64 = 54_478

    public static func buildHello(database: String, user: String, password: String) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(256)
        RawClickHouseWire.writeUVarInt(0, into: &output) // packet type: Hello
        RawClickHouseWire.writeString("SwiftDX Raw", into: &output)
        RawClickHouseWire.writeUVarInt(1, into: &output) // major
        RawClickHouseWire.writeUVarInt(0, into: &output) // minor
        RawClickHouseWire.writeUVarInt(revision, into: &output)
        RawClickHouseWire.writeString(database, into: &output)
        RawClickHouseWire.writeString(user, into: &output)
        RawClickHouseWire.writeString(password, into: &output)
        return output
    }

    // Sent immediately after the client Hello (no packet-type marker).
    // Quota key, send-chunked, recv-chunked, parallel-replicas version.
    public static func buildAddendum() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(48)
        RawClickHouseWire.writeString("", into: &output) // quota key
        RawClickHouseWire.writeString("notchunked", into: &output)
        RawClickHouseWire.writeString("notchunked", into: &output)
        RawClickHouseWire.writeUVarInt(0, into: &output) // parallel replicas proto
        return output
    }

    public static func buildQuery(_ sql: String) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(sql.utf8.count + 256)
        RawClickHouseWire.writeUVarInt(1, into: &output) // packet type: Query
        RawClickHouseWire.writeString("", into: &output) // query id
        encodeClientInfo(into: &output)
        RawClickHouseWire.writeString("", into: &output) // settings terminator
        RawClickHouseWire.writeString("", into: &output) // externally granted roles
        RawClickHouseWire.writeString("", into: &output) // interserver secret
        RawClickHouseWire.writeUVarInt(2, into: &output) // stage: Complete
        RawClickHouseWire.writeUVarInt(0, into: &output) // compression off
        RawClickHouseWire.writeString(sql, into: &output)
        RawClickHouseWire.writeString("", into: &output) // parameters terminator
        appendEmptyDataPacket(into: &output)
        return output
    }

    static func encodeClientInfo(into output: inout [UInt8]) {
        output.append(1) // queryKind: initialQuery
        RawClickHouseWire.writeString("", into: &output) // initialUser
        RawClickHouseWire.writeString("", into: &output) // initialQueryID
        RawClickHouseWire.writeString("127.0.0.1:0", into: &output) // initialAddress
        RawClickHouseWire.writeFixedInt(Int64(0), into: &output) // initialQueryStartTimeMicroseconds (>= 54449)
        output.append(1) // interface: TCP
        RawClickHouseWire.writeString("", into: &output) // osUser
        RawClickHouseWire.writeString("", into: &output) // clientHostname
        RawClickHouseWire.writeString("SwiftDX Raw", into: &output)
        RawClickHouseWire.writeUVarInt(1, into: &output) // clientVersionMajor
        RawClickHouseWire.writeUVarInt(0, into: &output) // clientVersionMinor
        RawClickHouseWire.writeUVarInt(revision, into: &output)
        RawClickHouseWire.writeString("", into: &output) // quota key
        RawClickHouseWire.writeUVarInt(0, into: &output) // distributedDepth (>= 54448)
        RawClickHouseWire.writeUVarInt(0, into: &output) // clientVersionPatch (>= 54401)
        output.append(0) // trace flag (>= 54442)
        RawClickHouseWire.writeUVarInt(0, into: &output) // collaborateWithInitiator (>= 54453)
        RawClickHouseWire.writeUVarInt(0, into: &output) // countParticipatingReplicas
        RawClickHouseWire.writeUVarInt(0, into: &output) // numberOfCurrentReplica
        RawClickHouseWire.writeUVarInt(0, into: &output) // queryNumberOfRows (>= 54475)
        RawClickHouseWire.writeUVarInt(0, into: &output) // queryNumberOfLines
        output.append(0) // haveJWT (>= 54476)
    }

    static func appendEmptyDataPacket(into output: inout [UInt8]) {
        RawClickHouseWire.writeUVarInt(2, into: &output) // packet type: Data
        RawClickHouseWire.writeString("", into: &output) // table name
        // BlockInfo
        RawClickHouseWire.writeUVarInt(1, into: &output)
        output.append(0) // isOverflows = false
        RawClickHouseWire.writeUVarInt(2, into: &output)
        RawClickHouseWire.writeFixedInt(Int32(-1), into: &output)
        RawClickHouseWire.writeUVarInt(0, into: &output)
        // Column count + row count.
        RawClickHouseWire.writeUVarInt(0, into: &output)
        RawClickHouseWire.writeUVarInt(0, into: &output)
    }
}
