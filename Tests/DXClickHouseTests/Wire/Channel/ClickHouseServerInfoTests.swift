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
import Testing

@Suite("ClickHouse server info derivation")
struct ClickHouseServerInfoTests {

    private static func makeMetadata(
        serverHello: ClickHouseServerHelloPacket,
        revision: UInt64 = 54_478
    ) -> ClickHouseConnectionMetadata {
        ClickHouseConnectionMetadata(
            negotiatedRevision: revision,
            clientHello: .init(
                clientName: "Test", versionMajor: 1, versionMinor: 0,
                protocolRevision: revision,
                defaultDatabase: "default", username: "u", password: ""
            ),
            serverHello: serverHello
        )
    }

    @Test("a fully-populated server hello produces complete server info with Major.Minor.Patch version")
    func fullyPopulatedHelloProducesCompleteInfo() {
        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24,
            versionMinor: 8,
            serverRevision: 54_478,
            serverTimezone: .value("UTC"),
            displayName: .value("production-1"),
            versionPatch: .value(7)
        )
        let metadata = Self.makeMetadata(serverHello: hello)
        let info = metadata.publicServerInfo
        #expect(info.name == "ClickHouse")
        #expect(info.version == "24.8.7")
        #expect(info.timezone == "UTC")
        #expect(info.displayName == "production-1")
        #expect(info.revision == 54_478)
    }

    @Test("a missing patch version reports as Major.Minor only")
    func missingPatchProducesShorterVersion() {
        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 21,
            versionMinor: 11,
            serverRevision: 54_400, // pre-revisionWithVersionPatch
            serverTimezone: .value("Pacific/Auckland"),
            displayName: .unsupported,
            versionPatch: .unsupported
        )
        let metadata = Self.makeMetadata(serverHello: hello, revision: 54_400)
        let info = metadata.publicServerInfo
        #expect(info.version == "21.11")
    }

    @Test("a missing display name falls back to the server name")
    func missingDisplayNameFallsBackToServerName() {
        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24,
            versionMinor: 8,
            serverRevision: 54_478,
            serverTimezone: .value("UTC"),
            displayName: .unsupported,
            versionPatch: .value(0)
        )
        let metadata = Self.makeMetadata(serverHello: hello)
        #expect(metadata.publicServerInfo.displayName == "ClickHouse")
    }

    @Test("a missing timezone defaults to UTC")
    func missingTimezoneDefaultsToUTC() {
        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24,
            versionMinor: 8,
            serverRevision: 54_478,
            serverTimezone: .unsupported,
            displayName: .value("x"),
            versionPatch: .value(0)
        )
        let metadata = Self.makeMetadata(serverHello: hello)
        #expect(metadata.publicServerInfo.timezone == "UTC")
    }

    @Test("the negotiated revision (not the server's reported revision) propagates to the public info")
    func negotiatedRevisionPropagates() {
        let hello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24,
            versionMinor: 8,
            serverRevision: 54_500, // server is newer
            serverTimezone: .value("UTC"),
            displayName: .value("x"),
            versionPatch: .value(0)
        )
        // Negotiated = min(client, server) = 54_400 (client's older revision wins)
        let metadata = Self.makeMetadata(serverHello: hello, revision: 54_400)
        #expect(metadata.publicServerInfo.revision == 54_400)
    }

    @Test("ClickHouseServerInfo equality compares all five fields")
    func serverInfoEquality() {
        let a = ClickHouseServerInfo(name: "X", version: "1.0", timezone: "UTC", displayName: "x", revision: 1)
        let b = ClickHouseServerInfo(name: "X", version: "1.0", timezone: "UTC", displayName: "x", revision: 1)
        #expect(a == b)

        let differentName = ClickHouseServerInfo(name: "Y", version: "1.0", timezone: "UTC", displayName: "x", revision: 1)
        #expect(a != differentName)

        let differentVersion = ClickHouseServerInfo(name: "X", version: "2.0", timezone: "UTC", displayName: "x", revision: 1)
        #expect(a != differentVersion)
    }

}
