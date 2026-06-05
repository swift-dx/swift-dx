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

// An IPv4 column SELECTed as a bare UInt32, or an IPv6 column as 16 raw
// bytes, is unreadable in logs and debugging. Each must render its standard
// textual form: dotted-quad for IPv4, and RFC 5952 canonical lowercase for
// IPv6 (no leading zeros, the single longest run of zero groups collapsed to
// "::", leftmost run on a tie, and a lone zero group never collapsed).
@Suite("the IP address types render their standard textual form")
struct IPAddressDescriptionTests {

    @Test("IPv4 renders dotted-quad with the first octet in the high byte")
    func ipv4Dotted() {
        #expect(ClickHouseIPv4(raw: 0x7F00_0001).description == "127.0.0.1")
        #expect(ClickHouseIPv4(raw: 0xC0A8_0101).description == "192.168.1.1")
        #expect(ClickHouseIPv4(raw: 0).description == "0.0.0.0")
        #expect(ClickHouseIPv4(raw: 0xFFFF_FFFF).description == "255.255.255.255")
        #expect(ClickHouseIPv4(raw: 0x0808_0808).description == "8.8.8.8")
    }

    @Test("IPv6 collapses the longest zero run and drops leading zeros")
    func ipv6Canonical() {
        #expect(Self.ipv6(0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1).description == "2001:db8::1")
        #expect(Self.ipv6(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0).description == "::")
        #expect(Self.ipv6(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1).description == "::1")
        #expect(Self.ipv6(0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0).description == "fe80::")
    }

    @Test("IPv6 leaves a fully populated address uncompressed")
    func ipv6Full() {
        let address = Self.ipv6(0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6)
        #expect(address.description == "2001:db8:1:2:3:4:5:6")
    }

    @Test("IPv6 never collapses a single zero group and picks the longest run")
    func ipv6SingleZeroAndTie() {
        #expect(Self.ipv6(0, 1, 0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7).description == "1:0:2:3:4:5:6:7")
        #expect(Self.ipv6(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 3).description == "0:0:1::2:3")
    }

    private static func ipv6(_ bytes: UInt8...) -> ClickHouseIPv6 {
        ClickHouseIPv6(bytes: bytes)
    }
}
