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

// ClickHouse Enum element names are string literals and legitimately
// contain apostrophes ("O'Brien", "can't", "won't fix") and backslashes.
// Such a name must be backslash-escaped in the rendered type declaration
// and un-escaped on decode, so the value round-trips. Before this, the
// encoder rejected any name with a quote, and the decoder stopped reading
// a name at the first quote — making a SELECT from an existing table whose
// Enum had an apostrophe fail to decode entirely.
@Suite("Enum element names with quotes and backslashes round-trip via escaping")
struct EnumQuotedNameTests {

    private struct Enum8Row: Codable, Sendable, Equatable {
        let label: ClickHouseEnum8
    }

    @Test("render backslash-escapes a single quote in the element name")
    func renderEscapesQuote() {
        let rendered = ClickHouseEnumMapping.render([ClickHouseEnumPair(name: "can't", value: 1)])
        #expect(rendered == "'can\\'t' = 1")
    }

    @Test("render backslash-escapes a literal backslash in the element name")
    func renderEscapesBackslash() {
        let rendered = ClickHouseEnumMapping.render([ClickHouseEnumPair(name: "a\\b", value: 1)])
        #expect(rendered == "'a\\\\b' = 1")
    }

    @Test("encoding an Enum8 with an apostrophe name now succeeds and escapes the type name")
    func encodeAcceptsQuotedName() throws {
        let mapping = [
            ClickHouseEnumPair(name: "can't", value: 1),
            ClickHouseEnumPair(name: "ok", value: 2),
        ]
        let columns = try ClickHouseRowEncoder().encode([
            Enum8Row(label: ClickHouseEnum8(value: 1, mapping: mapping)),
        ])
        #expect(columns[0].column.typeName == "Enum8('can\\'t' = 1, 'ok' = 2)")
    }

    @Test("decoder un-escapes an escaped quote in a server-sent Enum type")
    func decodeUnescapesQuotedName() throws {
        let body: [UInt8] = [1, 2]
        let block = ClickHouseBlock(
            rowCount: 2, columnCount: 1,
            columnNames: ["label"],
            columnTypes: ["Enum8('can\\'t' = 1, 'ok' = 2)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        switch columns[0].column {
        case .enum8(let values, let mapping):
            #expect(values == [1, 2])
            #expect(mapping == [
                ClickHouseEnumPair(name: "can't", value: 1),
                ClickHouseEnumPair(name: "ok", value: 2),
            ])
        default:
            Issue.record("expected enum8 column, got \(columns[0].column.typeName)")
        }
    }

    @Test("a quoted-name Enum round-trips encode -> type name -> decode")
    func quotedNameRoundTrips() throws {
        let mapping = [
            ClickHouseEnumPair(name: "won't fix", value: 1),
            ClickHouseEnumPair(name: "O'Brien", value: 2),
        ]
        let columns = try ClickHouseRowEncoder().encode([
            Enum8Row(label: ClickHouseEnum8(value: 2, mapping: mapping)),
            Enum8Row(label: ClickHouseEnum8(value: 1, mapping: mapping)),
        ])
        let typeName = columns[0].column.typeName

        let body: [UInt8] = [2, 1]
        let block = ClickHouseBlock(
            rowCount: 2, columnCount: 1,
            columnNames: ["label"],
            columnTypes: [typeName],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        switch decoded[0].column {
        case .enum8(_, let decodedMapping):
            #expect(decodedMapping == mapping)
        default:
            Issue.record("expected enum8 column, got \(decoded[0].column.typeName)")
        }
    }
}
