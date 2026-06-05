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

import DXClickHouse
import Foundation
import Testing

@Suite("DXClickHouse FixedString column")
struct ClickHouseFixedStringTests {

    struct Row: Codable, Sendable, Equatable {
        let id: ClickHouseFixedString
    }

    @Test("encoder right-pads content with zeros to the fixed length")
    func encodesPaddedColumn() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(id: ClickHouseFixedString("abc", length: 5)),
            Row(id: ClickHouseFixedString(bytes: [1, 2, 3, 4, 5], length: 5)),
        ])
        #expect(columns.count == 1)
        #expect(columns[0].name == "id")
        #expect(columns[0].column.typeName == "FixedString(5)")
        switch columns[0].column {
        case .fixedString(let values, let length):
            #expect(length == 5)
            #expect(values == [[97, 98, 99, 0, 0], [1, 2, 3, 4, 5]])
        default:
            Issue.record("expected a fixedString column, got \(columns[0].column.typeName)")
        }
    }

    @Test("block writer emits exactly length bytes per row, zero-padded")
    func blockBytesAreFixedWidth() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(id: ClickHouseFixedString("abc", length: 5)),
        ])
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        #expect(Self.contains(packet, [97, 98, 99, 0, 0]))
    }

    @Test("a value longer than the fixed length is rejected with a typed error")
    func overflowThrows() {
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try ClickHouseRowEncoder().encode([
                Row(id: ClickHouseFixedString("toolong", length: 3)),
            ])
        } catch let error {
            caught = error
        }
        switch caught {
        case .protocolError(let stage, _):
            #expect(stage == "encoder.fixedString")
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .queryFailed, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            Issue.record("expected protocolError, got \(caught)")
        }
    }

    @Test("decode returns the full fixed-width bytes including padding")
    func decodeRoundTrip() throws {
        let columns: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "id", column: .fixedString([[97, 98, 99, 0, 0]], length: 5)),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(rows == [Row(id: ClickHouseFixedString(bytes: [97, 98, 99, 0, 0], length: 5))])
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    private enum EncodeOutcome: Sendable, Equatable {
        case succeeded
        case rejected(stage: String)
        case otherError(String)
    }

    private static func encodeOutcome(of column: ClickHouseTypedColumn) -> EncodeOutcome {
        let columns = [ClickHouseNamedColumn(name: "id", column: column)]
        do {
            _ = try ClickHouseBlockWriter.encodeDataPacket(
                columns: columns,
                revision: ClickHouseBlockWriter.revisionWithCustomSerialization
            )
            return .succeeded
        } catch let error {
            if case .protocolError(let stage, _) = error { return .rejected(stage: stage) }
            return .otherError(String(describing: error))
        }
    }

    private static func bytes(count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 & 0xFF) }
    }

    @Test("block writer rejects an over-length FixedString instead of silently truncating")
    func blockWriterRejectsOverlongFixedString() {
        let overlong = Self.bytes(count: 45)
        let outcome = Self.encodeOutcome(of: .fixedString([overlong], length: 44))
        #expect(outcome == .rejected(stage: "blockWriter.fixedString"))
    }

    @Test("block writer rejects an over-length LowCardinality(FixedString) element")
    func blockWriterRejectsOverlongLowCardinalityFixedString() {
        let overlong = Self.bytes(count: 45)
        let outcome = Self.encodeOutcome(of: .lowCardinality([overlong], inner: .fixedString(length: 44)))
        #expect(outcome == .rejected(stage: "blockWriter.fixedString"))
    }

    @Test("block writer rejects an over-length Array(FixedString) element")
    func blockWriterRejectsOverlongArrayFixedString() {
        let overlong = Self.bytes(count: 45)
        let outcome = Self.encodeOutcome(of: .array([[overlong]], element: .fixedString(length: 44)))
        #expect(outcome == .rejected(stage: "blockWriter.fixedString"))
    }

    @Test("block writer still zero-pads an under-length FixedString without error")
    func blockWriterPadsUnderlongFixedString() {
        let outcome = Self.encodeOutcome(of: .fixedString([[1, 2, 3]], length: 8))
        #expect(outcome == .succeeded)
    }
}
