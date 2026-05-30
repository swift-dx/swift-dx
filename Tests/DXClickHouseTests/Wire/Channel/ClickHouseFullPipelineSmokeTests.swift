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

// End-to-end smoke tests that drive a full client/server conversation
// through every layer the codebase has built so far — handshake state
// machine, packet codecs, framing helper, connection wrapper, channel
// handlers, inbound stream handler, query lifecycle. One EmbeddedChannel
// represents the wire; the test code drives both client and server
// roles by sending typed packets through the connection and feeding
// simulated-server bytes back through `writeInbound`.
//
// This is the integration coverage no isolated unit test provides: a
// bug at any layer boundary surfaces here, regardless of which layer
// is at fault. Failures localize via the test phase that breaks first.
@Suite("ClickHouse — full pipeline smoke test")
struct ClickHouseFullPipelineSmokeTests {

    private static let revision: UInt64 = 54_478

    private static let clientHello = ClickHouseClientHelloPacket(
        clientName: "SwiftDX Smoke",
        versionMajor: 1, versionMinor: 0, protocolRevision: revision,
        defaultDatabase: "obs", username: "default", password: ""
    )

    private static let serverHello = ClickHouseServerHelloPacket(
        serverName: "ClickHouse",
        versionMajor: 24, versionMinor: 8, serverRevision: revision,
        parallelReplicasProtocolVersion: .value(0),
        serverTimezone: .value("UTC"), displayName: .value("smoke-srv"), versionPatch: .value(12),
        chunkedProtocolSend: .value("notchunked"),
        chunkedProtocolRecv: .value("notchunked"),
        passwordComplexityRules: .value([]),
        interserverSecretNonce: .value(0),
        queryPlanSerializationVersion: .value(0)
    )

    private static func makeWiredConnection() throws -> (ClickHouseConnection, EmbeddedChannel) {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: revision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: revision,
            clientHello: clientHello,
            serverHello: serverHello
        )
        let connection = ClickHouseConnection(
            channel: channel,
            inboundHandler: inboundHandler,
            metadata: metadata
        )
        return (connection, channel)
    }

    @Test("handshake → query → data → endOfStream end-to-end")
    func selectQueryRoundTripsThroughEveryLayer() async throws {
        // ── Phase 1: handshake (state machine + raw byte exchange) ──

        var wireToServer = try ClickHouseHandshake.openingBytes(clientHello: Self.clientHello)
        let receivedClientMarker = try ClickHouseClientPacketType.read(from: &wireToServer)
        #expect(receivedClientMarker == .hello)
        let parsedClientHello = try ClickHouseClientHelloPacket.decode(from: &wireToServer)
        #expect(parsedClientHello == Self.clientHello)
        #expect(wireToServer.readableBytes == 0)

        var wireToClient = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &wireToClient)
        Self.serverHello.encode(into: &wireToClient, clientRevision: Self.clientHello.protocolRevision)

        let handshake = ClickHouseHandshake(clientRevision: Self.clientHello.protocolRevision)
        let handshakeOutcome = try handshake.process(incoming: &wireToClient)
        guard case .complete(let negotiatedRevision, let confirmedServerHello) = handshakeOutcome else {
            Issue.record("handshake did not complete")
            return
        }
        #expect(negotiatedRevision == Self.revision)
        #expect(confirmedServerHello == Self.serverHello)

        // ── Phase 2: post-handshake connection wrapped with typed handlers ──

        let (connection, channel) = try Self.makeWiredConnection()
        var inboundIterator = connection.inboundPackets.makeAsyncIterator()

        // ── Phase 3: client sends Query through the connection ──

        let query = ClickHouseQueryPacket(queryID: "smoke-1", queryText: "SELECT 1")
        try await connection.send(.query(query))

        // Server side: confirm the bytes that emerged are a valid Query.
        var emittedQueryBytes = try #require(try channel.readOutbound(as: ByteBuffer.self))
        let queryMarker = try ClickHouseClientPacketType.read(from: &emittedQueryBytes)
        #expect(queryMarker == .query)
        let parsedQuery = try ClickHouseQueryPacket.decode(from: &emittedQueryBytes, revision: Self.revision)
        #expect(parsedQuery.queryID == "smoke-1")
        #expect(parsedQuery.queryText == "SELECT 1")

        // ── Phase 4: server simulates response (Data block + EndOfStream) ──

        let responseBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "1", column: ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: [1])),
            ]
        )
        var responseBytes = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &responseBytes)
        responseBytes.writeClickHouseString("")
        try responseBlock.encode(into: &responseBytes, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &responseBytes)
        try channel.writeInbound(responseBytes)

        // ── Phase 5: client drives query lifecycle over inbound stream ──

        let lifecycle = ClickHouseQueryLifecycle(revision: Self.revision)

        let firstPacket = try #require(try await inboundIterator.next())
        let firstEvent = try lifecycle.handle(firstPacket)
        guard case .data(let receivedBlock) = firstEvent else {
            Issue.record("expected .data, got \(firstEvent)")
            return
        }
        let receivedColumn = try #require(receivedBlock.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<UInt8>)
        #expect(receivedColumn.values == [1])

        let secondPacket = try #require(try await inboundIterator.next())
        let secondEvent = try lifecycle.handle(secondPacket)
        guard case .completed = secondEvent else {
            Issue.record("expected .completed, got \(secondEvent)")
            return
        }

        // ── Phase 6: clean close ──

        try await connection.close()
    }

    @Test("query that fails on the server surfaces as a .failed lifecycle event")
    func queryThatFailsServerSideSurfacesAsFailedEvent() async throws {
        let (connection, channel) = try Self.makeWiredConnection()
        var inboundIterator = connection.inboundPackets.makeAsyncIterator()

        let query = ClickHouseQueryPacket(queryID: "smoke-fail", queryText: "SELECT bad_column FROM no_such_table")
        try await connection.send(.query(query))
        _ = try channel.readOutbound(as: ByteBuffer.self)

        let exception = ClickHouseServerExceptionPacket(
            code: 60,
            name: "DB::Exception",
            message: "Table no_such_table doesn't exist",
            stackTrace: "frame 1\nframe 2",
            nested: .none
        )
        var responseBytes = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &responseBytes)
        exception.encode(into: &responseBytes)
        try channel.writeInbound(responseBytes)

        let lifecycle = ClickHouseQueryLifecycle(revision: Self.revision)
        let packet = try #require(try await inboundIterator.next())
        let event = try lifecycle.handle(packet)
        guard case .failed(let receivedException) = event else {
            Issue.record("expected .failed, got \(event)")
            return
        }
        #expect(receivedException.code == 60)
        #expect(receivedException.name == "DB::Exception")

        try await connection.close()
    }

    @Test("a multi-block response drives through the lifecycle in order until completion")
    func multiBlockResponseStreamsInOrder() async throws {
        let (connection, channel) = try Self.makeWiredConnection()
        var inboundIterator = connection.inboundPackets.makeAsyncIterator()

        let query = ClickHouseQueryPacket(queryID: "smoke-multi", queryText: "SELECT n FROM numbers(6)")
        try await connection.send(.query(query))
        _ = try channel.readOutbound(as: ByteBuffer.self)

        let blocks: [[Int32]] = [[0, 1], [2, 3], [4, 5]]
        var responseBytes = ByteBuffer()
        for values in blocks {
            let block = ClickHouseBlock(
                blockInfo: .init(),
                columns: [.init(
                    name: "n",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
                )]
            )
            ClickHouseServerPacketType.data.write(into: &responseBytes)
            responseBytes.writeClickHouseString("")
            try block.encode(into: &responseBytes, revision: Self.revision)
        }
        let progress = ClickHouseServerProgressPacket(
            rows: 6, bytes: 24, totalRows: 6, writtenRows: .value(0), writtenBytes: .value(0)
        )
        ClickHouseServerPacketType.progress.write(into: &responseBytes)
        progress.encode(into: &responseBytes, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &responseBytes)
        try channel.writeInbound(responseBytes)

        let lifecycle = ClickHouseQueryLifecycle(revision: Self.revision)

        var receivedValues: [Int32] = []
        var sawProgress = false
        var completed = false

        for _ in 0..<5 {
            let packet = try #require(try await inboundIterator.next())
            let event = try lifecycle.handle(packet)
            switch event {
            case .data(let block):
                let column = try #require(block.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
                receivedValues.append(contentsOf: column.values)
            case .progress(let info):
                sawProgress = true
                #expect(info.rows == 6)
            case .completed:
                completed = true
            default:
                Issue.record("unexpected event \(event)")
            }
            if completed { break }
        }

        #expect(receivedValues == [0, 1, 2, 3, 4, 5])
        #expect(sawProgress)
        #expect(completed)

        try await connection.close()
    }

    @Test("response bytes split across many writeInbound chunks reassemble correctly")
    func responseBytesFragmentedAcrossManyChunks() async throws {
        let (connection, channel) = try Self.makeWiredConnection()
        var inboundIterator = connection.inboundPackets.makeAsyncIterator()

        let query = ClickHouseQueryPacket(queryID: "smoke-frag", queryText: "SELECT 1")
        try await connection.send(.query(query))
        _ = try channel.readOutbound(as: ByteBuffer.self)

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseStringColumn(values: ["alpha", "beta", "gamma"])
            )]
        )
        var fullResponse = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &fullResponse)
        fullResponse.writeClickHouseString("")
        try block.encode(into: &fullResponse, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &fullResponse)

        let allBytes = fullResponse.getBytes(at: fullResponse.readerIndex, length: fullResponse.readableBytes) ?? []
        let chunkSize = max(1, allBytes.count / 8)
        var offset = 0
        while offset < allBytes.count {
            let end = min(offset + chunkSize, allBytes.count)
            var chunk = ByteBuffer()
            chunk.writeBytes(Array(allBytes[offset..<end]))
            try channel.writeInbound(chunk)
            offset = end
        }

        let lifecycle = ClickHouseQueryLifecycle(revision: Self.revision)

        let firstPacket = try #require(try await inboundIterator.next())
        let firstEvent = try lifecycle.handle(firstPacket)
        guard case .data(let receivedBlock) = firstEvent else {
            Issue.record("expected .data, got \(firstEvent)")
            return
        }
        let column = try #require(receivedBlock.columns.first?.column as? ClickHouseStringColumn)
        #expect(column.values == ["alpha", "beta", "gamma"])

        let secondPacket = try #require(try await inboundIterator.next())
        let secondEvent = try lifecycle.handle(secondPacket)
        guard case .completed = secondEvent else {
            Issue.record("expected .completed")
            return
        }

        try await connection.close()
    }

}
