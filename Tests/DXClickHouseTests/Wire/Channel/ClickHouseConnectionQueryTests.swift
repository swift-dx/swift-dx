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

@Suite("ClickHouse connection — selectBlocks streaming")
struct ClickHouseConnectionQueryTests {

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
                clientName: "QueryTest",
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

    private static func encodeServerData(_ blocks: [ClickHouseBlock], terminator: ClickHouseServerPacketType = .endOfStream) throws -> ByteBuffer {
        var buffer = ByteBuffer()
        for block in blocks {
            ClickHouseServerPacketType.data.write(into: &buffer)
            buffer.writeClickHouseString("")
            try block.encode(into: &buffer, revision: revision)
        }
        terminator.write(into: &buffer)
        return buffer
    }

    @Test("a single-block SELECT response streams that block then completes")
    func singleBlockStreamsAndCompletes() async throws {
        let (connection, channel) = try Self.makeConnection()

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
            )]
        )
        let inbound = try Self.encodeServerData([block])
        try channel.writeInbound(inbound)

        var collected: [Int32] = []
        for try await streamed in connection.selectBlocks("SELECT n FROM numbers(3)") {
            let column = try #require(streamed.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
            collected.append(contentsOf: column.values)
        }
        #expect(collected == [1, 2, 3])

        // drain client-side outbound to keep the channel clean
        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("multi-block responses stream every non-empty block in order")
    func multipleBlocksStreamInOrder() async throws {
        let (connection, channel) = try Self.makeConnection()

        let blocks: [[Int32]] = [[10, 20], [30, 40, 50], [60]]
        let serverBlocks = blocks.map { values in
            ClickHouseBlock(
                blockInfo: .init(),
                columns: [.init(
                    name: "n",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
                )]
            )
        }
        let inbound = try Self.encodeServerData(serverBlocks)
        try channel.writeInbound(inbound)

        var collected: [Int32] = []
        for try await streamed in connection.selectBlocks("SELECT") {
            let column = try #require(streamed.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
            collected.append(contentsOf: column.values)
        }
        #expect(collected == [10, 20, 30, 40, 50, 60])

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("an empty leading block from the server is filtered out (it is the ready-marker, not data)")
    func emptyLeadingBlockIsFiltered() async throws {
        let (connection, channel) = try Self.makeConnection()

        let emptyBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
            )]
        )
        let dataBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [99])
            )]
        )
        let inbound = try Self.encodeServerData([emptyBlock, dataBlock])
        try channel.writeInbound(inbound)

        var blockCount = 0
        var collected: [Int32] = []
        for try await streamed in connection.selectBlocks("SELECT") {
            blockCount += 1
            let column = try #require(streamed.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
            collected.append(contentsOf: column.values)
        }
        #expect(blockCount == 1)
        #expect(collected == [99])

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("Task.cancel during execute closes the channel via the cancellation handler")
    func taskCancelDuringExecuteClosesChannel() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Spawn the execute work in a child task. The server (the
        // EmbeddedChannel here) sends nothing, so the await on
        // iterator.next() is suspended indefinitely. Cancelling the
        // task must trigger the onCancel handler in
        // runWithCancellationGuard, which calls closeNonBlocking() and
        // tears down the channel.
        let task = Task {
            try await connection.execute("CREATE TABLE t (x Int32) ENGINE = Memory")
        }
        // Give the task a moment to send the Query+Data and reach the
        // suspended await on the next inbound packet.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result

        // Race tolerance: the channel close fires off the cancellation
        // handler asynchronously. Poll briefly for the channel to
        // become inactive.
        var inactive = !channel.isActive
        let deadline = Date().addingTimeInterval(0.5)
        while !inactive && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            inactive = !channel.isActive
        }
        #expect(inactive, "Task.cancel must close the channel via the runWithCancellationGuard onCancel handler")
    }

    @Test("execute throws unexpectedConnectionClose when the inbound stream ends before a terminal event")
    func executeThrowsOnUnexpectedClose() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Pre-load a non-terminal Progress, then close so the inbound
        // iterator returns nil before EndOfStream/Exception.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        let progress = ClickHouseServerProgressPacket(
            rows: 0, bytes: 0, totalRows: 0, writtenRows: .value(0), writtenBytes: .value(0)
        )
        progress.encode(into: &inbound, revision: Self.revision)
        try channel.writeInbound(inbound)
        try await channel.close().get()

        var thrown: Error?
        do {
            try await connection.execute("CREATE TABLE t (x Int32) ENGINE = Memory")
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "execute must throw on unexpected close, not silently return")
        guard case ClickHouseError.unexpectedConnectionClose = received else {
            Issue.record("expected unexpectedConnectionClose, got \(String(describing: thrown))")
            return
        }
    }

    @Test("insertBlocks surfaces unexpectedConnectionClose when the server hangs up before sending the ready-marker block")
    func insertBlocksThrowsOnEarlyUnexpectedClose() async throws {
        let (connection, channel) = try Self.makeConnection()

        // No bytes preloaded — close immediately so the wait for the
        // ready-marker (rowCount=0) Data block never sees a packet.
        try await channel.close().get()

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(name: "x", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1]))]
        )
        var thrown: Error?
        do {
            try await connection.insertBlocks("INSERT INTO t FORMAT Native", blocks: [block])
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "insertBlocks must throw on unexpected close before ready-marker")
        guard case ClickHouseError.unexpectedConnectionClose = received else {
            Issue.record("expected unexpectedConnectionClose, got \(String(describing: thrown))")
            return
        }
    }

    @Test("if the inbound stream ends without a terminal event, selectBlocks throws unexpectedConnectionClose")
    func selectBlocksThrowsOnUnexpectedClose() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Pre-load a Progress packet (non-terminal) then close the channel —
        // the inbound stream ends without ever yielding EndOfStream/Exception.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        let progress = ClickHouseServerProgressPacket(
            rows: 0, bytes: 0, totalRows: 0, writtenRows: .value(0), writtenBytes: .value(0)
        )
        progress.encode(into: &inbound, revision: Self.revision)
        try channel.writeInbound(inbound)
        try await channel.close().get()

        var thrown: Error?
        do {
            for try await _ in connection.selectBlocks("SELECT 1") {
                Issue.record("no blocks should be yielded before the stream errors")
            }
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "selectBlocks must throw on unexpected close, not silently return zero rows")
        guard case ClickHouseError.unexpectedConnectionClose = received else {
            Issue.record("expected unexpectedConnectionClose, got \(String(describing: thrown))")
            return
        }
    }

    @Test("a server exception during a query throws serverException AND closes the connection")
    func serverExceptionThrowsTypedError() async throws {
        let (connection, channel) = try Self.makeConnection()

        let exception = ClickHouseServerExceptionPacket(
            code: 60,
            name: "DB::TableNotFound",
            message: "Table missing",
            stackTrace: "frame",
            nested: .none
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &inbound)
        exception.encode(into: &inbound)
        try channel.writeInbound(inbound)

        var thrown: Error?
        do {
            for try await _ in connection.selectBlocks("SELECT bad FROM missing") {}
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.serverException(let received) = received else {
            Issue.record("expected serverException, got \(String(describing: thrown))")
            return
        }
        #expect(received.code == 60)
        #expect(received.name == "DB::TableNotFound")

        // Server exception must tear down the connection so the pool's release
        // discards it. Matches insertBlocks/execute close-on-error behavior.
        // Race tolerance: the close happens off-thread; poll briefly.
        var inactive = !connection.isActive
        let deadline = Date().addingTimeInterval(0.5)
        while !inactive && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            inactive = !connection.isActive
        }
        #expect(inactive, "selectBlocks must close the connection on any wire-phase error")

        while let _ = try? channel.readOutbound(as: ByteBuffer.self) {}
    }

    @Test("selectBlocks invokes the onProgress callback for each Progress packet from the server")
    func selectBlocksOnProgressFiresPerPacket() async throws {
        let (connection, channel) = try Self.makeConnection()

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])
            )]
        )
        let progress1 = ClickHouseServerProgressPacket(
            rows: 100, bytes: 4_000, totalRows: 1_000, writtenRows: .value(0), writtenBytes: .value(0)
        )
        let progress2 = ClickHouseServerProgressPacket(
            rows: 200, bytes: 8_000, totalRows: 1_000, writtenRows: .value(0), writtenBytes: .value(0)
        )

        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        progress1.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.data.write(into: &inbound)
        inbound.writeClickHouseString("")
        try block.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.progress.write(into: &inbound)
        progress2.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        let observer = TestProgressObserver()
        for try await _ in connection.selectBlocks(
            "SELECT n",
            onProgress: { progress in
                observer.append(progress)
            }
        ) {}

        let captured = observer.values
        #expect(captured.count == 2, "callback must fire once per Progress packet")
        #expect(captured[0].rows == 100)
        #expect(captured[0].bytes == 4_000)
        #expect(captured[0].totalRows == 1_000)
        #expect(captured[1].rows == 200)
        #expect(captured[1].bytes == 8_000)

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("selectBlocks does NOT invoke the onProgress callback when no Progress packets arrive")
    func selectBlocksNoProgressPackets() async throws {
        let (connection, channel) = try Self.makeConnection()

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])
            )]
        )
        let inbound = try Self.encodeServerData([block])
        try channel.writeInbound(inbound)

        let observer = TestProgressObserver()
        for try await _ in connection.selectBlocks("SELECT n", onProgress: { observer.append($0) }) {}
        #expect(observer.values.isEmpty, "no Progress packets means no callback invocations")

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("execute invokes the onProgress callback for each Progress packet during DDL")
    func executeOnProgressFires() async throws {
        let (connection, channel) = try Self.makeConnection()

        let progress = ClickHouseServerProgressPacket(
            rows: 50, bytes: 200, totalRows: 50, writtenRows: .value(0), writtenBytes: .value(0)
        )

        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        progress.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        let observer = TestProgressObserver()
        try await connection.execute(
            "ALTER TABLE foo MODIFY COLUMN x UInt32",
            onProgress: { observer.append($0) }
        )

        #expect(observer.values.count == 1)
        #expect(observer.values[0].rows == 50)

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("ClickHouseProgress preserves writtenRows and writtenBytes fields when present")
    func progressWrittenFieldsPreserved() {
        let progress = ClickHouseProgress(
            rows: 100, bytes: 1024, totalRows: 1000,
            writtenRows: .rows(42), writtenBytes: .rows(2048)
        )
        #expect(progress.rows == 100)
        #expect(progress.writtenRows == .rows(42))
        #expect(progress.writtenBytes == .rows(2048))
    }

    @Test("a successful selectBlocks completion leaves the connection alive (no close)")
    func successfulSelectKeepsConnectionAlive() async throws {
        let (connection, channel) = try Self.makeConnection()

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
            )]
        )
        let inbound = try Self.encodeServerData([block])
        try channel.writeInbound(inbound)

        for try await _ in connection.selectBlocks("SELECT n") {}

        // Successful completion must NOT close the connection — the pool
        // should be able to reuse it for the next query.
        #expect(connection.isActive == true, "successful selectBlocks completion preserves the connection")

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("single-block INSERT completes successfully when server acks with EndOfStream")
    func singleBlockInsertCompletes() async throws {
        let (connection, channel) = try Self.makeConnection()

        let tableColumns = ClickHouseServerTableColumnsPacket(name: "logs", columnsText: "n Int32")
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

        let dataBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 20, 30])
            )]
        )
        try await connection.insertBlocks("INSERT INTO logs", blocks: [dataBlock])

        var sentBlockCount = 0
        var sawQuery = false
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                switch type {
                case .query:
                    _ = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                    sawQuery = true
                case .data:
                    _ = try buffer.readClickHouseString()
                    let decoded = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                    if decoded.rowCount > 0 {
                        sentBlockCount += 1
                    }
                default:
                    break
                }
            }
        }
        #expect(sawQuery)
        #expect(sentBlockCount == 1)

        try await connection.close()
    }

    @Test("multi-block INSERT sends every block in order before terminator")
    func multiBlockInsertSendsAllBlocksInOrder() async throws {
        let (connection, channel) = try Self.makeConnection()

        let tableColumns = ClickHouseServerTableColumnsPacket(name: "logs", columnsText: "n Int32")
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

        let blockValues: [[Int32]] = [[1, 2], [3, 4, 5], [6]]
        let dataBlocks = blockValues.map { values in
            ClickHouseBlock(
                blockInfo: .init(),
                columns: [.init(
                    name: "n",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
                )]
            )
        }
        try await connection.insertBlocks("INSERT INTO logs", blocks: dataBlocks)

        var receivedRows: [Int32] = []
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                if type == .query {
                    _ = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                } else if type == .data {
                    _ = try buffer.readClickHouseString()
                    let decoded = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                    if let column = decoded.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>,
                       !column.values.isEmpty {
                        receivedRows.append(contentsOf: column.values)
                    }
                }
            }
        }
        #expect(receivedRows == [1, 2, 3, 4, 5, 6])

        try await connection.close()
    }

    @Test("empty INSERT (no blocks) still completes — only the terminator is sent")
    func emptyBlocksInsertStillCompletes() async throws {
        let (connection, channel) = try Self.makeConnection()

        let emptyBlock = ClickHouseBlock(blockInfo: .init(), columns: [])
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &inbound)
        inbound.writeClickHouseString("")
        try emptyBlock.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        try await connection.insertBlocks("INSERT INTO logs", blocks: [])

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("a server exception during INSERT throws serverException with the typed exception")
    func serverExceptionDuringInsertThrows() async throws {
        let (connection, channel) = try Self.makeConnection()

        let exception = ClickHouseServerExceptionPacket(
            code: 47,
            name: "DB::ColumnMismatch",
            message: "column count mismatch",
            stackTrace: "",
            nested: .none
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &inbound)
        exception.encode(into: &inbound)
        try channel.writeInbound(inbound)

        let dataBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [99])
            )]
        )
        var thrown: Error?
        do {
            try await connection.insertBlocks("INSERT INTO logs", blocks: [dataBlock])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.serverException(let receivedException) = received else {
            Issue.record("expected serverException, got \(String(describing: thrown))")
            return
        }
        #expect(receivedException.code == 47)
        #expect(receivedException.name == "DB::ColumnMismatch")

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("when the consumer abandons the stream early, the channel closes so the pool discards the connection")
    func consumerAbandonmentClosesChannel() async throws {
        let (connection, channel) = try Self.makeConnection()

        let block1 = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])
            )]
        )
        let block2 = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [2])
            )]
        )

        // Push only block1. The consumer reads it and breaks (iterator
        // drops, continuation becomes terminated). The cancellation
        // cascade fires `task.cancel`, which fires the connection's
        // cancellation handler, which closes the channel. The pool's
        // release path then sees `isActive == false` and discards the
        // connection — equivalent to a TCP RST that tells the server
        // to stop processing.
        _ = block2
        var firstWave = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &firstWave)
        firstWave.writeClickHouseString("")
        try block1.encode(into: &firstWave, revision: Self.revision)
        try channel.writeInbound(firstWave)

        var received: [Int32] = []
        for try await streamed in connection.selectBlocks("SELECT n FROM t") {
            let column = try #require(streamed.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
            received.append(contentsOf: column.values)
            break
        }
        #expect(received == [1])

        // The cancellation handler defers the channel close briefly so
        // any in-flight soft-abandon work has a chance to run; poll
        // until the channel reports inactive (or the deadline passes).
        var inactive = !connection.isActive
        let deadline = Date().addingTimeInterval(0.5)
        while !inactive && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            inactive = !connection.isActive
        }
        #expect(inactive, "consumer abandonment must close the channel so the pool discards the connection")
    }

    @Test("a block with mismatched column row counts surfaces blockColumnRowCountMismatch and closes the connection")
    func insertCloseOnRowCountMismatch() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Server side: send a tableColumns + sample data ack carrying
        // the destination schema (two Int32 columns "n" and "m") so
        // insertBlocks exits the readyLoop and starts streaming blocks.
        let tableColumns = ClickHouseServerTableColumnsPacket(name: "logs", columnsText: "n Int32, m Int32")
        let sampleBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(
                    name: "n",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
                ),
                .init(
                    name: "m",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
                ),
            ]
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.tableColumns.write(into: &inbound)
        tableColumns.encode(into: &inbound)
        ClickHouseServerPacketType.data.write(into: &inbound)
        inbound.writeClickHouseString("")
        try sampleBlock.encode(into: &inbound, revision: Self.revision)
        try channel.writeInbound(inbound)

        // Construct a deliberately malformed block: column "n" has 3 rows,
        // column "m" has 2 rows. Block.encode's assertConsistentRowCounts
        // catches this at the wire-send step.
        let badBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(
                    name: "n",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
                ),
                .init(
                    name: "m",
                    column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 20])
                )
            ]
        )

        var thrown: Error?
        do {
            try await connection.insertBlocks("INSERT INTO logs", blocks: [badBlock])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.blockColumnRowCountMismatch(let columnIndex, let expected, let actual) = received else {
            Issue.record("expected blockColumnRowCountMismatch, got \(String(describing: thrown))")
            return
        }
        #expect(columnIndex == 1)
        #expect(expected == 3)
        #expect(actual == 2)

        // The cleanup path closes the connection so the pool's release sees
        // `isActive == false` and discards it. Verify the channel is no
        // longer active.
        #expect(connection.isActive == false, "block-encode failure must tear down the connection so the pool discards it")

        while let _ = try? channel.readOutbound(as: ByteBuffer.self) {}
    }

    @Test("execute completes when the server signals EndOfStream after a single empty Data ack")
    func executeCompletesOnEndOfStream() async throws {
        let (connection, channel) = try Self.makeConnection()

        // For DDL, the server typically sends a single empty data block
        // (the "ready/ack" marker), then EndOfStream.
        let emptyBlock = ClickHouseBlock(blockInfo: .init(), columns: [])
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.data.write(into: &inbound)
        inbound.writeClickHouseString("")
        try emptyBlock.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        try await connection.execute("CREATE TABLE foo (id UInt32) ENGINE = MergeTree ORDER BY id")

        // Verify outbound: a Query packet plus the empty input terminator.
        var sawQuery = false
        var sawEmptyDataTerminator = false
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                switch type {
                case .query:
                    let q = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                    if q.queryText.contains("CREATE TABLE") { sawQuery = true }
                case .data:
                    _ = try buffer.readClickHouseString()
                    let block = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                    if block.rowCount == 0 { sawEmptyDataTerminator = true }
                default:
                    break
                }
            }
        }
        #expect(sawQuery)
        #expect(sawEmptyDataTerminator)

        try await connection.close()
    }

    @Test("execute throws serverException AND closes the connection when the server returns an Exception")
    func executeThrowsOnServerException() async throws {
        let (connection, channel) = try Self.makeConnection()

        let exception = ClickHouseServerExceptionPacket(
            code: 60,
            name: "DB::TableAlreadyExists",
            message: "Table foo already exists",
            stackTrace: "",
            nested: .none
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &inbound)
        exception.encode(into: &inbound)
        try channel.writeInbound(inbound)

        var thrown: Error?
        do {
            try await connection.execute("CREATE TABLE foo (id UInt32)")
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.serverException(let serverException) = received else {
            Issue.record("expected serverException, got \(String(describing: thrown))")
            return
        }
        #expect(serverException.code == 60)
        #expect(serverException.name == "DB::TableAlreadyExists")

        // The server-exception path must tear down the connection so the pool
        // discards it on release rather than reusing a mid-query state.
        #expect(connection.isActive == false, "execute must close the connection on any wire-phase error")

        while let _ = try? channel.readOutbound(as: ByteBuffer.self) {}
    }

    @Test("execute closes the connection when the inbound stream ends without a terminal event")
    func executeClosesConnectionOnUnexpectedClose() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Pre-load a Progress packet (non-terminal) then close the channel —
        // the inbound stream ends without ever yielding EndOfStream/Exception.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        let progress = ClickHouseServerProgressPacket(
            rows: 0, bytes: 0, totalRows: 0, writtenRows: .value(0), writtenBytes: .value(0)
        )
        progress.encode(into: &inbound, revision: Self.revision)
        try channel.writeInbound(inbound)
        // Closing inbound side of the channel forces the iterator to return nil
        // and execute throws unexpectedConnectionClose.
        try await channel.close().get()

        var thrown: Error?
        do {
            try await connection.execute("DROP TABLE foo")
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "execute must throw when the connection closes unexpectedly")
        #expect(connection.isActive == false, "execute must leave isActive == false after a wire-phase error")
    }

    @Test("execute completes immediately when the server sends only EndOfStream (no ack block)")
    func executeCompletesWithJustEndOfStream() async throws {
        let (connection, channel) = try Self.makeConnection()

        var inbound = ByteBuffer()
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        try await connection.execute("DROP TABLE foo")

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("settings supplied to execute propagate to the outbound Query packet")
    func executePropagatesSettings() async throws {
        let (connection, channel) = try Self.makeConnection()

        var inbound = ByteBuffer()
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        let settings = [ClickHouseQuerySetting(name: "alter_sync", value: "2")]
        try await connection.execute("ALTER TABLE foo ADD COLUMN x UInt32", settings: settings)

        var sawQueryWithSettings = false
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                if type == .query {
                    let q = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                    if q.settings.contains(where: { $0.name == "alter_sync" && $0.value == "2" }) {
                        sawQueryWithSettings = true
                    }
                } else if type == .data {
                    _ = try buffer.readClickHouseString()
                    _ = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                }
            }
        }
        #expect(sawQueryWithSettings)

        try await connection.close()
    }

    @Test("settings supplied to selectBlocks appear in the outbound Query packet")
    func selectBlocksPropagatesSettings() async throws {
        let (connection, channel) = try Self.makeConnection()

        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])
            )]
        )
        let inbound = try Self.encodeServerData([block])
        try channel.writeInbound(inbound)

        let settings = [
            ClickHouseQuerySetting(name: "max_execution_time", value: "30"),
            ClickHouseQuerySetting(name: "max_memory_usage", value: "1000000000")
        ]
        for try await _ in connection.selectBlocks("SELECT n", settings: settings) { }

        var sawQueryWithSettings = false
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                if type == .query {
                    let query = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                    // Caller-supplied settings must all appear; the SDK
                    // also injects an internal serialization-mode setting
                    // on top, so we check containment, not equality.
                    let suppliedNames = Set(settings.map(\.name))
                    let suppliedValues = Dictionary(uniqueKeysWithValues: settings.map { ($0.name, $0.value) })
                    let actualNames = Set(query.settings.map(\.name))
                    let actualValues = Dictionary(uniqueKeysWithValues: query.settings.map { ($0.name, $0.value) })
                    if suppliedNames.isSubset(of: actualNames),
                       suppliedValues.allSatisfy({ actualValues[$0.key] == $0.value }) {
                        sawQueryWithSettings = true
                    }
                } else if type == .data {
                    _ = try buffer.readClickHouseString()
                    _ = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                }
            }
        }
        #expect(sawQueryWithSettings, "Query packet on the wire must carry the settings supplied to selectBlocks")

        try await connection.close()
    }

    @Test("settings supplied to insertBlocks appear in the outbound Query packet")
    func insertBlocksPropagatesSettings() async throws {
        let (connection, channel) = try Self.makeConnection()

        let tableColumns = ClickHouseServerTableColumnsPacket(name: "logs", columnsText: "n Int32")
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

        let dataBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [42])
            )]
        )
        let settings = [ClickHouseQuerySetting(name: "async_insert", value: "1")]
        try await connection.insertBlocks("INSERT INTO logs", blocks: [dataBlock], settings: settings)

        var sawQueryWithSettings = false
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                if type == .query {
                    let query = try ClickHouseQueryPacket.decode(from: &buffer, revision: Self.revision)
                    if query.settings.contains(where: { $0.name == "async_insert" && $0.value == "1" }) {
                        sawQueryWithSettings = true
                    }
                } else if type == .data {
                    _ = try buffer.readClickHouseString()
                    _ = try ClickHouseBlock.decode(from: &buffer, revision: Self.revision)
                }
            }
        }
        #expect(sawQueryWithSettings, "Query packet on the wire must carry the settings supplied to insertBlocks")

        try await connection.close()
    }

    @Test("non-data side-channel events (progress, profileInfo) do not produce stream items")
    func nonDataEventsAreFiltered() async throws {
        let (connection, channel) = try Self.makeConnection()

        let dataBlock = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [42])
            )]
        )
        let progress = ClickHouseServerProgressPacket(
            rows: 1, bytes: 4, totalRows: 1,
            totalBytes: .value(0), writtenRows: .value(0), writtenBytes: .value(0), elapsedNanoseconds: .value(0)
        )
        let profileInfo = ClickHouseServerProfileInfoPacket(
            rows: 1, blocks: 1, bytes: 4,
            appliedLimit: false, rowsBeforeLimit: 0, calculatedRowsBeforeLimit: false,
            appliedAggregation: .value(false), rowsBeforeAggregation: .value(0)
        )

        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        progress.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.data.write(into: &inbound)
        inbound.writeClickHouseString("")
        try dataBlock.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.profileInfo.write(into: &inbound)
        profileInfo.encode(into: &inbound, revision: Self.revision)
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        var blockCount = 0
        for try await streamed in connection.selectBlocks("SELECT") {
            blockCount += 1
            let column = try #require(streamed.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
            #expect(column.values == [42])
        }
        #expect(blockCount == 1)

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("Query packet's clientInfo.clientRevision matches the connection's advertised hello revision (no entropy gap between Hello and Query)")
    func queryPacketClientInfoMatchesHelloRevision() async throws {
        // Pre-fix: ClickHouseClientInfo's `clientRevision` defaulted to
        // 54_478 while ClickHouseClientConfiguration.advertisedRevision
        // defaulted to 54_479 — a 1-version gap between what the client
        // says in Hello and what every subsequent Query packet's
        // ClientInfo carries. CH server reads ClientInfo's
        // client_tcp_protocol_version for distributed-query forwarding
        // and metadata logs; sending two contradicting values for the
        // same logical "client TCP protocol version" was an entropy gap
        // that survived because both sides had independent defaults.
        // Post-fix `makeQueryPacket` threads `metadata.clientHello.
        // protocolRevision` into clientInfo.clientRevision so they
        // always agree, regardless of what value the user configured.
        //
        // Use a custom revision (54_400) distinct from both defaults so
        // the assertion fails on either pre-fix code path (where
        // clientInfo defaulted to 54_478 regardless) and passes only
        // when the value actually flows from the connection's metadata.
        let customRevision: UInt64 = 54_400
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try channel.connect(to: address).wait()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: customRevision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: customRevision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: customRevision,
            clientHello: .init(
                clientName: "RevisionTest",
                versionMajor: 1, versionMinor: 0, protocolRevision: customRevision,
                defaultDatabase: "obs", username: "u", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: customRevision,
                serverTimezone: .value("UTC"), displayName: .value("test-1"), versionPatch: .value(1)
            )
        )
        let connection = ClickHouseConnection(channel: channel, inboundHandler: inboundHandler, metadata: metadata)

        var inbound = ByteBuffer()
        ClickHouseServerPacketType.endOfStream.write(into: &inbound)
        try channel.writeInbound(inbound)

        try await connection.execute("SELECT 1")

        var combinedOutbound = ByteBuffer()
        while let chunk = try channel.readOutbound(as: ByteBuffer.self) {
            var c = chunk
            combinedOutbound.writeBuffer(&c)
        }
        let packetType = try ClickHouseClientPacketType.read(from: &combinedOutbound)
        #expect(packetType == .query, "first outbound packet must be Query")
        let queryPacket = try ClickHouseQueryPacket.decode(from: &combinedOutbound, revision: customRevision)

        #expect(
            queryPacket.clientInfo.clientRevision == customRevision,
            "clientInfo.clientRevision (\(queryPacket.clientInfo.clientRevision)) must equal the connection's clientHello.protocolRevision (\(customRevision))"
        )

        try await connection.close()
    }

}

private final class TestProgressObserver: @unchecked Sendable {

    private let lock = NSLock()
    private var _values: [ClickHouseProgress] = []

    var values: [ClickHouseProgress] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: ClickHouseProgress) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }

}
