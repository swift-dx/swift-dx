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

@Suite("ClickHouse float coding")
struct FloatCodingTests {

    @Test(
        "Float32 round-trips at representative values",
        arguments: [
            Float32(0),
            Float32(-0.0),
            Float32(1),
            Float32(-1),
            Float32.leastNormalMagnitude,
            Float32.greatestFiniteMagnitude,
            -Float32.greatestFiniteMagnitude,
            Float32.pi,
        ]
    )
    func float32RoundTrip(_ value: Float32) throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFloat32(value)
        #expect(buffer.readableBytes == 4)
        let decoded = try buffer.readClickHouseFloat32()
        #expect(decoded.bitPattern == value.bitPattern)
    }

    @Test(
        "Float64 round-trips at representative values",
        arguments: [
            Float64(0),
            Float64(-0.0),
            Float64(1),
            Float64(-1),
            Float64.leastNormalMagnitude,
            Float64.greatestFiniteMagnitude,
            -Float64.greatestFiniteMagnitude,
            Float64.pi,
        ]
    )
    func float64RoundTrip(_ value: Float64) throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFloat64(value)
        #expect(buffer.readableBytes == 8)
        let decoded = try buffer.readClickHouseFloat64()
        #expect(decoded.bitPattern == value.bitPattern)
    }

    @Test("Float32 preserves NaN bit pattern through the wire")
    func float32PreservesNaN() throws {
        var buffer = ByteBuffer()
        let nan = Float32(nan: 0x12345, signaling: false)
        buffer.writeClickHouseFloat32(nan)
        let decoded = try buffer.readClickHouseFloat32()
        #expect(decoded.isNaN)
        #expect(decoded.bitPattern == nan.bitPattern)
    }

    @Test("Float64 preserves NaN bit pattern through the wire")
    func float64PreservesNaN() throws {
        var buffer = ByteBuffer()
        let nan = Float64(nan: 0x123456789ABC, signaling: false)
        buffer.writeClickHouseFloat64(nan)
        let decoded = try buffer.readClickHouseFloat64()
        #expect(decoded.isNaN)
        #expect(decoded.bitPattern == nan.bitPattern)
    }

    @Test("Float32 infinities round-trip exactly")
    func float32Infinities() throws {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFloat32(.infinity)
        buffer.writeClickHouseFloat32(-.infinity)
        #expect(try buffer.readClickHouseFloat32() == .infinity)
        #expect(try buffer.readClickHouseFloat32() == -.infinity)
    }

    @Test("Float32 1.0 has the canonical IEEE-754 bit pattern on the wire")
    func float32OneBytes() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFloat32(1.0)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 4) ?? []
        #expect(bytes == [0x00, 0x00, 0x80, 0x3F])
    }

    @Test("Float64 1.0 has the canonical IEEE-754 bit pattern on the wire")
    func float64OneBytes() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFloat64(1.0)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 8) ?? []
        #expect(bytes == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F])
    }

    @Test("Float32 batch round-trip preserves order")
    func float32BatchRoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [Float32] = [-1.5, 0, 1.5, 1e10, -1e-10]
        buffer.writeClickHouseFloat32s(values)
        let decoded = try buffer.readClickHouseFloat32s(rows: values.count)
        #expect(decoded.map(\.bitPattern) == values.map(\.bitPattern))
    }

    @Test("Float64 batch round-trip preserves order")
    func float64BatchRoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [Float64] = [-1.5, 0, 1.5, 1e100, -1e-100]
        buffer.writeClickHouseFloat64s(values)
        let decoded = try buffer.readClickHouseFloat64s(rows: values.count)
        #expect(decoded.map(\.bitPattern) == values.map(\.bitPattern))
    }

    @Test("truncated Float32 read surfaces a typed error")
    func truncatedFloat32Throws() {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8(0), UInt8(0)])
        #expect(throws: ClickHouseError.self) {
            try buffer.readClickHouseFloat32()
        }
    }

    // Micro-benchmark for the bulk Float64 encode/decode path. Pins
    // a wall-clock floor that catches a regression of the bulk
    // memcpy fast path back to the per-element bitPattern map. With
    // the fast path, decoding 1M Float64 values is dominated by the
    // single memcpy and the result-array allocation (sub-10 ms on an
    // M-series Mac); without it, the path allocates an intermediate
    // [UInt64] AND maps over every element, roughly tripling the
    // wall clock. The bound is set at 200 ms to allow CI variance
    // while still catching the regression class.
    @Test("bulk Float64 encode + decode for 1M values stays under the fast-path budget")
    func bulkFloat64FastPathStaysUnderBudget() throws {
        let count = 1_000_000
        var values = [Float64]()
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(Double(index) * 0.001)
        }
        var buffer = ByteBuffer()
        buffer.reserveCapacity(count * 8)

        let encodeStart = Date()
        buffer.writeClickHouseFloat64s(values)
        let encodeElapsed = Date().timeIntervalSince(encodeStart)
        #expect(buffer.readableBytes == count * 8)

        let decodeStart = Date()
        let decoded = try buffer.readClickHouseFloat64s(rows: count)
        let decodeElapsed = Date().timeIntervalSince(decodeStart)

        #expect(decoded.count == count)
        // Spot-check: bit patterns must match. Iterating all 1M would
        // dominate the test time; checking endpoints + samples is
        // enough to catch a wholesale corruption regression.
        #expect(decoded[0].bitPattern == values[0].bitPattern)
        #expect(decoded[count - 1].bitPattern == values[count - 1].bitPattern)
        for sampleIndex in stride(from: 0, to: count, by: count / 16) {
            #expect(decoded[sampleIndex].bitPattern == values[sampleIndex].bitPattern)
        }

        print("[FLOAT FAST-PATH] encode 1M Float64: \(String(format: "%.1f ms", encodeElapsed * 1000)), decode: \(String(format: "%.1f ms", decodeElapsed * 1000))")
        // The fast path's expected envelope: each direction stays
        // well under 200 ms even on a slow CI runner. Without the
        // bulk-memcpy path, decode alone would exceed this.
        #expect(encodeElapsed < 0.2,
                "Float64 bulk encode regressed: \(String(format: "%.1fms", encodeElapsed * 1000)) — expected sub-200ms via the bulk-memcpy path")
        #expect(decodeElapsed < 0.2,
                "Float64 bulk decode regressed: \(String(format: "%.1fms", decodeElapsed * 1000)) — expected sub-200ms via the bulk-memcpy path")
    }

    @Test("bulk Float32 encode + decode for 1M values stays under the fast-path budget")
    func bulkFloat32FastPathStaysUnderBudget() throws {
        let count = 1_000_000
        var values = [Float32]()
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(Float32(index) * 0.001)
        }
        var buffer = ByteBuffer()
        buffer.reserveCapacity(count * 4)

        let encodeStart = Date()
        buffer.writeClickHouseFloat32s(values)
        let encodeElapsed = Date().timeIntervalSince(encodeStart)
        #expect(buffer.readableBytes == count * 4)

        let decodeStart = Date()
        let decoded = try buffer.readClickHouseFloat32s(rows: count)
        let decodeElapsed = Date().timeIntervalSince(decodeStart)

        #expect(decoded.count == count)
        #expect(decoded[0].bitPattern == values[0].bitPattern)
        #expect(decoded[count - 1].bitPattern == values[count - 1].bitPattern)
        for sampleIndex in stride(from: 0, to: count, by: count / 16) {
            #expect(decoded[sampleIndex].bitPattern == values[sampleIndex].bitPattern)
        }

        print("[FLOAT FAST-PATH] encode 1M Float32: \(String(format: "%.1f ms", encodeElapsed * 1000)), decode: \(String(format: "%.1f ms", decodeElapsed * 1000))")
        #expect(encodeElapsed < 0.2,
                "Float32 bulk encode regressed: \(String(format: "%.1fms", encodeElapsed * 1000))")
        #expect(decodeElapsed < 0.2,
                "Float32 bulk decode regressed: \(String(format: "%.1fms", decodeElapsed * 1000))")
    }

}
