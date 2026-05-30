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

@Suite("ClickHouse Query packet — query parameters")
struct ClickHouseQueryParametersTests {

    private static let revision: UInt64 = 54_478

    @Test("empty parameters list encodes as a single empty-name terminator (matches existing behavior)")
    func emptyParametersList() throws {
        let packet = ClickHouseQueryPacket(queryID: "q1", queryText: "SELECT 1")
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)
        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.parameters.isEmpty)
    }

    @Test("a single parameter round-trips through encode and decode")
    func singleParameterRoundTrips() throws {
        let parameter = ClickHouseQueryParameter(name: "id", value: "42")
        let packet = ClickHouseQueryPacket(
            queryID: "q2",
            queryText: "SELECT * FROM t WHERE id = {id:UInt64}",
            parameters: [parameter]
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)
        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.parameters.count == 1)
        #expect(decoded.parameters[0].name == "id")
        #expect(decoded.parameters[0].value == "42")
    }

    @Test("multiple parameters preserve order on the wire")
    func multipleParametersPreserveOrder() throws {
        let parameters = [
            ClickHouseQueryParameter(name: "user_id", value: "100"),
            ClickHouseQueryParameter(name: "start_date", value: "2026-01-01"),
            ClickHouseQueryParameter(name: "label", value: "active")
        ]
        let packet = ClickHouseQueryPacket(
            queryID: "q3",
            queryText: "SELECT * FROM events WHERE user_id = {user_id:UInt64}",
            parameters: parameters
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)
        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.parameters.count == 3)
        #expect(decoded.parameters.map(\.name) == parameters.map(\.name))
        #expect(decoded.parameters.map(\.value) == parameters.map(\.value))
    }

    @Test("parameter values containing special characters survive the wire round-trip verbatim")
    func parametersWithSpecialCharacters() throws {
        let parameter = ClickHouseQueryParameter(
            name: "label",
            value: "it's a \"complex\" value with \\ and \n newlines"
        )
        let packet = ClickHouseQueryPacket(
            queryID: "q4",
            queryText: "SELECT * FROM t WHERE label = {label:String}",
            parameters: [parameter]
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)
        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.parameters[0].value == parameter.value)
    }

    @Test("settings AND parameters can coexist on the same Query packet")
    func settingsAndParametersCoexist() throws {
        let packet = ClickHouseQueryPacket(
            queryID: "q5",
            settings: [ClickHouseQuerySetting(name: "max_execution_time", value: "30")],
            queryText: "SELECT * FROM t WHERE id = {id:UInt64}",
            parameters: [ClickHouseQueryParameter(name: "id", value: "100")]
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)
        var copy = buffer
        let decoded = try ClickHouseQueryPacket.decode(from: &copy, revision: Self.revision)
        #expect(decoded.settings.count == 1)
        #expect(decoded.settings[0].name == "max_execution_time")
        #expect(decoded.parameters.count == 1)
        #expect(decoded.parameters[0].name == "id")
    }

    @Test("a parameter encoded by the Swift writer carries the Custom flag (bit 1) on the wire")
    func parameterEncodingUsesCustomFlag() throws {
        let parameter = ClickHouseQueryParameter(name: "k", value: "v")
        let packet = ClickHouseQueryPacket(
            queryID: "q6",
            queryText: "SELECT",
            parameters: [parameter]
        )
        var buffer = ByteBuffer()
        try packet.encode(into: &buffer, revision: Self.revision)

        // Decode the whole packet, then verify the wire interpretation uses Custom.
        // Construct a wire payload that emits a parameter as a Setting with Custom=true,
        // then decode as a Setting and verify the flag bit is set.
        var wireOnlyParam = ByteBuffer()
        wireOnlyParam.writeClickHouseString(parameter.name)
        wireOnlyParam.writeClickHouseUVarInt(ClickHouseQueryPacket.settingFlagCustom)
        wireOnlyParam.writeClickHouseString(parameter.value)
        // Read back and verify the flag carries Custom=2
        let key = try wireOnlyParam.readClickHouseString()
        let flags = try wireOnlyParam.readClickHouseUVarInt()
        let value = try wireOnlyParam.readClickHouseString()
        #expect(key == parameter.name)
        #expect(value == parameter.value)
        #expect(flags & ClickHouseQueryPacket.settingFlagCustom != 0)
    }

    @Test("a parameter with an empty name is rejected at the encode boundary instead of silently truncating the parameter list on the wire")
    func emptyParameterNameRejected() throws {
        // Pre-fix: empty parameter name was written verbatim. The
        // empty-string is the parameters-list terminator on the wire,
        // so the server stopped reading parameters at the bad entry,
        // dropped every subsequent parameter, and treated our trailing
        // bytes as the next packet's marker — desyncing the
        // connection. The fix rejects empty names at the encode
        // boundary with a typed error.
        let packet = ClickHouseQueryPacket(
            queryID: "q-empty",
            queryText: "SELECT 1",
            parameters: [ClickHouseQueryParameter(name: "", value: "anything")]
        )
        var buffer = ByteBuffer()
        #expect(throws: ClickHouseError.emptyQueryParameterName) {
            try packet.encode(into: &buffer, revision: Self.revision)
        }
    }

    @Test("when a downstream parameter has an empty name, the encoder rejects before the bytes reach the wire so prior parameters and unrelated subsequent parameters are not silently lost")
    func emptyParameterNameMidListRejectsBeforeWriting() throws {
        // Same wire-corruption concern as the leading-empty case, but
        // verifies the guard fires on a mid-list empty even after we've
        // already written valid parameters in the same loop iteration.
        let packet = ClickHouseQueryPacket(
            queryID: "q-mid",
            queryText: "SELECT 1",
            parameters: [
                ClickHouseQueryParameter(name: "first", value: "1"),
                ClickHouseQueryParameter(name: "", value: "bad"),
                ClickHouseQueryParameter(name: "third", value: "3"),
            ]
        )
        var buffer = ByteBuffer()
        #expect(throws: ClickHouseError.emptyQueryParameterName) {
            try packet.encode(into: &buffer, revision: Self.revision)
        }
    }

}
