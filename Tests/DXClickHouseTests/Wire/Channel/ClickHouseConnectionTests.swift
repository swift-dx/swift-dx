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

@Suite("ClickHouse connection")
struct ClickHouseConnectionTests {

    private static let revision: UInt64 = 54_478

    private static func makeMetadata() -> ClickHouseConnectionMetadata {
        ClickHouseConnectionMetadata(
            negotiatedRevision: revision,
            clientHello: .init(
                clientName: "SwiftDX Test",
                versionMajor: 1, versionMinor: 0, protocolRevision: revision,
                defaultDatabase: "obs", username: "default", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: revision,
                serverTimezone: .value("UTC"), displayName: .value("ch-1"), versionPatch: .value(12)
            )
        )
    }

    private static func makeConnection() throws -> (ClickHouseConnection, EmbeddedChannel) {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: revision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)

        let connection = ClickHouseConnection(
            channel: channel,
            inboundHandler: inboundHandler,
            metadata: makeMetadata()
        )
        return (connection, channel)
    }

    @Test("send produces wire bytes downstream of the encoder")
    func sendProducesEncodedBytes() async throws {
        let (connection, embedded) = try Self.makeConnection()
        try await connection.send(.ping)

        let outbound = try #require(try embedded.readOutbound(as: ByteBuffer.self))
        #expect(outbound.readableBytes == 1)
        let byte: UInt8 = outbound.getInteger(at: outbound.readerIndex) ?? 0xFF
        #expect(byte == ClickHouseClientPacketType.ping.rawValue)
    }

    @Test("inbound bytes are decoded into the packet stream in order")
    func inboundBytesArriveOnStream() async throws {
        let (connection, embedded) = try Self.makeConnection()
        var iterator = connection.inboundPackets.makeAsyncIterator()

        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)
        ClickHouseServerPacketType.endOfStream.write(into: &buffer)
        try embedded.writeInbound(buffer)

        let firstPacket = try #require(try await iterator.next())
        let secondPacket = try #require(try await iterator.next())
        switch (firstPacket, secondPacket) {
        case (.pong, .endOfStream):
            break
        default:
            Issue.record("expected pong then endOfStream, got \(firstPacket) then \(secondPacket)")
        }
    }

    @Test("inbound stream finishes cleanly when the channel becomes inactive")
    func inboundStreamFinishesOnChannelInactive() async throws {
        let (connection, embedded) = try Self.makeConnection()
        var iterator = connection.inboundPackets.makeAsyncIterator()

        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)
        try embedded.writeInbound(buffer)

        let first = try #require(try await iterator.next())
        switch first {
        case .pong: break
        default: Issue.record("expected .pong, got \(first)")
        }

        _ = try await embedded.close()

        let next = try await iterator.next()
        #expect(next == nil)
    }

    @Test("a Hello packet round-trips: encoded outbound, decoded inbound")
    func helloRoundTripsThroughTheConnection() async throws {
        let (connection, embedded) = try Self.makeConnection()
        var iterator = connection.inboundPackets.makeAsyncIterator()

        let clientHello = ClickHouseClientHelloPacket(
            clientName: "Roundtrip",
            versionMajor: 1, versionMinor: 0, protocolRevision: Self.revision,
            defaultDatabase: "obs", username: "u", password: ""
        )
        try await connection.send(.hello(clientHello))

        var outbound = try #require(try embedded.readOutbound(as: ByteBuffer.self))
        let type = try ClickHouseClientPacketType.read(from: &outbound)
        #expect(type == .hello)
        let decoded = try ClickHouseClientHelloPacket.decode(from: &outbound)
        #expect(decoded == clientHello)

        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24, versionMinor: 8, serverRevision: Self.revision,
            parallelReplicasProtocolVersion: .value(0),
            serverTimezone: .value("UTC"), displayName: .value("ch-1"), versionPatch: .value(12),
            chunkedProtocolSend: .value("notchunked"), chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0),
            queryPlanSerializationVersion: .value(0)
        )
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &inbound)
        serverHello.encode(into: &inbound, clientRevision: Self.revision)
        try embedded.writeInbound(inbound)

        let serverPacket = try #require(try await iterator.next())
        guard case .hello(let decodedHello) = serverPacket else {
            Issue.record("expected .hello")
            return
        }
        #expect(decodedHello == serverHello)
    }

    @Test("metadata is preserved on the connection wrapper")
    func metadataIsPreserved() throws {
        let (connection, _) = try Self.makeConnection()
        #expect(connection.metadata.negotiatedRevision == Self.revision)
        #expect(connection.metadata.serverDisplayName == "ch-1")
        #expect(connection.metadata.serverTimezone == "UTC")
    }

    @Test("close completes without throwing on a healthy channel")
    func closeWorksOnHealthyChannel() async throws {
        let (connection, _) = try Self.makeConnection()
        try await connection.close()
    }

    @Test("dropping a Connection without explicit close still closes the channel via the deinit safety net")
    func dropWithoutCloseClosesChannel() async throws {
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try channel.connect(to: address).wait()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: Self.revision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: Self.revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)
        #expect(channel.isActive, "EmbeddedChannel must be connected before the test")

        // Run the lifecycle in a tight scope so the connection deinit
        // fires deterministically when control leaves the closure.
        do {
            _ = ClickHouseConnection(
                channel: channel,
                inboundHandler: inboundHandler,
                metadata: Self.makeMetadata()
            )
        }

        // EmbeddedChannel.close fires synchronously on its event loop,
        // which the test runs on, so by the time we get here the
        // channel.isActive should already be false. Poll briefly just
        // in case scheduling reorders things.
        var inactive = !channel.isActive
        let deadline = Date().addingTimeInterval(0.5)
        while !inactive && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            inactive = !channel.isActive
        }
        #expect(inactive, "Connection deinit must close its channel")
    }

    @Test("closeNonBlocking flips isActive synchronously before NIO finishes the close future")
    func closeNonBlockingFlipsIsActiveSynchronously() async throws {
        let (connection, embedded) = try Self.makeConnection()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try await embedded.connect(to: address).get()
        #expect(connection.isActive, "fresh connected channel must be active")

        // closeNonBlocking schedules the channel close on the event
        // loop; the underlying channel.isActive may briefly stay true
        // until channelInactive fires. The Connection must surface
        // false IMMEDIATELY via its synchronous closing flag, otherwise
        // the pool's release+acquire path can hand a doomed connection
        // to the next caller during the cancellation cleanup window.
        connection.closeNonBlocking()
        #expect(!connection.isActive, "isActive must reflect the synchronous closing flag")
    }

}
