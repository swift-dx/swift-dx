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

@Suite("ClickHouse float column")
struct FloatColumnTests {

    @Test("Float32 column round-trips representative values")
    func float32RoundTrip() throws {
        let column = ClickHouseFloat32Column(values: [-1.5, 0, 1.5, .infinity, -.infinity])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == column.rowCount * 4)

        let decoded = try ClickHouseFloat32Column.decode(rows: column.rowCount, from: &buffer)
        #expect(decoded.values.map(\.bitPattern) == column.values.map(\.bitPattern))
        #expect(decoded.spec == .float32)
    }

    @Test("Float64 column round-trips representative values")
    func float64RoundTrip() throws {
        let column = ClickHouseFloat64Column(values: [-1.5, 0, 1.5, .infinity, -.infinity])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == column.rowCount * 8)

        let decoded = try ClickHouseFloat64Column.decode(rows: column.rowCount, from: &buffer)
        #expect(decoded.values.map(\.bitPattern) == column.values.map(\.bitPattern))
        #expect(decoded.spec == .float64)
    }

    @Test("registry decode preserves NaN bit patterns for Float32")
    func registryFloat32NaN() throws {
        let nan = Float32(nan: 0xABCDE, signaling: false)
        let column = ClickHouseFloat32Column(values: [nan])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .float32, rows: 1, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFloat32Column)
        #expect(typed.values.first?.bitPattern == nan.bitPattern)
    }

    @Test("registry decode preserves NaN bit patterns for Float64")
    func registryFloat64NaN() throws {
        let nan = Float64(nan: 0x123456789ABC, signaling: false)
        let column = ClickHouseFloat64Column(values: [nan])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .float64, rows: 1, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFloat64Column)
        #expect(typed.values.first?.bitPattern == nan.bitPattern)
    }

    @Test("truncated Float32 buffer surfaces a typed error")
    func truncatedFloat32Throws() {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8(0), UInt8(0)])
        #expect(throws: ClickHouseError.self) {
            try ClickHouseFloat32Column.decode(rows: 1, from: &buffer)
        }
    }

}
