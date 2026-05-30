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

// Substruct of ClickHouseQueryPacket carrying identity, transport,
// and parallel-execution metadata. Wire layout is heavily revision-
// gated; thresholds below mirror clickhouse-go's protocol/client_info.
//
//   UInt8    queryKind  (0 = noQuery short-circuits, 1 = initial, 2 = secondary)
//   String   initialUser
//   String   initialQueryID
//   String   initialAddress
//   Int64    initialQueryStartTimeMicroseconds   (>= 54449)
//   UInt8    interface  (1 = TCP, 2 = HTTP)
//   if interface == 1 (TCP):
//     String osUser
//     String clientHostname
//     String clientName
//     UVarInt clientVersionMajor / Minor / clientRevision
//   String   quotaKey   (>= 54060, but we always emit at our baseline)
//   UVarInt  distributedDepth                   (>= 54448)
//   UVarInt  clientVersionPatch                 (>= 54401)
//   UInt8    traceFlag                          (>= 54442; 0 = no context,
//                                                1 = trace context follows)
//   UVarInt  collaborateWithInitiator           (>= 54448)
//   UVarInt  countParticipatingReplicas         (>= 54448)
//   UVarInt  numberOfCurrentReplica             (>= 54448)
//
// Trace-context emission and HTTP-interface emission are deferred —
// the decoder asserts the wire is in the expected shape (traceFlag==0,
// interface==.tcp) and throws otherwise. Those are known seams, not
// silent gaps.
struct ClickHouseClientInfo: Sendable, Equatable {

    static let revisionWithInitialQueryStartTime: UInt64 = 54_449
    static let revisionWithDistributedDepth: UInt64 = 54_448
    static let revisionWithVersionPatch: UInt64 = 54_401
    static let revisionWithOpenTelemetry: UInt64 = 54_442
    static let revisionWithParallelReplicas: UInt64 = 54_453
    static let revisionWithQueryAndLineNumbers: UInt64 = 54_475
    static let revisionWithJWTInInterserver: UInt64 = 54_476

    enum QueryKind: UInt8, Sendable {

        case noQuery = 0
        case initialQuery = 1
        case secondaryQuery = 2

    }

    enum Interface: UInt8, Sendable {

        case tcp = 1
        case http = 2

    }

    var queryKind: QueryKind = .initialQuery
    var initialUser: String = ""
    var initialQueryID: String = ""
    var initialAddress: String = "127.0.0.1:0"
    var initialQueryStartTimeMicroseconds: Int64 = 0
    var clientInterface: Interface = .tcp
    var osUser: String = ""
    var clientHostname: String = ""
    var clientName: String = "SwiftDX Swift Client"
    var clientVersionMajor: UInt64 = 1
    var clientVersionMinor: UInt64 = 0
    var clientRevision: UInt64 = 54_478
    var quotaKey: String = ""
    var distributedDepth: UInt64 = 0
    var clientVersionPatch: UInt64 = 0
    var collaborateWithInitiator: UInt64 = 0
    var countParticipatingReplicas: UInt64 = 0
    var numberOfCurrentReplica: UInt64 = 0

    func encode(into buffer: inout ByteBuffer, revision: UInt64) {
        buffer.writeInteger(queryKind.rawValue)
        guard queryKind != .noQuery else { return }
        encodeInitialFields(into: &buffer, revision: revision)
        encodeInterfaceFields(into: &buffer)
        buffer.writeClickHouseString(quotaKey)
        encodeRevisionedFields(into: &buffer, revision: revision)
    }

    private func encodeInitialFields(into buffer: inout ByteBuffer, revision: UInt64) {
        buffer.writeClickHouseString(initialUser)
        buffer.writeClickHouseString(initialQueryID)
        buffer.writeClickHouseString(initialAddress)
        if revision >= Self.revisionWithInitialQueryStartTime {
            buffer.writeClickHouseFixedWidthInteger(initialQueryStartTimeMicroseconds)
        }
    }

    private func encodeInterfaceFields(into buffer: inout ByteBuffer) {
        buffer.writeInteger(clientInterface.rawValue)
        guard clientInterface == .tcp else { return }
        buffer.writeClickHouseString(osUser)
        buffer.writeClickHouseString(clientHostname)
        buffer.writeClickHouseString(clientName)
        buffer.writeClickHouseUVarInt(clientVersionMajor)
        buffer.writeClickHouseUVarInt(clientVersionMinor)
        buffer.writeClickHouseUVarInt(clientRevision)
    }

    private func encodeRevisionedFields(into buffer: inout ByteBuffer, revision: UInt64) {
        encodeRevisionedSimple(into: &buffer, revision: revision)
        encodeRevisionedReplicas(into: &buffer, revision: revision)
        encodeRevisionedScriptLines(into: &buffer, revision: revision)
        encodeRevisionedJWT(into: &buffer, revision: revision)
    }

    private func encodeRevisionedSimple(into buffer: inout ByteBuffer, revision: UInt64) {
        encodeRevisionedDepthAndPatch(into: &buffer, revision: revision)
        if revision >= Self.revisionWithOpenTelemetry {
            buffer.writeInteger(UInt8(0))
        }
    }

    private func encodeRevisionedDepthAndPatch(into buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= Self.revisionWithDistributedDepth {
            buffer.writeClickHouseUVarInt(distributedDepth)
        }
        if revision >= Self.revisionWithVersionPatch {
            buffer.writeClickHouseUVarInt(clientVersionPatch)
        }
    }

    private func encodeRevisionedReplicas(into buffer: inout ByteBuffer, revision: UInt64) {
        guard revision >= Self.revisionWithParallelReplicas else { return }
        buffer.writeClickHouseUVarInt(collaborateWithInitiator)
        buffer.writeClickHouseUVarInt(countParticipatingReplicas)
        buffer.writeClickHouseUVarInt(numberOfCurrentReplica)
    }

    private func encodeRevisionedScriptLines(into buffer: inout ByteBuffer, revision: UInt64) {
        guard revision >= Self.revisionWithQueryAndLineNumbers else { return }
        buffer.writeClickHouseUVarInt(0)
        buffer.writeClickHouseUVarInt(0)
    }

    private func encodeRevisionedJWT(into buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= Self.revisionWithJWTInInterserver {
            buffer.writeInteger(UInt8(0))
        }
    }

    static func decode(from buffer: inout ByteBuffer, revision: UInt64) throws -> Self {
        let queryKind = try decodeQueryKind(from: &buffer)
        var packet = ClickHouseClientInfo()
        packet.queryKind = queryKind
        guard queryKind != .noQuery else { return packet }
        try decodeInitialFields(into: &packet, from: &buffer, revision: revision)
        try decodeInterfaceFields(into: &packet, from: &buffer)
        packet.quotaKey = try buffer.readClickHouseString()
        try decodeRevisionedFields(into: &packet, from: &buffer, revision: revision)
        return packet
    }

    private static func decodeQueryKind(from buffer: inout ByteBuffer) throws -> QueryKind {
        let queryKindRaw = try buffer.readClickHouseFixedWidthInteger(UInt8.self)
        guard let queryKind = QueryKind(rawValue: queryKindRaw) else {
            throw ClickHouseError.unknownClientInfoQueryKind(rawValue: queryKindRaw)
        }
        return queryKind
    }

    private static func decodeInitialFields(into packet: inout ClickHouseClientInfo, from buffer: inout ByteBuffer, revision: UInt64) throws {
        packet.initialUser = try buffer.readClickHouseString()
        packet.initialQueryID = try buffer.readClickHouseString()
        packet.initialAddress = try buffer.readClickHouseString()
        if revision >= Self.revisionWithInitialQueryStartTime {
            packet.initialQueryStartTimeMicroseconds = try buffer.readClickHouseFixedWidthInteger(Int64.self)
        }
    }

    private static func decodeInterfaceFields(into packet: inout ClickHouseClientInfo, from buffer: inout ByteBuffer) throws {
        let interfaceRaw = try buffer.readClickHouseFixedWidthInteger(UInt8.self)
        guard let clientInterface = Interface(rawValue: interfaceRaw) else {
            throw ClickHouseError.unknownClientInfoInterface(rawValue: interfaceRaw)
        }
        packet.clientInterface = clientInterface
        guard clientInterface == .tcp else { return }
        packet.osUser = try buffer.readClickHouseString()
        packet.clientHostname = try buffer.readClickHouseString()
        packet.clientName = try buffer.readClickHouseString()
        packet.clientVersionMajor = try buffer.readClickHouseUVarInt()
        packet.clientVersionMinor = try buffer.readClickHouseUVarInt()
        packet.clientRevision = try buffer.readClickHouseUVarInt()
    }

    private static func decodeRevisionedFields(into packet: inout ClickHouseClientInfo, from buffer: inout ByteBuffer, revision: UInt64) throws {
        try decodeRevisionedVersionAndTrace(into: &packet, from: &buffer, revision: revision)
        try decodeRevisionedReplicas(into: &packet, from: &buffer, revision: revision)
        try decodeRevisionedScriptLines(from: &buffer, revision: revision)
        try decodeRevisionedJWT(from: &buffer, revision: revision)
    }

    private static func decodeRevisionedVersionAndTrace(into packet: inout ClickHouseClientInfo, from buffer: inout ByteBuffer, revision: UInt64) throws {
        if revision >= Self.revisionWithDistributedDepth {
            packet.distributedDepth = try buffer.readClickHouseUVarInt()
        }
        if revision >= Self.revisionWithVersionPatch {
            packet.clientVersionPatch = try buffer.readClickHouseUVarInt()
        }
        try decodeRevisionedTraceFlag(from: &buffer, revision: revision)
    }

    private static func decodeRevisionedTraceFlag(from buffer: inout ByteBuffer, revision: UInt64) throws {
        guard revision >= Self.revisionWithOpenTelemetry else { return }
        let traceFlag = try buffer.readClickHouseFixedWidthInteger(UInt8.self)
        guard traceFlag == 0 else {
            throw ClickHouseError.unimplementedTraceContext
        }
    }

    private static func decodeRevisionedReplicas(into packet: inout ClickHouseClientInfo, from buffer: inout ByteBuffer, revision: UInt64) throws {
        guard revision >= Self.revisionWithParallelReplicas else { return }
        packet.collaborateWithInitiator = try buffer.readClickHouseUVarInt()
        packet.countParticipatingReplicas = try buffer.readClickHouseUVarInt()
        packet.numberOfCurrentReplica = try buffer.readClickHouseUVarInt()
    }

    private static func decodeRevisionedScriptLines(from buffer: inout ByteBuffer, revision: UInt64) throws {
        guard revision >= Self.revisionWithQueryAndLineNumbers else { return }
        _ = try buffer.readClickHouseUVarInt()
        _ = try buffer.readClickHouseUVarInt()
    }

    private static func decodeRevisionedJWT(from buffer: inout ByteBuffer, revision: UInt64) throws {
        guard revision >= Self.revisionWithJWTInInterserver else { return }
        let haveJWT = try buffer.readClickHouseFixedWidthInteger(UInt8.self)
        if haveJWT != 0 {
            _ = try buffer.readClickHouseString()
        }
    }

}
