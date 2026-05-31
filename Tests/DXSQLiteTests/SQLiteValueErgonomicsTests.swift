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

import NIOCore
import Testing
import DXSQLite

@Suite("DXSQLite value ergonomics")
struct SQLiteValueErgonomicsTests {

    struct Meta: Encodable {
        let tags: [String]
    }

    @Test("literals build the matching SQLite values")
    func literals() {
        let values: [SQLiteValue] = ["Ada", 42, 2.5, true]
        #expect(values == [.text("Ada"), .integer(42), .real(2.5), .integer(1)])
    }

    @Test("the json factory encodes an Encodable into a text value")
    func jsonValue() throws {
        let value = try SQLiteValue.json(Meta(tags: ["a", "b"]))
        #expect(value == .text("{\"tags\":[\"a\",\"b\"]}"))
    }

    @Test("a byte buffer round-trips through a blob value")
    func byteBuffer() throws {
        let value = SQLiteValue(blob: ByteBuffer(bytes: [1, 2, 3]))
        #expect(value == .blob([1, 2, 3]))
        let buffer = try value.byteBuffer()
        #expect(Array(buffer.readableBytesView) == [1, 2, 3])
    }
}
