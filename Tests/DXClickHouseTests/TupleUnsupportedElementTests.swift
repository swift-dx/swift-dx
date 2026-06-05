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

// ClickHouseTuple represents each element as raw value bytes tagged with a
// ClickHouseArrayElementType, which covers only String, FixedString, Bool and
// the fixed-width numeric scalars. A Tuple column whose element is anything
// else - DateTime, UUID, Decimal, Nullable, Array, a nested Tuple - cannot be
// represented. The builder used to fall back to ".string with empty bytes"
// for those, so a common Tuple(String, DateTime) (a labelled timestamp)
// decoded with its DateTime element silently turned into an empty string -
// data loss with no error. The decoder must reject such a Tuple instead.
@Suite("a Tuple with a non-representable element is rejected, not silently emptied")
struct TupleUnsupportedElementTests {

    private struct Row: Codable, Sendable {
        let t: ClickHouseTuple
    }

    @Test("Tuple(Int32, DateTime) is rejected rather than dropping the DateTime")
    func rejectsTupleWithDateTimeElement() throws {
        // Column-wise: the Int32 value (42) then the DateTime value (1000s).
        let body: [UInt8] = [42, 0, 0, 0, 232, 3, 0, 0]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["t"],
            columnTypes: ["Tuple(Int32, DateTime)"],
            bodyStart: 0, bodyLength: body.count
        )
        var stage = "none"
        var rejected = false
        do {
            let decoded = try body.withUnsafeBytes { raw in
                try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
            }
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: decoded, rowCount: 1)
        } catch let error as ClickHouseError {
            if case .protocolError(let parsed, let message) = error {
                stage = parsed
                rejected = message.contains("cannot represent")
            }
        }

        #expect(stage == "decoder.tuple")
        #expect(rejected)
    }
}
