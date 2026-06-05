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

    static let minRevisionWithQuotaKeyInClientInfo: UInt64 = 54_060
    static let minRevisionWithVersionPatch: UInt64 = 54_401
    static let minRevisionWithInterserverSecret: UInt64 = 54_441
    static let minRevisionWithOpenTelemetry: UInt64 = 54_442
    static let minRevisionWithDistributedDepth: UInt64 = 54_448
    static let minRevisionWithInitialQueryStartTime: UInt64 = 54_449
    static let minRevisionWithParallelReplicas: UInt64 = 54_453
    static let minRevisionWithAddendum: UInt64 = 54_458
    static let minRevisionWithChunkedPackets: UInt64 = 54_470
    static let minRevisionWithRolesInClientInfo: UInt64 = 54_472
    static let minRevisionWithQueryAndLineNumbers: UInt64 = 54_475
    static let minRevisionWithJWTInInterserver: UInt64 = 54_476

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
    // Every field is gated on the revision the server advertised, mirroring
    // exactly what that server reads back: a server below
    // minRevisionWithAddendum (54458) never reads an addendum, so none is
    // sent; the send/recv chunked-framing strings exist only from
    // minRevisionWithChunkedPackets (54470). Sending an ungated addendum to
    // an older server leaves the extra bytes in the server's buffer, which
    // it then misreads as the next packet and desyncs the connection at the
    // first query. The thresholds all sit below the client revision, so
    // gating on the server's advertised revision equals gating on the
    // negotiated minimum.
    public static func buildAddendum(serverRevision: UInt64) -> [UInt8] {
        var output: [UInt8] = []
        if serverRevision < minRevisionWithAddendum {
            return output
        }
        output.reserveCapacity(48)
        ClickHouseWire.writeString("", into: &output) // quota key
        if serverRevision >= minRevisionWithChunkedPackets {
            ClickHouseWire.writeString("notchunked", into: &output)
            ClickHouseWire.writeString("notchunked", into: &output)
        }
        ClickHouseWire.writeUVarInt(0, into: &output) // parallel replicas protocol version
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
        encodeClientInfo(into: &output, revision: revision)
        try settings.encode(into: &output)
        appendGated(revision, atLeast: minRevisionWithRolesInClientInfo, into: &output) {
            ClickHouseWire.writeString("", into: &$0) // externally granted roles
        }
        appendGated(revision, atLeast: minRevisionWithInterserverSecret, into: &output) {
            ClickHouseWire.writeString("", into: &$0) // interserver secret
        }
        ClickHouseWire.writeUVarInt(2, into: &output) // stage: Complete
        ClickHouseWire.writeUVarInt(0, into: &output) // compression off
        ClickHouseWire.writeString(sql, into: &output)
        try parameters.encode(into: &output, revision: revision)
        appendEmptyDataPacket(into: &output)
    }

    // Emits a wire field only when the negotiated protocol revision is at
    // least the revision that introduced it. Below that, the server does
    // not read the field, so emitting it would desync the packet stream.
    private static func appendGated(
        _ revision: UInt64,
        atLeast introduced: UInt64,
        into output: inout [UInt8],
        _ body: (inout [UInt8]) -> Void
    ) {
        if revision >= introduced {
            body(&output)
        }
    }

    static func encodeClientInfo(into output: inout [UInt8], revision: UInt64) {
        output.append(1) // queryKind: initialQuery
        ClickHouseWire.writeString("", into: &output) // initialUser
        ClickHouseWire.writeString("", into: &output) // initialQueryID
        ClickHouseWire.writeString("127.0.0.1:0", into: &output) // initialAddress
        appendGated(revision, atLeast: minRevisionWithInitialQueryStartTime, into: &output) {
            ClickHouseWire.writeFixedInt(Int64(0), into: &$0) // initialQueryStartTimeMicroseconds
        }
        output.append(1) // interface: TCP
        ClickHouseWire.writeString("", into: &output) // osUser
        ClickHouseWire.writeString("", into: &output) // clientHostname
        ClickHouseWire.writeString("SwiftDX Raw", into: &output) // clientName
        ClickHouseWire.writeUVarInt(1, into: &output) // clientVersionMajor
        ClickHouseWire.writeUVarInt(0, into: &output) // clientVersionMinor
        ClickHouseWire.writeUVarInt(revision, into: &output) // clientTcpProtocolVersion
        appendGated(revision, atLeast: minRevisionWithQuotaKeyInClientInfo, into: &output) {
            ClickHouseWire.writeString("", into: &$0) // quota key
        }
        appendGated(revision, atLeast: minRevisionWithDistributedDepth, into: &output) {
            ClickHouseWire.writeUVarInt(0, into: &$0) // distributedDepth
        }
        appendGated(revision, atLeast: minRevisionWithVersionPatch, into: &output) {
            ClickHouseWire.writeUVarInt(0, into: &$0) // clientVersionPatch
        }
        appendGated(revision, atLeast: minRevisionWithOpenTelemetry, into: &output) {
            $0.append(0) // trace flag: no OpenTelemetry context
        }
        appendGated(revision, atLeast: minRevisionWithParallelReplicas, into: &output) {
            ClickHouseWire.writeUVarInt(0, into: &$0) // collaborateWithInitiator
            ClickHouseWire.writeUVarInt(0, into: &$0) // countParticipatingReplicas
            ClickHouseWire.writeUVarInt(0, into: &$0) // numberOfCurrentReplica
        }
        appendGated(revision, atLeast: minRevisionWithQueryAndLineNumbers, into: &output) {
            ClickHouseWire.writeUVarInt(0, into: &$0) // queryNumberOfRows
            ClickHouseWire.writeUVarInt(0, into: &$0) // queryNumberOfLines
        }
        appendGated(revision, atLeast: minRevisionWithJWTInInterserver, into: &output) {
            $0.append(0) // haveJWT
        }
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
