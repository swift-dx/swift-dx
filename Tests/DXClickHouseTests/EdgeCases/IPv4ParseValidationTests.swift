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

// A dotted-quad IPv4 address has exactly four octets. Parsing a string with
// too few octets must not silently shift a smaller value into place, and too
// many octets must not silently drop the leading octets off the UInt32. Both
// are malformed input and must throw at the parse boundary rather than yield a
// wrong address that a caller would then store or query against.
@Suite("IPv4 string parsing rejects the wrong octet count")
struct IPv4ParseValidationTests {

    @Test("a valid dotted-quad parses to the expected packed value")
    func validParses() throws {
        #expect(try ClickHouseIPv4("1.2.3.4").raw == 0x01020304)
        #expect(try ClickHouseIPv4("0.0.0.0").raw == 0)
        #expect(try ClickHouseIPv4("255.255.255.255").raw == 0xFFFFFFFF)
    }

    @Test("too few octets throws")
    func tooFewOctetsThrows() {
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1.2.3") }
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1.2") }
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1") }
    }

    @Test("too many octets throws")
    func tooManyOctetsThrows() {
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1.2.3.4.5") }
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1.2.3.4.5.6") }
    }

    @Test("out-of-range and empty octets still throw")
    func malformedOctetsThrow() {
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1.2.3.256") }
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4("1.2..4") }
    }
}
