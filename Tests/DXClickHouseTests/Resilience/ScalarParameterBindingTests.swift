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
import Testing

// `select`/`selectAll` accept server-side `{name:Type}` parameter
// bindings, the injection-safe way to pass values into a query. `scalar`
// (single-value reads) and `execute` (DDL/DML) historically dropped them
// — there was no `parameters:` argument, so a caller binding a value to a
// single-value aggregate or a parameterized DELETE was forced into SQL
// string interpolation, the exact injection vector parameters exist to
// remove. These tests drive a real client against an in-process server
// and assert the bound parameter is actually transmitted on the wire.
@Suite("scalar and execute transmit bound query parameters")
struct ScalarParameterBindingTests {

    // Data packet: one UInt8 column with a single row carrying `value`,
    // then EndOfStream. The scalar path renames the column internally, so
    // its name here is irrelevant.
    private static func singleUInt8BlockThenEndOfStream(value: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("result", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        bytes.append(value)
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    // The wire encoding of a single parameter triple: name string, the
    // Custom flag UVarInt, then value string. Searching the captured
    // request for this exact subsequence proves the parameter was sent
    // (the SQL text alone never contains this byte pattern).
    private static func parameterTriple(name: String, value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeString(name, into: &bytes)
        ClickHouseWire.writeUVarInt(ClickHouseQuerySettings.flagCustom, into: &bytes)
        ClickHouseWire.writeString(value, into: &bytes)
        return bytes
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    @Test("scalar binds a parameter and transmits it on the wire", .timeLimit(.minutes(1)))
    func scalarTransmitsParameter() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,
                .reply(Self.singleUInt8BlockThenEndOfStream(value: 42))
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let value = try await client.scalar(
            "SELECT {n:UInt8}",
            as: UInt8.self,
            parameters: ClickHouseQueryParameters([.init(name: "n", value: "42")])
        )
        await client.close()
        server.finished.wait()

        #expect(value == 42)
        let request = try #require(server.capturedRequests.first)
        #expect(Self.contains(request, Self.parameterTriple(name: "n", value: "42")))
    }

    @Test("execute binds a parameter and transmits it on the wire", .timeLimit(.minutes(1)))
    func executeTransmitsParameter() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,
                .reply([0x05])
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        try await client.execute(
            "ALTER TABLE events DELETE WHERE id = {id:UInt64}",
            parameters: ClickHouseQueryParameters([.init(name: "id", value: "7")])
        )
        await client.close()
        server.finished.wait()

        let request = try #require(server.capturedRequests.first)
        #expect(Self.contains(request, Self.parameterTriple(name: "id", value: "7")))
    }
}
