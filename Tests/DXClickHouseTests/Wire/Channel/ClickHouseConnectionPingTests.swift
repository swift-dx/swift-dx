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

@Suite("ClickHouse connection — ping/pong")
struct ClickHouseConnectionPingTests {

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
                clientName: "PingTest",
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

    @Test("ping completes successfully when the server responds with Pong")
    func pingReceivesPong() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Pre-load a Pong response on the inbound side.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &inbound)
        try channel.writeInbound(inbound)

        try await connection.ping()

        // Verify the client wrote a single Ping packet (1-byte marker, no body).
        var sawPing = false
        while let outbound = try channel.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                if type == .ping {
                    sawPing = true
                }
            }
        }
        #expect(sawPing, "ping must produce a Ping packet on the wire")

        try await connection.close()
    }

    @Test("ping fails when the underlying channel is closed before a response arrives")
    func pingFailsOnClosedChannel() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Close the channel; the send itself will raise a NIO transport-layer
        // error from `writeAndFlush` before the inbound iterator is reached.
        _ = try channel.finish()

        await #expect(throws: (any Error).self) {
            try await connection.ping()
        }
    }

    @Test("ping throws unexpectedPingResponse if the server sends a non-Pong packet")
    func pingThrowsOnUnexpectedResponse() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Send a Progress packet instead of Pong.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        let progress = ClickHouseServerProgressPacket(
            rows: 1, bytes: 4, totalRows: 1, writtenRows: .value(0), writtenBytes: .value(0)
        )
        progress.encode(into: &inbound, revision: Self.revision)
        try channel.writeInbound(inbound)

        var thrown: Error?
        do {
            try await connection.ping()
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.unexpectedPingResponse(let kind) = received else {
            Issue.record("expected unexpectedPingResponse, got \(String(describing: thrown))")
            return
        }
        #expect(kind == "progress", "the error should report what kind of packet the server sent")

        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
        try await connection.close()
    }

    @Test("when ping receives a non-Pong response the connection is torn down (channel inactive) so the next pool consumer cannot read leftover bytes as their own query response. Pre-fix ping() threw `unexpectedPingResponse` without closing the channel: the pool's release() path then re-parked the connection in idle while it still held stale post-Ping inbound bytes, opening a silent cross-query response mismatch. Symmetric with the bug-28 fix on insertBlockStream and with execute/runSelectStream's catch-and-close.")
    func pingClosesConnectionOnUnexpectedResponse() async throws {
        let (connection, channel) = try Self.makeConnection()

        // Server sends a Progress packet first (simulating a leftover
        // from a prior abandoned query that wasn't fully drained).
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        let progress = ClickHouseServerProgressPacket(
            rows: 1, bytes: 4, totalRows: 1, writtenRows: .value(0), writtenBytes: .value(0)
        )
        progress.encode(into: &inbound, revision: Self.revision)
        try channel.writeInbound(inbound)

        var thrown: Error?
        do {
            try await connection.ping()
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.unexpectedPingResponse = received else {
            Issue.record("expected unexpectedPingResponse; got \(received)")
            return
        }
        #expect(connection.isActive == false,
                "ping must close the channel on unexpectedPingResponse so the pool discards the connection on release")
        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
    }

    @Test("ping returns promptly when the calling Task is cancelled while the server stays silent")
    func pingHonoursTaskCancellation() async throws {
        let (connection, channel) = try Self.makeConnection()

        // No inbound Pong is ever written. The ping would block forever
        // on `nextPacket()` if cancellation were not honoured.
        let pingTask = Task {
            try await connection.ping()
        }

        // Give the ping a moment to enter the suspended `nextPacket()`
        // await, then cancel. Without the cancellation guard, the
        // closeNonBlocking() path is never taken and the task hangs.
        try await Task.sleep(nanoseconds: 50_000_000)
        pingTask.cancel()

        await #expect(throws: (any Error).self) {
            try await pingTask.value
        }

        // Drain anything still pending on the embedded channel.
        while let _ = try channel.readOutbound(as: ByteBuffer.self) {}
    }

}
