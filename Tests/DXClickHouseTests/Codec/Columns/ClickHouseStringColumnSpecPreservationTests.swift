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

@Suite("ClickHouseStringColumn — spec preservation across String and JSON")
struct ClickHouseStringColumnSpecPreservationTests {

    @Test("default constructor produces a String-typed column")
    func defaultConstructorIsString() {
        let column = ClickHouseStringColumn(values: ["a", "b"])
        #expect(column.spec == .string)
    }

    @Test("explicit spec .json produces a JSON-typed column carrying the same values on the wire")
    func jsonSpecIsPreserved() {
        let column = ClickHouseStringColumn(spec: .json, values: ["{\"a\":1}", "[]"])
        #expect(column.spec == .json)
    }

    @Test("a JSON column writes the JSON type name when serialized via Block")
    func jsonColumnSerializesWithJSONTypeName() throws {
        let block = ClickHouseBlock(
            blockInfo: ClickHouseBlockInfo(),
            columns: [.init(name: "payload", column: ClickHouseStringColumn(spec: .json, values: ["{\"x\":1}"]))]
        )
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: ClickHouseBlock.revisionWithCustomSerialization)

        // Decode and verify the type name carried on the wire is "JSON".
        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: ClickHouseBlock.revisionWithCustomSerialization)
        #expect(decoded.columns.count == 1)
        #expect(decoded.columns[0].name == "payload")
        #expect(decoded.columns[0].column.spec == .json, "spec should round-trip as .json, not collapse to .string")
        #expect(decoded.columns[0].column.spec.typeName == "JSON")
    }

    @Test("a String column round-trips with .string spec preserved")
    func stringColumnRoundTrips() throws {
        let block = ClickHouseBlock(
            blockInfo: ClickHouseBlockInfo(),
            columns: [.init(name: "label", column: ClickHouseStringColumn(values: ["alpha"]))]
        )
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: ClickHouseBlock.revisionWithCustomSerialization)

        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: ClickHouseBlock.revisionWithCustomSerialization)
        #expect(decoded.columns[0].column.spec == .string)
        #expect(decoded.columns[0].column.spec.typeName == "String")
    }

    @Test("INSERT path .json([...]) produces a column with .json spec preserved")
    func insertJsonValuesPreservesSpec() throws {
        let internalColumn = try ClickHouseClient.toInternalColumn(.json(["{\"x\":1}", "{\"y\":2}"]))
        #expect(internalColumn.spec == .json, "INSERT must tag the column as JSON, not String, or the server would reject it")
    }

    @Test("public SELECT mapping returns .json Values for a JSON-spec column")
    func selectMappingPreservesJSONForUserVisibleAPI() throws {
        let column = ClickHouseStringColumn(spec: .json, values: ["{\"a\":1}"])
        let publicColumn = try ClickHouseSelectColumn.from(name: "payload", internalColumn: column)
        #expect(publicColumn.typeName == "JSON")
        guard case .json(let values) = publicColumn.values else {
            Issue.record("expected .json Values case to surface JSON-ness to the user")
            return
        }
        #expect(values == ["{\"a\":1}"])
    }

}
