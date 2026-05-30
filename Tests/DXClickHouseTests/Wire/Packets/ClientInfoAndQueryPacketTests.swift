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

@testable import DXClickHouse
import NIOCore
import Testing

@Suite("ClickHouse client info")
struct ClickHouseClientInfoTests {

    @Test("default ClientInfo round-trips at modern revision")
    func defaultClientInfoRoundTripModern() throws {
        let original = ClickHouseClientInfo()
        var buffer = ByteBuffer()
        original.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseClientInfo.decode(from: &buffer, revision: 54_478)
        #expect(decoded == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("ClientInfo with custom values round-trips")
    func customClientInfoRoundTrip() throws {
        var original = ClickHouseClientInfo()
        original.queryKind = .secondaryQuery
        original.initialUser = "admin"
        original.initialQueryID = "query-123"
        original.initialAddress = "192.0.2.1:9000"
        original.initialQueryStartTimeMicroseconds = 1_700_000_000_000_000
        original.osUser = "ubuntu"
        original.clientHostname = "service-1"
        original.clientName = "SwiftDX Test"
        original.clientVersionMajor = 24
        original.clientVersionMinor = 8
        original.clientRevision = 54_478
        original.quotaKey = "tenant-A"
        original.distributedDepth = 3
        original.clientVersionPatch = 7
        original.collaborateWithInitiator = 1
        original.countParticipatingReplicas = 4
        original.numberOfCurrentReplica = 2

        var buffer = ByteBuffer()
        original.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseClientInfo.decode(from: &buffer, revision: 54_478)
        #expect(decoded == original)
    }

    @Test("queryKind == noQuery short-circuits the body and consumes only one byte")
    func noQueryShortCircuits() throws {
        var info = ClickHouseClientInfo()
        info.queryKind = .noQuery
        info.initialUser = "should not be written"

        var buffer = ByteBuffer()
        info.encode(into: &buffer, revision: 54_478)
        #expect(buffer.readableBytes == 1)

        let decoded = try ClickHouseClientInfo.decode(from: &buffer, revision: 54_478)
        #expect(decoded.queryKind == .noQuery)
        #expect(decoded.initialUser == "")
    }

    @Test("legacy revision skips startTime, distributedDepth, traceFlag, parallel replicas")
    func legacyRevisionSkipsModernFields() throws {
        let original = ClickHouseClientInfo()
        var modernBuffer = ByteBuffer()
        original.encode(into: &modernBuffer, revision: 54_478)
        var legacyBuffer = ByteBuffer()
        original.encode(into: &legacyBuffer, revision: 54_400)
        #expect(modernBuffer.readableBytes > legacyBuffer.readableBytes)

        let decoded = try ClickHouseClientInfo.decode(from: &legacyBuffer, revision: 54_400)
        #expect(decoded.queryKind == .initialQuery)
        #expect(decoded.distributedDepth == 0)
    }

    @Test("an unknown query kind raw value surfaces a typed error")
    func unknownQueryKindRejected() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(99))
        #expect(throws: ClickHouseError.unknownClientInfoQueryKind(rawValue: 99)) {
            try ClickHouseClientInfo.decode(from: &buffer, revision: 54_478)
        }
    }

    @Test("a non-zero trace-flag surfaces unimplementedTraceContext rather than misframing")
    func traceContextUnimplementedRejected() {
        var info = ClickHouseClientInfo()
        var buffer = ByteBuffer()
        info.encode(into: &buffer, revision: 54_478)
        // Find the trace-flag byte and flip it. The trace-flag is the byte
        // immediately before the parallel-replicas UVarInts. Easier: just
        // craft a fresh buffer with traceFlag = 1.
        var corrupt = ByteBuffer()
        info.queryKind = .initialQuery
        corrupt.writeInteger(info.queryKind.rawValue)
        corrupt.writeClickHouseString(info.initialUser)
        corrupt.writeClickHouseString(info.initialQueryID)
        corrupt.writeClickHouseString(info.initialAddress)
        corrupt.writeClickHouseFixedWidthInteger(info.initialQueryStartTimeMicroseconds)
        corrupt.writeInteger(info.clientInterface.rawValue)
        corrupt.writeClickHouseString(info.osUser)
        corrupt.writeClickHouseString(info.clientHostname)
        corrupt.writeClickHouseString(info.clientName)
        corrupt.writeClickHouseUVarInt(info.clientVersionMajor)
        corrupt.writeClickHouseUVarInt(info.clientVersionMinor)
        corrupt.writeClickHouseUVarInt(info.clientRevision)
        corrupt.writeClickHouseString(info.quotaKey)
        corrupt.writeClickHouseUVarInt(info.distributedDepth)
        corrupt.writeClickHouseUVarInt(info.clientVersionPatch)
        corrupt.writeInteger(UInt8(1))
        #expect(throws: ClickHouseError.unimplementedTraceContext) {
            try ClickHouseClientInfo.decode(from: &corrupt, revision: 54_478)
        }
    }

}

@Suite("ClickHouse query packet")
struct ClickHouseQueryPacketTests {

    @Test("query packet round-trips with default ClientInfo")
    func queryRoundTripWithDefaults() throws {
        let original = ClickHouseQueryPacket(
            queryID: "abc-123",
            queryText: "SELECT 1"
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseQueryPacket.decode(from: &buffer, revision: 54_478)
        #expect(decoded.queryID == "abc-123")
        #expect(decoded.queryText == "SELECT 1")
        #expect(decoded.queryProcessingStage == .complete)
        #expect(decoded.compression == false)
        #expect(buffer.readableBytes == 0)
    }

    @Test("query packet preserves processing stage and compression flag")
    func nonDefaultStageAndCompressionRoundTrip() throws {
        let original = ClickHouseQueryPacket(
            queryID: "q-9",
            queryProcessingStage: .withMergeableState,
            compression: true,
            queryText: "SELECT count() FROM logs"
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseQueryPacket.decode(from: &buffer, revision: 54_478)
        #expect(decoded.queryProcessingStage == .withMergeableState)
        #expect(decoded.compression == true)
        #expect(decoded.queryText == "SELECT count() FROM logs")
    }

    @Test("empty settings terminator is preserved on the wire")
    func emptySettingsTerminator() throws {
        let original = ClickHouseQueryPacket(queryID: "q", queryText: "SELECT 1")
        var modernBuffer = ByteBuffer()
        try original.encode(into: &modernBuffer, revision: 54_478)
        // The decoder reads a settings list ending with an empty-name
        // terminator. The default packet has no settings, so decode reads
        // the terminator immediately and moves on to the next field.
        let decoded = try ClickHouseQueryPacket.decode(from: &modernBuffer, revision: 54_478)
        #expect(decoded.queryText == "SELECT 1")
    }

    @Test("a properly-encoded settings entry decodes back into the packet's settings list")
    func encodedSettingsEntryDecodes() throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseString("q")
        ClickHouseClientInfo().encode(into: &buffer, revision: 54_478)
        // One setting: name="max_threads", flags=0x01 (important), value="8"
        buffer.writeClickHouseString("max_threads")
        buffer.writeClickHouseUVarInt(0x01)
        buffer.writeClickHouseString("8")
        // Empty-name terminator
        buffer.writeClickHouseString("")
        // Rest of query
        buffer.writeClickHouseString("") // received_extra_roles (revision >= 54_472)
        buffer.writeClickHouseString("") // interserverSecret (revision >= 54_441)
        buffer.writeClickHouseUVarInt(2) // stage
        buffer.writeClickHouseUVarInt(0) // compression off
        buffer.writeClickHouseString("SELECT 1")
        buffer.writeClickHouseString("") // params terminator (revision >= 54_459)
        let decoded = try ClickHouseQueryPacket.decode(from: &buffer, revision: 54_478)
        #expect(decoded.settings.count == 1)
        #expect(decoded.settings[0].name == "max_threads")
        #expect(decoded.settings[0].value == "8")
        #expect(decoded.settings[0].important == true)
    }

    @Test("query packet routes through the client packet writer with the query marker")
    func writerProducesQueryMarker() throws {
        let packet = ClickHouseQueryPacket(queryID: "q", queryText: "SELECT 1")
        var buffer = ByteBuffer()
        try ClickHouseClientPacketWriter.write(.query(packet), into: &buffer, revision: 54_478)

        let type = try ClickHouseClientPacketType.read(from: &buffer)
        #expect(type == .query)
        let decoded = try ClickHouseQueryPacket.decode(from: &buffer, revision: 54_478)
        #expect(decoded.queryID == "q")
        #expect(decoded.queryText == "SELECT 1")
    }

    @Test("revision below interserver-secret threshold omits the secret field")
    func legacyRevisionOmitsInterserverSecret() throws {
        let original = ClickHouseQueryPacket(
            queryID: "q",
            interserverSecret: "should-be-omitted",
            queryText: "SELECT 1"
        )
        var legacyBuffer = ByteBuffer()
        try original.encode(into: &legacyBuffer, revision: 54_400)

        let decoded = try ClickHouseQueryPacket.decode(from: &legacyBuffer, revision: 54_400)
        #expect(decoded.interserverSecret == "")
    }

}
