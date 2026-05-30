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
// statement into a single [UInt8] buffer. No NIO, no async; the caller
// hands the buffer to send().
//
// Wire layout (matching what Sources/DXClickHouse emits at the
// negotiated revision used by ClickHouseConnection):
//
//   UVarInt packetType = 1 (Query)
//   String  queryID
//   ClientInfo block (see encodeClientInfo)
//   Settings list — sequence of (name, flags, value) triples + empty
//                   terminator
//   String  externallyGrantedRoles = ""  (revision >= 54472)
//   String  interserverSecret = ""        (revision >= 54441)
//   UVarInt stage = 2 (Complete)
//   UVarInt compression = 0
//   String  queryText
//   Parameters list — sequence of (name, customFlag, value) triples +
//                     empty terminator                    (>= 54459)
//   Empty Data packet to signal "no inline data follows":
//     UVarInt packetType = 2 (Data)
//     String  table = ""
//     BlockInfo: 1, 0, 2, -1 (int32 little-endian), 0
//     UVarInt columnCount = 0
//     UVarInt rowCount = 0
public enum ClickHouseQueryBuilder {

    public static let revision: UInt64 = 54_478

    public static func buildHello(database: String, user: String, password: String) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(256)
        ClickHouseWire.writeUVarInt(0, into: &output) // packet type: Hello
        ClickHouseWire.writeString("SwiftDX Raw", into: &output)
        ClickHouseWire.writeUVarInt(1, into: &output) // major
        ClickHouseWire.writeUVarInt(0, into: &output) // minor
        ClickHouseWire.writeUVarInt(revision, into: &output)
        ClickHouseWire.writeString(database, into: &output)
        ClickHouseWire.writeString(user, into: &output)
        ClickHouseWire.writeString(password, into: &output)
        return output
    }

    // Sent immediately after the client Hello (no packet-type marker).
    // Quota key, send-chunked, recv-chunked, parallel-replicas version.
    public static func buildAddendum() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(48)
        ClickHouseWire.writeString("", into: &output) // quota key
        ClickHouseWire.writeString("notchunked", into: &output)
        ClickHouseWire.writeString("notchunked", into: &output)
        ClickHouseWire.writeUVarInt(0, into: &output) // parallel replicas proto
        return output
    }

    // Backwards-compatible shorthand for the no-settings,
    // no-parameters, blank-query-id case used by the original POSIX
    // floor benchmarks and smoke tests.
    public static func buildQuery(_ sql: String) -> [UInt8] {
        var output: [UInt8] = []
        do {
            try writeQuery(
                sql,
                queryID: "",
                settings: .empty,
                parameters: .empty,
                revision: revision,
                into: &output
            )
        } catch {
            // The empty settings / parameters path cannot throw — encode
            // only validates non-empty names. Re-emit an empty buffer in
            // the impossible-state branch.
            output.removeAll(keepingCapacity: false)
        }
        return output
    }

    // Full Query packet builder used by the production surface. Caller
    // provides query ID, settings, and parameters; the builder applies
    // revision-gated field skipping (parameters only emit for
    // revision >= 54_459).
    public static func buildQuery(
        _ sql: String,
        queryID: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters,
        revision: UInt64
    ) throws(ClickHouseError) -> [UInt8] {
        var output: [UInt8] = []
        try writeQuery(
            sql,
            queryID: queryID,
            settings: settings,
            parameters: parameters,
            revision: revision,
            into: &output
        )
        return output
    }

    // Ping packet. Two bytes: UVarInt packetType = 4 (Ping). Used by
    // pool preflight to validate a recycled connection before handing
    // it back to a caller.
    public static func buildPing() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(2)
        ClickHouseWire.writeUVarInt(4, into: &output)
        return output
    }

    // Cancel packet. Single UVarInt = 3. Used by callers that abandon a
    // SELECT stream mid-flight to instruct the server to stop emitting
    // result blocks.
    public static func buildCancel() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(2)
        ClickHouseWire.writeUVarInt(3, into: &output)
        return output
    }

    private static func writeQuery(
        _ sql: String,
        queryID: String,
        settings: ClickHouseQuerySettings,
        parameters: ClickHouseQueryParameters,
        revision: UInt64,
        into output: inout [UInt8]
    ) throws(ClickHouseError) {
        output.reserveCapacity(sql.utf8.count + 256 + settings.count * 64 + parameters.count * 64)
        ClickHouseWire.writeUVarInt(1, into: &output) // packet type: Query
        ClickHouseWire.writeString(queryID, into: &output)
        encodeClientInfo(into: &output)
        try settings.encode(into: &output)
        ClickHouseWire.writeString("", into: &output) // externally granted roles
        ClickHouseWire.writeString("", into: &output) // interserver secret
        ClickHouseWire.writeUVarInt(2, into: &output) // stage: Complete
        ClickHouseWire.writeUVarInt(0, into: &output) // compression off
        ClickHouseWire.writeString(sql, into: &output)
        try parameters.encode(into: &output, revision: revision)
        appendEmptyDataPacket(into: &output)
    }

    static func encodeClientInfo(into output: inout [UInt8]) {
        output.append(1) // queryKind: initialQuery
        ClickHouseWire.writeString("", into: &output) // initialUser
        ClickHouseWire.writeString("", into: &output) // initialQueryID
        ClickHouseWire.writeString("127.0.0.1:0", into: &output) // initialAddress
        ClickHouseWire.writeFixedInt(Int64(0), into: &output) // initialQueryStartTimeMicroseconds (>= 54449)
        output.append(1) // interface: TCP
        ClickHouseWire.writeString("", into: &output) // osUser
        ClickHouseWire.writeString("", into: &output) // clientHostname
        ClickHouseWire.writeString("SwiftDX Raw", into: &output)
        ClickHouseWire.writeUVarInt(1, into: &output) // clientVersionMajor
        ClickHouseWire.writeUVarInt(0, into: &output) // clientVersionMinor
        ClickHouseWire.writeUVarInt(revision, into: &output)
        ClickHouseWire.writeString("", into: &output) // quota key
        ClickHouseWire.writeUVarInt(0, into: &output) // distributedDepth (>= 54448)
        ClickHouseWire.writeUVarInt(0, into: &output) // clientVersionPatch (>= 54401)
        output.append(0) // trace flag (>= 54442)
        ClickHouseWire.writeUVarInt(0, into: &output) // collaborateWithInitiator (>= 54453)
        ClickHouseWire.writeUVarInt(0, into: &output) // countParticipatingReplicas
        ClickHouseWire.writeUVarInt(0, into: &output) // numberOfCurrentReplica
        ClickHouseWire.writeUVarInt(0, into: &output) // queryNumberOfRows (>= 54475)
        ClickHouseWire.writeUVarInt(0, into: &output) // queryNumberOfLines
        output.append(0) // haveJWT (>= 54476)
    }

    static func appendEmptyDataPacket(into output: inout [UInt8]) {
        ClickHouseWire.writeUVarInt(2, into: &output) // packet type: Data
        ClickHouseWire.writeString("", into: &output) // table name
        // BlockInfo
        ClickHouseWire.writeUVarInt(1, into: &output)
        output.append(0) // isOverflows = false
        ClickHouseWire.writeUVarInt(2, into: &output)
        ClickHouseWire.writeFixedInt(Int32(-1), into: &output)
        ClickHouseWire.writeUVarInt(0, into: &output)
        // Column count + row count.
        ClickHouseWire.writeUVarInt(0, into: &output)
        ClickHouseWire.writeUVarInt(0, into: &output)
    }
}
