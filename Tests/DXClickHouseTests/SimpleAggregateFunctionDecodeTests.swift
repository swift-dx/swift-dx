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

// SimpleAggregateFunction(func, T) stores its value wire-identically to T.
// Type normalization is the connection layer's job: ClickHouseGeoTypeName
// .expand rewrites SimpleAggregateFunction (and the geo and Nested aliases)
// to the underlying type before any column is materialised, so the decoder
// only ever sees the expanded type. The decoder therefore rejects an
// unexpanded SimpleAggregateFunction, exactly as it rejects an unexpanded
// geo alias — there is one normalization source, not two. The end-to-end
// read path is covered by SimpleAggregateFunctionSelectTests.
@Suite("SimpleAggregateFunction normalizes at the connection layer, not the decoder")
struct SimpleAggregateFunctionDecodeTests {

    struct UIntRow: Codable, Sendable, Equatable { let total: UInt64 }

    @Test("expand rewrites SimpleAggregateFunction to its underlying value type")
    func expandUnwrapsValueType() {
        #expect(ClickHouseGeoTypeName.expand("SimpleAggregateFunction(sum, UInt64)") == "UInt64")
    }

    @Test("expand keeps the value type's own commas, e.g. a Map value type")
    func expandKeepsInnerCommas() {
        #expect(ClickHouseGeoTypeName.expand("SimpleAggregateFunction(sumMap, Map(String, UInt64))") == "Map(String, UInt64)")
    }

    @Test("the decoder rejects an unexpanded SimpleAggregateFunction type")
    func decoderRejectsUnexpanded() {
        let body: [UInt8] = [42, 0, 0, 0, 0, 0, 0, 0]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["total"],
            columnTypes: ["SimpleAggregateFunction(sum, UInt64)"],
            bodyStart: 0, bodyLength: body.count
        )
        #expect(throws: ClickHouseError.self) {
            _ = try body.withUnsafeBytes { raw in
                try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
            }
        }
    }
}
