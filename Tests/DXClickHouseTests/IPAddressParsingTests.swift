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
import Testing

// IP columns are commonly inserted from text (log ingestion). The address
// types could render to a string (description) but not parse from one, so a
// caller had to hand-pack the raw UInt32 / 16 bytes. init(_:) parses the
// standard textual forms - dotted-quad for IPv4 and RFC 4291 (including "::"
// compression) for IPv6 - and round-trips with the canonical description.
@Suite("the IP address types parse their standard textual form")
struct IPAddressParsingTests {

    @Test("IPv4 parses dotted-quad and round-trips through description")
    func ipv4Parses() throws {
        #expect(try ClickHouseIPv4("127.0.0.1").raw == 0x7F00_0001)
        #expect(try ClickHouseIPv4("0.0.0.0").raw == 0)
        #expect(try ClickHouseIPv4("255.255.255.255").raw == 0xFFFF_FFFF)
        #expect(try ClickHouseIPv4("192.168.1.1").description == "192.168.1.1")
    }

    @Test("an invalid IPv4 string is rejected")
    func ipv4Rejects() {
        for bad in ["256.0.0.1", "1.2.3", "1.2.3.4.5", "1.2.3.x", "", "1.2.3.-1"] {
            #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv4(bad) }
        }
    }

    @Test("IPv6 parses canonical and compressed forms, round-tripping")
    func ipv6Parses() throws {
        for canonical in ["2001:db8::1", "::1", "::", "fe80::", "2001:db8:1:2:3:4:5:6"] {
            #expect(try ClickHouseIPv6(canonical).description == canonical)
        }
        // An uncompressed all-explicit form parses to the same 16 bytes.
        let explicit = try ClickHouseIPv6("2001:0db8:0:0:0:0:0:1")
        #expect(explicit.description == "2001:db8::1")
    }

    @Test("an invalid IPv6 string is rejected")
    func ipv6Rejects() {
        for bad in ["gggg::", "1:2:3", "1::2::3", "12345::", "2001:db8:1:2:3:4:5:6:7", ""] {
            #expect(throws: ClickHouseError.self) { _ = try ClickHouseIPv6(bad) }
        }
    }
}
