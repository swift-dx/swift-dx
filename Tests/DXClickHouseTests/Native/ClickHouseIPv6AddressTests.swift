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

@Suite("ClickHouseIPv6Address — typed wrapper over the 16-byte raw value")
struct ClickHouseIPv6AddressTests {

    // MARK: - Construction from raw Data

    @Test("init(_ rawValue:) accepts exactly 16 bytes")
    func initFromRawValue() {
        let bytes = Data(repeating: 0xAB, count: 16)
        let address = ClickHouseIPv6Address(bytes)
        #expect(address?.rawValue == bytes)
    }

    @Test("init(_ rawValue:) returns nil for input shorter than 16 bytes")
    func initRejectsShortData() {
        let short = Data(repeating: 0, count: 15)
        #expect(ClickHouseIPv6Address(short) == nil)
    }

    @Test("init(_ rawValue:) returns nil for input longer than 16 bytes")
    func initRejectsLongData() {
        let long = Data(repeating: 0, count: 17)
        #expect(ClickHouseIPv6Address(long) == nil)
    }

    @Test("init(_ rawValue:) returns nil for empty data")
    func initRejectsEmptyData() {
        #expect(ClickHouseIPv6Address(Data()) == nil)
    }

    // MARK: - String parsing

    @Test("init?(string:) parses :: (all-zero address)")
    func parseAllZeros() {
        let address = ClickHouseIPv6Address(string: "::")
        #expect(address?.rawValue == Data(repeating: 0, count: 16))
    }

    @Test("init?(string:) parses ::1 (loopback)")
    func parseLoopback() {
        let address = ClickHouseIPv6Address(string: "::1")
        var expected = Data(repeating: 0, count: 16)
        expected[15] = 1
        #expect(address?.rawValue == expected)
    }

    @Test("init?(string:) parses a fully expanded address")
    func parseFullyExpanded() {
        let address = ClickHouseIPv6Address(string: "2001:0db8:0000:0000:0000:0000:0000:0001")
        var expected = Data(repeating: 0, count: 16)
        expected[0] = 0x20; expected[1] = 0x01
        expected[2] = 0x0D; expected[3] = 0xB8
        expected[15] = 0x01
        #expect(address?.rawValue == expected)
    }

    @Test("init?(string:) parses zero-compressed form")
    func parseZeroCompressed() {
        let viaCompressed = ClickHouseIPv6Address(string: "2001:db8::1")
        let viaExpanded = ClickHouseIPv6Address(string: "2001:0db8:0000:0000:0000:0000:0000:0001")
        #expect(viaCompressed == viaExpanded)
    }

    @Test("init?(string:) parses IPv4-mapped form ::ffff:192.0.2.1")
    func parseIPv4Mapped() {
        let address = ClickHouseIPv6Address(string: "::ffff:192.0.2.1")
        var expected = Data(repeating: 0, count: 16)
        expected[10] = 0xFF; expected[11] = 0xFF
        expected[12] = 192; expected[13] = 0; expected[14] = 2; expected[15] = 1
        #expect(address?.rawValue == expected)
    }

    @Test("init?(string:) parses real-world public DNS addresses")
    func parsePublicResolverAddresses() {
        // Google: 2001:4860:4860::8888
        let google = ClickHouseIPv6Address(string: "2001:4860:4860::8888")
        var googleBytes = Data(repeating: 0, count: 16)
        googleBytes[0] = 0x20; googleBytes[1] = 0x01
        googleBytes[2] = 0x48; googleBytes[3] = 0x60
        googleBytes[4] = 0x48; googleBytes[5] = 0x60
        googleBytes[14] = 0x88; googleBytes[15] = 0x88
        #expect(google?.rawValue == googleBytes)

        // Cloudflare: 2606:4700:4700::1111
        let cloudflare = ClickHouseIPv6Address(string: "2606:4700:4700::1111")
        var cfBytes = Data(repeating: 0, count: 16)
        cfBytes[0] = 0x26; cfBytes[1] = 0x06
        cfBytes[2] = 0x47; cfBytes[3] = 0x00
        cfBytes[4] = 0x47; cfBytes[5] = 0x00
        cfBytes[14] = 0x11; cfBytes[15] = 0x11
        #expect(cloudflare?.rawValue == cfBytes)
    }

    @Test("init?(string:) returns nil for malformed input")
    func parseRejectsMalformedInput() {
        #expect(ClickHouseIPv6Address(string: "") == nil)
        #expect(ClickHouseIPv6Address(string: "not-an-ipv6") == nil)
        #expect(ClickHouseIPv6Address(string: "192.0.2.1") == nil, "IPv4 form alone isn't IPv6")
        #expect(ClickHouseIPv6Address(string: "2001:db8") == nil, "incomplete groups")
        #expect(ClickHouseIPv6Address(string: "2001:db8::1::2") == nil, "two :: are illegal")
        #expect(ClickHouseIPv6Address(string: "gggg::1") == nil, "non-hex chars")
    }

    // MARK: - String formatting

    @Test("stringValue formats the all-zero address as ::")
    func formatAllZeros() throws {
        #expect(try ClickHouseIPv6Address.zero.stringValue() == "::")
    }

    @Test("stringValue formats ::1 for the loopback")
    func formatLoopback() throws {
        #expect(try ClickHouseIPv6Address.loopback.stringValue() == "::1")
    }

    @Test("stringValue uses lowercase hex with zero-compression")
    func formatLowercaseAndCompressed() throws {
        let address = ClickHouseIPv6Address(string: "2001:0DB8:0000:0000:0000:0000:0000:0001")!
        #expect(try address.stringValue() == "2001:db8::1", "lowercase + compressed")
    }

    @Test("stringValue formats public-resolver addresses canonically")
    func formatPublicResolvers() throws {
        let google = try #require(ClickHouseIPv6Address(string: "2001:4860:4860:0000:0000:0000:0000:8888"))
        #expect(try google.stringValue() == "2001:4860:4860::8888")
        let cloudflare = try #require(ClickHouseIPv6Address(string: "2606:4700:4700:0000:0000:0000:0000:1111"))
        #expect(try cloudflare.stringValue() == "2606:4700:4700::1111")
    }

    // MARK: - Round-trip

    @Test("init?(string:) and stringValue round-trip across all canonical forms")
    func roundTripPreservesAddress() throws {
        let inputs = ["::", "::1", "2001:db8::1", "2001:4860:4860::8888", "::ffff:192.0.2.1"]
        for input in inputs {
            let parsed = try #require(ClickHouseIPv6Address(string: input))
            let formatted = try parsed.stringValue()
            let reparsed = try #require(ClickHouseIPv6Address(string: formatted))
            let reformatted = try reparsed.stringValue()
            #expect(parsed == reparsed, "\(input) → \(formatted) → \(reformatted)")
        }
    }

    // MARK: - Static literals

    @Test(".zero and .loopback static literals match canonical raw bytes")
    func staticLiterals() {
        #expect(ClickHouseIPv6Address.zero.rawValue == Data(repeating: 0, count: 16))

        var loopbackExpected = Data(repeating: 0, count: 16)
        loopbackExpected[15] = 1
        #expect(ClickHouseIPv6Address.loopback.rawValue == loopbackExpected)
    }

    // MARK: - Equatable / Hashable

    @Test("Equatable and Hashable identity over rawValue")
    func equatableAndHashable() {
        let a = ClickHouseIPv6Address(string: "2001:db8::1")!
        let b = ClickHouseIPv6Address(string: "2001:0db8:0000:0000:0000:0000:0000:0001")!
        let c = ClickHouseIPv6Address(string: "2001:db8::2")!
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    // MARK: - Interop with the public Values .ipv6 case

    @Test("the public Values .ipv6 case interoperates with the typed wrapper via .rawValue")
    func interopWithIPv6ValuesCase() throws {
        let addresses: [ClickHouseIPv6Address] = [
            ClickHouseIPv6Address.loopback,
            ClickHouseIPv6Address(string: "2001:db8::1")!
        ]
        let values = ClickHouseColumnEntry.Values.ipv6(addresses.map(\.rawValue))
        guard case .ipv6(let raws) = values else {
            Issue.record("expected .ipv6 case")
            return
        }
        let restored = raws.compactMap(ClickHouseIPv6Address.init)
        #expect(restored.count == addresses.count)
        #expect(restored == addresses)
        #expect(try restored.map { try $0.stringValue() } == ["::1", "2001:db8::1"])
    }

}
