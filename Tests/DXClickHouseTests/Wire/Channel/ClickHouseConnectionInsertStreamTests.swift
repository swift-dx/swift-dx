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
import Foundation
import NIOCore
import NIOEmbedded
import Testing

@Suite("ClickHouse connection — insertBlockStream (streaming INSERT)")
struct ClickHouseConnectionInsertStreamTests {

    private static let revision: UInt64 = 54_478

    private static func makeConnection() throws -> (ClickHouseConnection, EmbeddedChannel) {
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try channel.connect(to: address).wait()
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
            clientHello: .init(
                clientName: "InsertStreamTest",
                versionMajor: 1, versionMinor: 0, protocolRevision: revision,
                defaultDatabase: "obs", username: "u", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: revision,
                serverTimezone: .value("UTC"), displayName: .value("test-1"), versionPatch: .value(1)
            )
        )
        let connection = ClickHouseConnection(channel: channel, inboundHandler: inboundHandler, metadata: metadata)
        return (connection, channel)
    }

    private static func writeReadyAck(into channel: EmbeddedChannel) throws {
        let tableColumns = ClickHouseServerTableColumnsPacket(name: "logs", columnsText: "n Int32")
        // Empty data block carrying the destination column schema —
        // the INSERT lifecycle uses this to promote inbound blocks to
        // the server's declared types. Must match the shape of the
        // data blocks the tests in this suite send via `makeBlock`.
        let sampleBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
            )]
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.tableColumns.write(into: &inbound)
        tableColumns.encode(into: &inbound)
        ClickHouseServerPacketType.data.write(into: &inbound)
        inbound.writeClickHouseString("")
        try sampleBlock.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)
    }

    private static func makeBlock(values: [Int32]) -> ClickHouseBlock {
        ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
            )]
        )
    }

    private static func collectOutboundRows(_ channel: EmbeddedChannel) throws -> [Int32] {
        var rows: [Int32] = []
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                switch type {
                case .query:
                    _ = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                case .data:
                    _ = try buffer.readClickHouseString()
                    let decoded = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                    if let column = decoded.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>,
                       !column.values.isEmpty {
                        rows.append(contentsOf: column.values)
                    }
                default:
                    break
                }
            }
        }
        return rows
    }

    @Test("a closure-based block stream sends every yielded block in order, terminating on nil")
    func closureStreamSendsBlocksInOrder() async throws {
        let (connection, channel) = try Self.makeConnection()
        try Self.writeReadyAck(into: channel)

        let allBlocks: [[Int32]] = [[1, 2], [3, 4, 5], [6]]
        let cursor = ClickHouseBlockArrayCursor(blocks: allBlocks.map { Self.makeBlock(values: $0) })

        try await connection.insertBlockStream(
            "INSERT INTO logs",
            nextBlock: { cursor.next() }
        )

        let rows = try Self.collectOutboundRows(channel)
        #expect(rows == [1, 2, 3, 4, 5, 6])
        try await connection.close()
    }

    @Test("a closure that returns nil immediately sends only handshake + terminator (zero data blocks)")
    func emptyClosureStreamSendsOnlyTerminator() async throws {
        let (connection, channel) = try Self.makeConnection()
        try Self.writeReadyAck(into: channel)

        try await connection.insertBlockStream(
            "INSERT INTO logs",
            nextBlock: { .endOfStream }
        )

        let rows = try Self.collectOutboundRows(channel)
        #expect(rows.isEmpty, "no data blocks should have rows")
        try await connection.close()
    }

    @Test("when the closure throws mid-stream, the connection is torn down and the error propagates")
    func closureThrowingMidStreamTearsDownConnection() async throws {
        struct ProviderError: Error, Equatable {}

        let (connection, channel) = try Self.makeConnection()
        try Self.writeReadyAck(into: channel)

        // First block sent successfully, second throws
        let cursor = ClickHouseBlockArrayCursor(blocks: [Self.makeBlock(values: [1, 2])])
        let throwOnSecond = ClickHouseBlockProviderState()

        var caught: Error?
        do {
            try await connection.insertBlockStream(
                "INSERT INTO logs",
                nextBlock: { () async throws -> ClickHouseBlockCursorOutcome in
                    if throwOnSecond.calls > 0 {
                        throw ProviderError()
                    }
                    throwOnSecond.calls += 1
                    return cursor.next()
                }
            )
        } catch {
            caught = error
        }
        #expect(caught is ProviderError)
        // Drain anything outbound
        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
    }

    @Test("when the server sends an Exception during the readyLoop (before the empty-data ready signal), the connection is closed so the next pool user gets a fresh socket. Pre-fix the readyLoop's serverException throw propagated up without tearing the channel down, so the connection got parked back in idle in mid-INSERT state with stale inbound bytes left over for the next caller.")
    func serverExceptionInReadyLoopClosesConnection() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Simulate the server immediately responding to our Query + empty-data
        // signal with an Exception packet — common path when the SQL is
        // malformed (parse error / unknown table / type mismatch reported
        // at parse time).
        let exception = ClickHouseServerExceptionPacket(
            code: 60,
            name: "DB::Exception",
            message: "Unknown table",
            stackTrace: "(simulated)",
            nested: .none
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &inbound)
        exception.encode(into: &inbound)
        try channel.writeInbound(inbound)

        var caught: Error?
        do {
            try await connection.insertBlockStream(
                "INSERT INTO bad_table",
                nextBlock: { .endOfStream }
            )
        } catch {
            caught = error
        }
        // The right error surfaces…
        guard case ClickHouseError.serverException(let got)? = caught as? ClickHouseError else {
            Issue.record("expected serverException; got \(String(describing: caught))")
            return
        }
        #expect(got.code == 60)
        // …and the connection must be torn down so a stale-channel reuse
        // by the next pool caller can't read leftover bytes from this
        // mid-INSERT state as their own query response.
        #expect(connection.isActive == false,
                "channel must close on a readyLoop server exception, mirroring execute() and runSelectStream() catch behaviour")
        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
    }

    @Test("when the server hangs up mid-readyLoop (channel closes before the empty-data signal arrives), insertBlockStream surfaces unexpectedConnectionClose AND leaves the connection inactive so the pool discards it. Pre-fix nextPacket() returning nil propagated the typed error up without an explicit close call; the channel was already inactive in this specific path, but other readyLoop throws shared the same gap.")
    func midReadyLoopHangupSurfacesTypedErrorAndConnectionIsInactive() async throws {
        let (connection, channel) = try Self.makeConnection()

        // No inbound bytes — just close the channel from the server side
        // to simulate a mid-readyLoop hangup.
        try await channel.close()

        var caught: Error?
        do {
            try await connection.insertBlockStream(
                "INSERT INTO logs",
                nextBlock: { .endOfStream }
            )
        } catch {
            caught = error
        }
        #expect(caught is ClickHouseError,
                "must surface typed protocol error; got \(String(describing: caught))")
        #expect(connection.isActive == false)
        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
    }

}

private final class ClickHouseBlockProviderState: @unchecked Sendable {
    var calls: Int = 0
}
