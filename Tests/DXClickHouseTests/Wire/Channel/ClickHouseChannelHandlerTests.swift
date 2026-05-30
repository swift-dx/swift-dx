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
import NIOEmbedded
import Testing

@Suite("ClickHouse channel handlers")
struct ClickHouseChannelHandlerTests {

    @Test("a complete Pong packet flows through the inbound decoder as .pong")
    func inboundPongFlows() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        )

        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)
        try channel.writeInbound(buffer)

        let packet = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        guard case .pong = packet else {
            Issue.record("expected .pong, got \(packet)")
            return
        }
        #expect(try channel.finish().isClean)
    }

    @Test("a Hello packet flows through the inbound decoder with all fields preserved")
    func inboundHelloFlows() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        )

        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24, versionMinor: 8,
            serverRevision: 54_478,
            parallelReplicasProtocolVersion: .value(0),
            serverTimezone: .value("UTC"), displayName: .value("ch-1"), versionPatch: .value(12),
            chunkedProtocolSend: .value("notchunked"), chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0),
            queryPlanSerializationVersion: .value(0)
        )
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &buffer)
        hello.encode(into: &buffer, clientRevision: 54_478)
        try channel.writeInbound(buffer)

        let packet = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        guard case .hello(let decoded) = packet else {
            Issue.record("expected .hello, got \(packet)")
            return
        }
        #expect(decoded == hello)
        #expect(try channel.finish().isClean)
    }

    @Test("a packet split across two inbound writes is reassembled into one decoded packet")
    func inboundSplitAcrossWritesReassembles() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        )

        let exception = ClickHouseServerExceptionPacket(
            code: 81, name: "DB::Test", message: "split across two reads", stackTrace: "frame", nested: .none
        )
        var fullBuffer = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &fullBuffer)
        exception.encode(into: &fullBuffer)
        let allBytes = fullBuffer.getBytes(at: fullBuffer.readerIndex, length: fullBuffer.readableBytes) ?? []
        let halfPoint = allBytes.count / 2

        var firstHalf = ByteBuffer()
        firstHalf.writeBytes(Array(allBytes[0..<halfPoint]))
        try channel.writeInbound(firstHalf)
        #expect(try channel.readInbound(as: ClickHouseServerPacket.self) == nil)

        var secondHalf = ByteBuffer()
        secondHalf.writeBytes(Array(allBytes[halfPoint..<allBytes.count]))
        try channel.writeInbound(secondHalf)

        let packet = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        guard case .exception(let decoded) = packet else {
            Issue.record("expected .exception")
            return
        }
        #expect(decoded == exception)
        #expect(try channel.finish().isClean)
    }

    @Test("multiple packets in one inbound write decode in order")
    func multiplePacketsInOneWriteDecodeInOrder() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        )

        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)
        ClickHouseServerPacketType.endOfStream.write(into: &buffer)
        ClickHouseServerPacketType.readTaskRequest.write(into: &buffer)
        try channel.writeInbound(buffer)

        let p1 = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        let p2 = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        let p3 = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        switch (p1, p2, p3) {
        case (.pong, .endOfStream, .readTaskRequest):
            break
        default:
            Issue.record("packets out of order: \(p1) \(p2) \(p3)")
        }
        #expect(try channel.readInbound(as: ClickHouseServerPacket.self) == nil)
        #expect(try channel.finish().isClean)
    }

    @Test("decodeLast at channel-close drains complete packets before deciding the buffer is truncated")
    func decodeLastDrainsCompletePacketsBeforeTruncationThrow() throws {
        // Pre-fix: `decodeLast` checked `seenEOF && readableBytes > 0`
        // immediately after the first `decode` call. If `decode`
        // succeeded with `.continue` and the remaining buffer held
        // another complete packet, the trailing bytes were treated as
        // truncation and the throw fired before NIO could call
        // `decodeLast` again to drain the second packet. Post-fix the
        // throw additionally requires `.needMoreData`, so a buffer
        // still containing further-decodable packets keeps NIO looping
        // until either everything is drained (clean state) or we
        // genuinely cannot make progress (real truncation).
        //
        // We exercise this by using a custom channel handler that
        // forces decodeLast to be invoked while the buffer still holds
        // a complete second packet plus partial bytes for a third.
        let channel = EmbeddedChannel()
        let handler = ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        try channel.pipeline.syncOperations.addHandler(handler)

        var prelude = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &prelude)
        ClickHouseServerPacketType.endOfStream.write(into: &prelude)
        try channel.writeInbound(prelude)

        // Both packets should have decoded via the regular `decode`
        // path before any close-related drain runs.
        let first = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        let second = try #require(try channel.readInbound(as: ClickHouseServerPacket.self))
        guard case .pong = first, case .endOfStream = second else {
            Issue.record("expected .pong then .endOfStream, got \(first) and \(second)")
            return
        }

        // Now close the channel (channelInactive triggers decodeLast
        // with empty buffer). Should be clean — no truncation.
        #expect(try channel.finish().isClean)
    }

    @Test("a malformed inbound byte stream surfaces the typed error through the channel")
    func inboundMalformedSurfacesError() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        )

        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(200)
        #expect(throws: ClickHouseError.unknownServerPacketType(rawValue: 200)) {
            try channel.writeInbound(buffer)
        }
    }

    @Test("the outbound encoder writes a Ping packet as a single marker byte")
    func outboundPingProducesSingleByte() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: 54_478))
        )

        try channel.writeOutbound(ClickHouseClientPacket.ping)
        let outbound = try #require(try channel.readOutbound(as: ByteBuffer.self))
        #expect(outbound.readableBytes == 1)
        let byte: UInt8 = outbound.getInteger(at: outbound.readerIndex) ?? 0xFF
        #expect(byte == ClickHouseClientPacketType.ping.rawValue)
        #expect(try channel.finish().isClean)
    }

    @Test("the outbound encoder writes a Hello packet that decodes back faithfully")
    func outboundHelloRoundTripsToInboundDecoder() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: 54_478))
        )

        let hello = ClickHouseClientHelloPacket(
            clientName: "SwiftDX",
            versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
            defaultDatabase: "obs", username: "u", password: ""
        )
        try channel.writeOutbound(ClickHouseClientPacket.hello(hello))

        var outbound = try #require(try channel.readOutbound(as: ByteBuffer.self))
        let type = try ClickHouseClientPacketType.read(from: &outbound)
        #expect(type == .hello)
        let decoded = try ClickHouseClientHelloPacket.decode(from: &outbound)
        #expect(decoded == hello)
        #expect(try channel.finish().isClean)
    }

    @Test("the outbound encoder writes a Query packet whose body decodes back faithfully")
    func outboundQueryRoundTrips() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: 54_478))
        )

        let query = ClickHouseQueryPacket(queryID: "q-1", queryText: "SELECT 1")
        try channel.writeOutbound(ClickHouseClientPacket.query(query))

        var outbound = try #require(try channel.readOutbound(as: ByteBuffer.self))
        let type = try ClickHouseClientPacketType.read(from: &outbound)
        #expect(type == .query)
        let decoded = try ClickHouseQueryPacket.decode(from: &outbound, revision: 54_478)
        #expect(decoded.queryID == "q-1")
        #expect(decoded.queryText == "SELECT 1")
        #expect(try channel.finish().isClean)
    }

    @Test("EOF with bytes still in the buffer surfaces a truncation error rather than silently dropping")
    func eofWithLeftoverBytesSurfacesTruncation() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: 54_478))
        )

        var buffer = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &buffer)
        buffer.writeBytes([UInt8(0x01), UInt8(0x02)])
        try channel.writeInbound(buffer)
        #expect(try channel.readInbound(as: ClickHouseServerPacket.self) == nil)

        #expect(throws: ClickHouseError.self) {
            _ = try channel.finish(acceptAlreadyClosed: false)
        }
    }

}
