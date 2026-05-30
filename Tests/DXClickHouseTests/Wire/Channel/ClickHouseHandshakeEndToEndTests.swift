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

// End-to-end value-level "client + simulated server" exchange that
// drives every layer built so far — handshake state machine, packet
// dispatch enums, packet codecs, framing helper, and connection
// metadata — through a single round trip with no NIO involvement.
//
// If any layer's encoder is asymmetric with the corresponding
// decoder, or if the handshake's revision negotiation drifts, this
// test catches it. Pure unit-test coverage of the full pre-query
// pipeline.
@Suite("ClickHouse handshake — end-to-end conversation simulation")
struct ClickHouseHandshakeEndToEndTests {

    private let clientHello = ClickHouseClientHelloPacket(
        clientName: "SwiftDX Test",
        versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
        defaultDatabase: "obs", username: "default", password: ""
    )

    @Test("simulated handshake yields connection metadata with the negotiated revision and parsed server hello")
    func simulatedHandshakeProducesMetadata() throws {
        // Client side: produce the opening hello bytes.
        var wireToServer = try ClickHouseHandshake.openingBytes(clientHello: clientHello)

        // Simulated server side: receive bytes, parse the marker + body,
        // verify it matches the client hello we sent.
        let clientMarker = try ClickHouseClientPacketType.read(from: &wireToServer)
        #expect(clientMarker == .hello)
        let receivedClientHello = try ClickHouseClientHelloPacket.decode(from: &wireToServer)
        #expect(receivedClientHello == clientHello)
        #expect(wireToServer.readableBytes == 0)

        // Simulated server: pick a server revision lower than the
        // client's to verify negotiation picks the min. Fields gated
        // above 54_460 (parallelReplicas/chunkedPackets/passwordRules/
        // interserverNonce/queryPlanSerialization) are intentionally
        // nil here: a real server at 54_460 wouldn't emit them, and the
        // encoder honors that by gating on min(client, server). The
        // ones gated below 54_460 (timezone/displayName/versionPatch)
        // round-trip as set.
        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24, versionMinor: 8,
            serverRevision: 54_460,
            serverTimezone: .value("Pacific/Auckland"),
            displayName: .value("ch-prod-1"),
            versionPatch: .value(12)
        )
        var wireToClient = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &wireToClient)
        serverHello.encode(into: &wireToClient, clientRevision: clientHello.protocolRevision)

        // Client side: process the server bytes through the handshake.
        let handshake = ClickHouseHandshake(clientRevision: clientHello.protocolRevision)
        let outcome = try handshake.process(incoming: &wireToClient)
        guard case .complete(let negotiatedRevision, let decodedServerHello) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }

        // Build connection metadata and verify it captures everything
        // downstream needs.
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: negotiatedRevision,
            clientHello: clientHello,
            serverHello: decodedServerHello
        )
        #expect(metadata.negotiatedRevision == 54_460)
        #expect(metadata.serverDisplayName == "ch-prod-1")
        #expect(metadata.serverTimezone == "Pacific/Auckland")
        #expect(metadata.serverHello == serverHello)
        #expect(wireToClient.readableBytes == 0)
    }

    @Test("when server omits display name, metadata falls back to server name")
    func metadataFallsBackToServerNameWhenDisplayNameMissing() throws {
        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 18, versionMinor: 0,
            serverRevision: 54_100,
            serverTimezone: .value("UTC"),
            displayName: .unsupported,
            versionPatch: .unsupported
        )
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: 54_100,
            clientHello: clientHello,
            serverHello: serverHello
        )
        #expect(metadata.serverDisplayName == "ClickHouse")
        #expect(metadata.serverTimezone == "UTC")
    }

    @Test("when server omits timezone, metadata defaults to UTC")
    func metadataDefaultsToUTCWhenTimezoneMissing() throws {
        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 1, versionMinor: 0,
            serverRevision: 54_000,
            serverTimezone: .unsupported,
            displayName: .unsupported,
            versionPatch: .unsupported
        )
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: 54_000,
            clientHello: clientHello,
            serverHello: serverHello
        )
        #expect(metadata.serverTimezone == "UTC")
    }

    @Test("auth-failure conversation propagates a Rejected outcome with the typed exception")
    func authFailureConversation() throws {
        var wireToServer = try ClickHouseHandshake.openingBytes(clientHello: clientHello)

        // Simulated server consumes the client hello (validates we wrote a
        // valid frame).
        let clientMarker = try ClickHouseClientPacketType.read(from: &wireToServer)
        #expect(clientMarker == .hello)
        _ = try ClickHouseClientHelloPacket.decode(from: &wireToServer)

        // Simulated server replies with an Authentication failure exception.
        let exception = ClickHouseServerExceptionPacket(
            code: 516,
            name: "DB::Authentication",
            message: "Wrong password for user default",
            stackTrace: "",
            nested: .none
        )
        var wireToClient = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &wireToClient)
        exception.encode(into: &wireToClient)

        let handshake = ClickHouseHandshake(clientRevision: clientHello.protocolRevision)
        let outcome = try handshake.process(incoming: &wireToClient)
        guard case .rejected(let decoded) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(decoded == exception)
        #expect(decoded.code == 516)
    }

    @Test("server hello arriving in two TCP-style fragments still completes the handshake")
    func fragmentedServerHelloCompletes() throws {
        var wireToServer = try ClickHouseHandshake.openingBytes(clientHello: clientHello)
        _ = try ClickHouseClientPacketType.read(from: &wireToServer)
        _ = try ClickHouseClientHelloPacket.decode(from: &wireToServer)

        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse", versionMajor: 24, versionMinor: 8,
            serverRevision: 54_478,
            parallelReplicasProtocolVersion: .value(0),
            serverTimezone: .value("Europe/London"),
            displayName: .value("ch-eu-1"),
            versionPatch: .value(5),
            chunkedProtocolSend: .value("notchunked"),
            chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0),
            queryPlanSerializationVersion: .value(0)
        )
        var fullResponse = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &fullResponse)
        serverHello.encode(into: &fullResponse, clientRevision: clientHello.protocolRevision)
        let allBytes = fullResponse.getBytes(at: fullResponse.readerIndex, length: fullResponse.readableBytes) ?? []
        let firstChunk = Array(allBytes[0..<(allBytes.count / 3)])
        let secondChunk = Array(allBytes[(allBytes.count / 3)..<(2 * allBytes.count / 3)])
        let thirdChunk = Array(allBytes[(2 * allBytes.count / 3)..<allBytes.count])

        let handshake = ClickHouseHandshake(clientRevision: clientHello.protocolRevision)
        var clientReceiveBuffer = ByteBuffer()

        clientReceiveBuffer.writeBytes(firstChunk)
        let firstOutcome = try handshake.process(incoming: &clientReceiveBuffer)
        guard case .awaitMore = firstOutcome else {
            Issue.record("expected .awaitMore after first chunk, got \(firstOutcome)")
            return
        }

        clientReceiveBuffer.writeBytes(secondChunk)
        let secondOutcome = try handshake.process(incoming: &clientReceiveBuffer)
        guard case .awaitMore = secondOutcome else {
            Issue.record("expected .awaitMore after second chunk, got \(secondOutcome)")
            return
        }

        clientReceiveBuffer.writeBytes(thirdChunk)
        let finalOutcome = try handshake.process(incoming: &clientReceiveBuffer)
        guard case .complete(let revision, let decoded) = finalOutcome else {
            Issue.record("expected .complete after final chunk, got \(finalOutcome)")
            return
        }
        #expect(revision == 54_478)
        #expect(decoded == serverHello)
    }

}
