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

@Suite("ClickHouse handshake")
struct ClickHouseHandshakeTests {

    private let clientHello = ClickHouseClientHelloPacket(
        clientName: "SwiftDX Test",
        versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
        defaultDatabase: "obs", username: "default", password: ""
    )

    @Test("opening bytes carry the hello marker followed by the encoded body")
    func openingBytesAreHelloPacket() throws {
        var buffer = try ClickHouseHandshake.openingBytes(clientHello: clientHello)
        let type = try ClickHouseClientPacketType.read(from: &buffer)
        #expect(type == .hello)
        let decoded = try ClickHouseClientHelloPacket.decode(from: &buffer)
        #expect(decoded == clientHello)
        #expect(buffer.readableBytes == 0)
    }

    @Test("a server hello completes with the negotiated revision = min(client, server)")
    func serverHelloCompletesWithNegotiatedRevision() throws {
        let cases: [(client: UInt64, server: UInt64, expected: UInt64)] = [
            (54_478, 54_478, 54_478),
            (54_478, 54_448, 54_448),
            (54_448, 54_478, 54_448),
            (54_400, 54_478, 54_400),
        ]

        for testCase in cases {
            let client = testCase.client
            // Field presence is gated on min(client, server) — the
            // negotiated revision both sides actually use on the wire.
            // Pre-fix this used `client >= ...`, which only worked when
            // server >= client; it scrambled the round-trip when the
            // server was older.
            let effective = min(testCase.client, testCase.server)
            let serverHello = ClickHouseServerHelloPacket(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8,
                serverRevision: testCase.server,
                parallelReplicasProtocolVersion: effective >= ClickHouseServerHelloPacket.revisionWithVersionedParallelReplicas ? .value(0) : .unsupported,
                serverTimezone: effective >= ClickHouseServerHelloPacket.revisionWithTimezone ? .value("UTC") : .unsupported,
                displayName: effective >= ClickHouseServerHelloPacket.revisionWithDisplayName ? .value("ch-1") : .unsupported,
                versionPatch: effective >= ClickHouseServerHelloPacket.revisionWithVersionPatch ? .value(12) : .unsupported,
                chunkedProtocolSend: effective >= ClickHouseServerHelloPacket.revisionWithChunkedPackets ? .value("notchunked") : .unsupported,
                chunkedProtocolRecv: effective >= ClickHouseServerHelloPacket.revisionWithChunkedPackets ? .value("notchunked") : .unsupported,
                passwordComplexityRules: effective >= ClickHouseServerHelloPacket.revisionWithPasswordComplexityRules ? .value([]) : .unsupported,
                interserverSecretNonce: effective >= ClickHouseServerHelloPacket.revisionWithInterserverSecretV2 ? .value(0) : .unsupported,
                queryPlanSerializationVersion: effective >= ClickHouseServerHelloPacket.revisionWithQueryPlanSerialization ? .value(0) : .unsupported,
                clusterProcessingProtocolVersion: effective >= ClickHouseServerHelloPacket.revisionWithVersionedClusterFunctionProtocol ? .value(0) : .unsupported
            )
            var buffer = ByteBuffer()
            ClickHouseServerPacketType.hello.write(into: &buffer)
            serverHello.encode(into: &buffer, clientRevision: client)

            let handshake = ClickHouseHandshake(clientRevision: testCase.client)
            let outcome = try handshake.process(incoming: &buffer)
            guard case .complete(let revision, let decoded) = outcome else {
                Issue.record("expected .complete for client=\(testCase.client) server=\(testCase.server)")
                continue
            }
            #expect(revision == testCase.expected)
            #expect(decoded == serverHello)
        }
    }

    @Test("a server exception during handshake completes as .rejected with the exception")
    func serverExceptionRejectsHandshake() throws {
        let exception = ClickHouseServerExceptionPacket(
            code: 516, name: "DB::Authentication", message: "auth failed", stackTrace: "", nested: .none
        )
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.exception.write(into: &buffer)
        exception.encode(into: &buffer)

        let handshake = ClickHouseHandshake(clientRevision: 54_478)
        let outcome = try handshake.process(incoming: &buffer)
        guard case .rejected(let decoded) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(decoded == exception)
    }

    @Test("a non-Hello / non-Exception server packet during handshake surfaces a typed protocol error")
    func unexpectedPacketDuringHandshakeRejected() {
        var buffer = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &buffer)

        let handshake = ClickHouseHandshake(clientRevision: 54_478)
        #expect {
            try handshake.process(incoming: &buffer)
        } throws: { error in
            guard case ClickHouseError.unexpectedHandshakeResponse(let received) = error else {
                return false
            }
            return received == "pong"
        }
    }

    @Test("partial server hello bytes return .awaitMore and rewind the buffer")
    func partialBytesAwaitMore() throws {
        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse", versionMajor: 24, versionMinor: 8,
            serverRevision: 54_478,
            parallelReplicasProtocolVersion: .value(0),
            serverTimezone: .value("UTC"), displayName: .value("ch-1"), versionPatch: .value(12),
            chunkedProtocolSend: .value("notchunked"), chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0),
            queryPlanSerializationVersion: .value(0)
        )
        var fullBuffer = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &fullBuffer)
        serverHello.encode(into: &fullBuffer, clientRevision: 54_478)
        let allBytes = fullBuffer.getBytes(at: fullBuffer.readerIndex, length: fullBuffer.readableBytes) ?? []
        let halfPoint = allBytes.count / 2

        var buffer = ByteBuffer()
        buffer.writeBytes(Array(allBytes[0..<halfPoint]))
        let savedIndex = buffer.readerIndex

        let handshake = ClickHouseHandshake(clientRevision: 54_478)
        let firstOutcome = try handshake.process(incoming: &buffer)
        guard case .awaitMore = firstOutcome else {
            Issue.record("expected .awaitMore, got \(firstOutcome)")
            return
        }
        #expect(buffer.readerIndex == savedIndex)

        buffer.writeBytes(Array(allBytes[halfPoint..<allBytes.count]))
        let secondOutcome = try handshake.process(incoming: &buffer)
        guard case .complete(let revision, let decoded) = secondOutcome else {
            Issue.record("expected .complete, got \(secondOutcome)")
            return
        }
        #expect(revision == 54_478)
        #expect(decoded == serverHello)
    }

    @Test("a malformed server response (unknown marker) propagates as fatal")
    func unknownServerMarkerIsFatal() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(200)

        let handshake = ClickHouseHandshake(clientRevision: 54_478)
        #expect(throws: ClickHouseError.unknownServerPacketType(rawValue: 200)) {
            try handshake.process(incoming: &buffer)
        }
    }

    @Test("opening bytes round-trip the client hello identically across constructions")
    func openingBytesAreDeterministic() throws {
        let firstBytes = try ClickHouseHandshake.openingBytes(clientHello: clientHello)
        let secondBytes = try ClickHouseHandshake.openingBytes(clientHello: clientHello)
        let firstArray = firstBytes.getBytes(at: firstBytes.readerIndex, length: firstBytes.readableBytes) ?? []
        let secondArray = secondBytes.getBytes(at: secondBytes.readerIndex, length: secondBytes.readableBytes) ?? []
        #expect(firstArray == secondArray)
    }

}
