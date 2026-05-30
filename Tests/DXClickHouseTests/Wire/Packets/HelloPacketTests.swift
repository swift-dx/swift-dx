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

@Suite("ClickHouse client hello packet")
struct ClickHouseClientHelloPacketTests {

    @Test("client hello round-trips faithfully")
    func clientHelloRoundTrip() throws {
        let original = ClickHouseClientHelloPacket(
            clientName: "SwiftDX Swift Client",
            versionMajor: 1,
            versionMinor: 0,
            protocolRevision: 54_453,
            defaultDatabase: "observability",
            username: "default",
            password: ""
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer)

        let decoded = try ClickHouseClientHelloPacket.decode(from: &buffer)
        #expect(decoded == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("empty default database, username, and password encode as zero-length strings")
    func emptyStringFieldsEncodeAsLengthZero() {
        let packet = ClickHouseClientHelloPacket(
            clientName: "x",
            versionMajor: 0,
            versionMinor: 0,
            protocolRevision: 0,
            defaultDatabase: "",
            username: "",
            password: ""
        )
        var buffer = ByteBuffer()
        packet.encode(into: &buffer)
        #expect(buffer.readableBytes == 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1)
    }

}

@Suite("ClickHouse server hello packet")
struct ClickHouseServerHelloPacketTests {

    @Test("modern server hello at client_rev=54_479 round-trips with all gated fields")
    func modernHelloRoundTrip() throws {
        let clientRev: UInt64 = 54_479
        let original = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24,
            versionMinor: 8,
            serverRevision: 54_479,
            parallelReplicasProtocolVersion: .value(5),
            serverTimezone: .value("UTC"),
            displayName: .value("ch-prod-01"),
            versionPatch: .value(12),
            chunkedProtocolSend: .value("notchunked"),
            chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0xDEAD_BEEF_CAFE_BABE),
            queryPlanSerializationVersion: .value(0),
            clusterProcessingProtocolVersion: .value(1)
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, clientRevision: clientRev)

        let decoded = try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: clientRev)
        #expect(decoded == original)
    }

    @Test("server hello with revision lower than the client's gates fields on min(client, server), so beyond-min fields aren't read")
    func olderServerHelloDecodedAtMinRevision() throws {
        // Pre-fix: encoder and decoder both gated fields on the
        // `clientRevision` arg, ignoring the parsed/stored
        // `serverRevision`. With matching revisions on both sides this
        // looked symmetric, but never matched what a real older server
        // emits. CH's wire convention: server emits hello fields gated
        // on min(client, server). The fix routes both encode and decode
        // through min(clientRevision, serverRevision).
        let clientRev: UInt64 = 54_478
        let original = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 23, versionMinor: 0,
            serverRevision: 54_400,
            serverTimezone: .value("UTC"),
            displayName: .value("ch-old")
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, clientRevision: clientRev)

        let decoded = try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: clientRev)

        #expect(decoded.serverRevision == 54_400)
        #expect(decoded.serverTimezone == .value("UTC"))
        #expect(decoded.displayName == .value("ch-old"))
        // Fields gated above 54_400 must NOT be on the wire (a real
        // older server wouldn't emit them) and thus must NOT be read.
        #expect(decoded.parallelReplicasProtocolVersion == .unsupported, "parallelReplicas (54_471) > min, must be omitted")
        #expect(decoded.versionPatch == .unsupported, "versionPatch (54_401) > min, must be omitted")
        #expect(decoded.chunkedProtocolSend == .unsupported, "chunkedProtocolSend (54_470) > min, must be omitted")
        #expect(decoded.passwordComplexityRules == .unsupported, "passwordComplexityRules (54_461) > min, must be omitted")
        #expect(decoded.interserverSecretNonce == .unsupported, "interserverSecretNonce (54_462) > min, must be omitted")
        #expect(decoded.queryPlanSerializationVersion == .unsupported, "queryPlanSerializationVersion (54_477) > min, must be omitted")
        #expect(buffer.readableBytes == 0, "decoder must consume exactly the bytes the encoder wrote, no trailing bytes")
    }

    @Test("client_rev=54_460 hello skips chunked/password/nonce/settings/queryPlan/cluster fields")
    func legacyClientRevisionSkipsNewFields() throws {
        let clientRev: UInt64 = 54_460
        let original = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 18,
            versionMinor: 0,
            serverRevision: 54_460,
            serverTimezone: .value("UTC"),
            displayName: .value("ch-1"),
            versionPatch: .value(5)
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, clientRevision: clientRev)

        let decoded = try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: clientRev)
        #expect(decoded.serverTimezone == .value("UTC"))
        #expect(decoded.displayName == .value("ch-1"))
        #expect(decoded.versionPatch == .value(5))
        #expect(decoded.chunkedProtocolSend == .unsupported)
        #expect(decoded.passwordComplexityRules == .unsupported)
        #expect(decoded.interserverSecretNonce == .unsupported)
    }

    @Test("ancient client_rev=54_000 hello has no version-gated fields at all")
    func ancientClientRevisionOmitsAllGatedFields() throws {
        let clientRev: UInt64 = 54_000
        let original = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 1,
            versionMinor: 0,
            serverRevision: 54_000
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, clientRevision: clientRev)

        let decoded = try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: clientRev)
        #expect(decoded == original)
    }

    @Test("password complexity rules round-trip with multiple entries preserved")
    func passwordComplexityRulesRoundTrip() throws {
        let clientRev: UInt64 = 54_465
        let original = ClickHouseServerHelloPacket(
            serverName: "ClickHouse", versionMajor: 24, versionMinor: 8,
            serverRevision: 54_465,
            serverTimezone: .value("UTC"), displayName: .value("ch"), versionPatch: .value(1),
            passwordComplexityRules: .value([
                .init(pattern: "[A-Z]+", message: "Must contain uppercase"),
                .init(pattern: ".{8,}", message: "Must be ≥ 8 chars")
            ]),
            interserverSecretNonce: .value(0)
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, clientRevision: clientRev)

        let decoded = try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: clientRev)
        guard case .value(let rules) = decoded.passwordComplexityRules else {
            Issue.record("expected .value for passwordComplexityRules, got .unsupported")
            return
        }
        #expect(rules.count == 2)
        #expect(rules[0].pattern == "[A-Z]+")
        #expect(rules[1].message == "Must be ≥ 8 chars")
    }

    @Test("server hello rejects a hostile password-rule count that would trap on Int(count)")
    func passwordComplexityRulesHostileCount() throws {
        // Build a minimal valid Hello prefix up to the password-complexity-
        // rules section, then plant a UVarInt count of UInt64.max. Without
        // the `Int(exactly:)` guard, this would trap when converting to Int
        // for `reserveCapacity`. With the guard, the decode surfaces a
        // typed protocol error.
        let clientRev: UInt64 = 54_465
        var buffer = ByteBuffer()
        // serverName / versionMajor / versionMinor / serverRevision / timezone / displayName / versionPatch
        buffer.writeClickHouseString("ClickHouse")
        buffer.writeClickHouseUVarInt(24)  // versionMajor
        buffer.writeClickHouseUVarInt(8)   // versionMinor
        buffer.writeClickHouseUVarInt(54_465)  // serverRevision
        buffer.writeClickHouseString("UTC")  // timezone
        buffer.writeClickHouseString("ch")   // displayName
        buffer.writeClickHouseUVarInt(1)     // versionPatch
        // Hostile rule count: UInt64.max
        buffer.writeClickHouseUVarInt(UInt64.max)
        // No rule bodies follow — we should never reach them.
        do {
            _ = try ClickHouseServerHelloPacket.decode(from: &buffer, clientRevision: clientRev)
            Issue.record("Expected protocol error rejecting hostile rule count")
        } catch is ClickHouseError {
            // Expected: the typed error short-circuits before any
            // `Int(count)` trap or `reserveCapacity` allocation.
        } catch {
            Issue.record("Expected ClickHouseError, got \(error)")
        }
    }

}
