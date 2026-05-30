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

@Suite("ClickHouse string column")
struct StringColumnTests {

    @Test("string column round-trips multilingual values")
    func multilingualRoundTrip() throws {
        let values = ["", "a", "ClickHouse", "Привет", "新西兰", "🚀"]
        let column = ClickHouseStringColumn(values: values)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseStringColumn.decode(rows: values.count, from: &buffer)
        #expect(decoded.values == values)
        #expect(decoded.spec == .string)
        #expect(buffer.readableBytes == 0)
    }

    @Test("registry decode produces an equivalent string column")
    func registryDecodeMatches() throws {
        let column = ClickHouseStringColumn(values: ["one", "two", "three"])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .string, rows: column.rowCount, from: &buffer)
        let typed = try #require(decoded as? ClickHouseStringColumn)
        #expect(typed.values == column.values)
    }

    @Test("rowCount tracks values regardless of byte length")
    func rowCountIndependentOfByteLength() {
        let column = ClickHouseStringColumn(values: [String(repeating: "x", count: 10_000), "", "a"])
        #expect(column.rowCount == 3)
    }

    @Test("a length prefix that exceeds the buffer surfaces a typed error")
    func corruptedLengthPrefixThrows() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseUVarInt(64)
        buffer.writeBytes(Array("short".utf8))
        #expect(throws: ClickHouseError.self) {
            try ClickHouseStringColumn.decode(rows: 1, from: &buffer)
        }
    }

}
