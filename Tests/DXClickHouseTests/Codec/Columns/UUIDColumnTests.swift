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
import NIOCore
import Testing

@Suite("ClickHouse UUID column")
struct UUIDColumnTests {

    @Test("UUID column round-trips through encode and decode")
    func uuidRoundTrip() throws {
        let values = (0..<16).map { _ in UUID() }
        let column = ClickHouseUUIDColumn(values: values)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == column.rowCount * 16)

        let decoded = try ClickHouseUUIDColumn.decode(rows: column.rowCount, from: &buffer)
        #expect(decoded.values == values)
        #expect(decoded.spec == .uuid)
    }

    @Test("registry dispatches uuid spec to the UUID column")
    func registryDispatchesUUID() throws {
        let values = [
            try #require(UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F")),
            try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
        ]
        let column = ClickHouseUUIDColumn(values: values)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .uuid, rows: column.rowCount, from: &buffer)
        let typed = try #require(decoded as? ClickHouseUUIDColumn)
        #expect(typed.values == values)
    }

    @Test("an empty UUID column consumes zero bytes")
    func emptyUUIDColumn() throws {
        var buffer = ByteBuffer()
        let column = ClickHouseUUIDColumn(values: [])
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseUUIDColumn.decode(rows: 0, from: &buffer)
        #expect(decoded.values.isEmpty)
    }

    @Test("a truncated UUID buffer surfaces a typed error")
    func truncatedUUIDThrows() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0), count: 24))
        #expect(throws: ClickHouseError.self) {
            try ClickHouseUUIDColumn.decode(rows: 2, from: &buffer)
        }
    }

}
