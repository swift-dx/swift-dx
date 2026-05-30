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
import Testing

@Suite("ClickHouseIPv4Address — typed wrapper over the UInt32 raw value")
struct ClickHouseIPv4AddressTests {

    @Test("init from raw UInt32 stores the value verbatim")
    func initFromRawValue() {
        #expect(ClickHouseIPv4Address(0x7F00_0001).rawValue == 0x7F00_0001)
        #expect(ClickHouseIPv4Address(0).rawValue == 0)
    }

    @Test("init(string:) parses standard dotted-quad addresses")
    func parseStandardFormats() throws {
        #expect(try ClickHouseIPv4Address(string: "0.0.0.0").rawValue == 0)
        #expect(try ClickHouseIPv4Address(string: "127.0.0.1").rawValue == 0x7F00_0001)
        #expect(try ClickHouseIPv4Address(string: "192.0.2.1").rawValue == 0xC000_0201)
        #expect(try ClickHouseIPv4Address(string: "198.51.100.8").rawValue == 0xC633_6408)
        #expect(try ClickHouseIPv4Address(string: "255.255.255.255").rawValue == 0xFFFF_FFFF)
    }

    @Test("init(string:) throws malformedIPv6Address for invalid input")
    func parseRejectsMalformedInput() {
        let invalidInputs = [
            "",
            "127.0.0",
            "127.0.0.1.5",
            "127.0..1",
            "256.0.0.1",
            "abc.def.ghi.jkl",
            "127.0.0.-1"
        ]
        for input in invalidInputs {
            #expect(throws: ClickHouseError.malformedIPv6Address, "expected \(input) to throw") {
                _ = try ClickHouseIPv4Address(string: input)
            }
        }
    }

    @Test("stringValue formats as standard dotted-quad with no leading zeros")
    func stringValueFormatting() {
        #expect(ClickHouseIPv4Address(0).stringValue == "0.0.0.0")
        #expect(ClickHouseIPv4Address(0x7F00_0001).stringValue == "127.0.0.1")
        #expect(ClickHouseIPv4Address(0xC000_0201).stringValue == "192.0.2.1")
        #expect(ClickHouseIPv4Address(0xC633_6408).stringValue == "198.51.100.8")
        #expect(ClickHouseIPv4Address(0xFFFF_FFFF).stringValue == "255.255.255.255")
    }

    @Test("init(string:) and stringValue round-trip exactly for all four octet positions")
    func roundTripPreservesRawValue() throws {
        for raw in [UInt32(0), 1, 0x0102_0304, 0x7F00_0001, 0xC000_0202, UInt32.max] {
            let address = ClickHouseIPv4Address(raw)
            let parsed = try ClickHouseIPv4Address(string: address.stringValue)
            #expect(parsed == address)
            #expect(parsed.rawValue == raw)
        }
    }

    @Test("loopback / zero / broadcast static literals match their canonical raw values")
    func staticLiterals() {
        #expect(ClickHouseIPv4Address.zero.rawValue == 0)
        #expect(ClickHouseIPv4Address.loopback.rawValue == 0x7F00_0001)
        #expect(ClickHouseIPv4Address.loopback.stringValue == "127.0.0.1")
        #expect(ClickHouseIPv4Address.broadcast.rawValue == 0xFFFF_FFFF)
        #expect(ClickHouseIPv4Address.broadcast.stringValue == "255.255.255.255")
    }

    @Test("Equatable and Hashable conformance work as identity over rawValue")
    func equatableAndHashable() throws {
        let a = ClickHouseIPv4Address(0x7F00_0001)
        let b = try ClickHouseIPv4Address(string: "127.0.0.1")
        let c = try ClickHouseIPv4Address(string: "198.51.100.8")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("the public Values .ipv4 case interoperates with the typed wrapper via .rawValue")
    func interopWithIPv4ValuesCase() throws {
        let addresses: [ClickHouseIPv4Address] = [
            try ClickHouseIPv4Address(string: "127.0.0.1"),
            try ClickHouseIPv4Address(string: "198.51.100.8")
        ]
        let values = ClickHouseColumnEntry.Values.ipv4(addresses.map(\.rawValue))
        guard case .ipv4(let raws) = values else {
            Issue.record("expected .ipv4 case")
            return
        }
        let restored = raws.map(ClickHouseIPv4Address.init)
        #expect(restored == addresses)
        #expect(restored.map(\.stringValue) == ["127.0.0.1", "198.51.100.8"])
    }

}
