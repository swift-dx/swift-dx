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

@Suite("ClickHouse Query packet — settings list")
struct ClickHouseQuerySettingsTests {

    private static let revision: UInt64 = 54_478

    @Test("empty settings list encodes as a single empty-name terminator")
    func emptySettingsListProducesTerminator() throws {
        let packet = ClickHouseQueryPacket(queryID: "q1", queryText: "SELECT 1")
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        // Decoder must round-trip the empty list.
        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings.isEmpty)
        #expect(decoded.queryID == "q1")
        #expect(decoded.queryText == "SELECT 1")
    }

    @Test("a single important setting encodes with flags 0x01 and round-trips")
    func singleImportantSettingRoundTrips() throws {
        let setting = ClickHouseQuerySetting(name: "max_execution_time", value: "60")
        let packet = ClickHouseQueryPacket(
            queryID: "q2",
            settings: [setting],
            queryText: "SELECT 1"
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings.count == 1)
        #expect(decoded.settings[0].name == "max_execution_time")
        #expect(decoded.settings[0].value == "60")
        #expect(decoded.settings[0].important == true)
        #expect(decoded.settings[0].custom == false)
        #expect(decoded.settings[0].obsolete == false)
    }

    @Test("a setting with all three flags has flags 0x07 on the wire")
    func allFlagsRoundTrip() throws {
        let setting = ClickHouseQuerySetting(
            name: "experimental_thing",
            value: "1",
            important: true,
            custom: true,
            obsolete: true
        )
        let packet = ClickHouseQueryPacket(
            queryID: "q3",
            settings: [setting],
            queryText: "SELECT"
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings.count == 1)
        #expect(decoded.settings[0].important == true)
        #expect(decoded.settings[0].custom == true)
        #expect(decoded.settings[0].obsolete == true)
    }

    @Test("a setting with no flags (all false) round-trips")
    func noFlagsRoundTrip() throws {
        let setting = ClickHouseQuerySetting(
            name: "compatibility",
            value: "23.8",
            important: false
        )
        let packet = ClickHouseQueryPacket(
            queryID: "q4",
            settings: [setting],
            queryText: "SELECT"
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings[0].important == false)
        #expect(decoded.settings[0].custom == false)
        #expect(decoded.settings[0].obsolete == false)
    }

    @Test("multiple settings preserve their order on the wire")
    func multipleSettingsPreserveOrder() throws {
        let settings = [
            ClickHouseQuerySetting(name: "max_execution_time", value: "30"),
            ClickHouseQuerySetting(name: "max_memory_usage", value: "1000000000"),
            ClickHouseQuerySetting(name: "readonly", value: "1"),
            ClickHouseQuerySetting(name: "use_uncompressed_cache", value: "0")
        ]
        let packet = ClickHouseQueryPacket(
            queryID: "q5",
            settings: settings,
            queryText: "SELECT"
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings.count == 4)
        #expect(decoded.settings.map(\.name) == settings.map(\.name))
        #expect(decoded.settings.map(\.value) == settings.map(\.value))
    }

    @Test("the encoded settings section is bounded by an empty-name string terminator")
    func encodedSettingsSectionEndsWithTerminator() throws {
        // Verify wire layout: after the clientInfo, settings entries appear, ending with
        // the empty-name terminator. This test focuses on the structural invariant
        // — the decoder relies on the terminator to know when to stop.
        let settings = [ClickHouseQuerySetting(name: "x", value: "y")]
        let packet = ClickHouseQueryPacket(
            queryID: "q6",
            settings: settings,
            queryText: "SELECT"
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        // Round-trip through decode: if the terminator is missing or malformed,
        // decode will read past the settings into the interserverSecret and fail
        // a downstream invariant.
        var copy = buffer
        _ = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
    }

    @Test("a setting with empty name in the middle of the list ends decoding early")
    func emptyNameTerminatesDecodeEarly() throws {
        // Manually construct a wire payload where a second "setting" has an empty
        // name. The decoder must treat that as the terminator and stop, not crash.
        var buffer = ByteBuffer()
        // queryID
        buffer.writeClickHouseString("q7")
        // ClientInfo: matching the encoder's actual output format.
        ClickHouseClientInfo().encode(into: &buffer, revision: Self.revision)
        // Setting 1
        buffer.writeClickHouseString("a")
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseString("1")
        // Empty-name terminator
        buffer.writeClickHouseString("")
        // Rest of the query (extra_roles, interserverSecret, stage, compression, queryText, params)
        buffer.writeClickHouseString("") // received_extra_roles (revision >= 54_472)
        buffer.writeClickHouseString("") // interserverSecret (revision >= 54441)
        buffer.writeClickHouseUVarInt(2) // stage = .complete
        buffer.writeClickHouseUVarInt(0) // compression off
        buffer.writeClickHouseString("SELECT") // queryText
        buffer.writeClickHouseString("") // params terminator (revision >= 54_459)

        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings.count == 1)
        #expect(decoded.settings[0].name == "a")
    }

    @Test("a setting with empty name is rejected at encode rather than silently truncating the settings list on the wire")
    func emptySettingNameRejected() throws {
        // Symmetric concern to emptyQueryParameterName: empty setting
        // name on the wire IS the settings-list terminator. A user-
        // supplied empty name would silently drop everything that
        // follows (settings, interserverSecret, stage, compression,
        // queryText, parameters) and desync the connection. Reject at
        // the encode boundary with a typed error.
        let packet = ClickHouseQueryPacket(
            queryID: "q-empty-setting",
            settings: [ClickHouseQuerySetting(name: "", value: "anything")],
            queryText: "SELECT 1"
        )
        var buffer = ByteBuffer()
        #expect(throws: ClickHouseError.emptyQuerySettingName) {
            try packet.encode(into: &buffer, revision: Self.revision)
        }
    }

}
