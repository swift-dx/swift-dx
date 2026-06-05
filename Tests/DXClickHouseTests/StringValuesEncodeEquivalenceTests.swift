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

// The columnar insert fast path serializes a String column through the
// `.stringValues([String])` variant, which streams each value's utf8 straight to
// the wire instead of first materializing a [UInt8] per value. The wire bytes
// must be identical to the original `.string([[UInt8]])` path; a divergence
// would silently corrupt every inserted String. This pins byte-for-byte
// equality across empty, ASCII, multi-byte utf8, embedded-NUL, and long values.
@Suite("stringValues encodes byte-identically to the [[UInt8]] String column")
struct StringValuesEncodeEquivalenceTests {

    @Test("the two String column representations produce the same data packet")
    func stringValuesMatchesStringBytes() throws {
        let values = [
            "",
            "a",
            "row_123",
            "café ☕ — multi-byte",
            String(decoding: [0x68, 0x00, 0x69], as: UTF8.self),
            String(repeating: "x", count: 300),
        ]
        let revision = ClickHouseQueryBuilder.revision

        let viaBytes = [ClickHouseNamedColumn(name: "s", column: .string(values.map { Array($0.utf8) }))]
        let viaValues = [ClickHouseNamedColumn(name: "s", column: .stringValues(values))]

        let fromBytes = try ClickHouseBlockWriter.encodeDataPacketTerminated(columns: viaBytes, revision: revision)
        let fromValues = try ClickHouseBlockWriter.encodeDataPacketTerminated(columns: viaValues, revision: revision)

        #expect(fromBytes == fromValues)
    }

    @Test("an empty stringValues column matches an empty [[UInt8]] column")
    func emptyColumnsMatch() throws {
        let revision = ClickHouseQueryBuilder.revision
        let viaBytes = [ClickHouseNamedColumn(name: "s", column: .string([]))]
        let viaValues = [ClickHouseNamedColumn(name: "s", column: .stringValues([]))]
        let fromBytes = try ClickHouseBlockWriter.encodeDataPacketTerminated(columns: viaBytes, revision: revision)
        let fromValues = try ClickHouseBlockWriter.encodeDataPacketTerminated(columns: viaValues, revision: revision)
        #expect(fromBytes == fromValues)
    }
}
