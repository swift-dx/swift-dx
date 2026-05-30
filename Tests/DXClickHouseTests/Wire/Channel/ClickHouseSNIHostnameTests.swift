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

// SNI hostname derivation: hostnames pass through, IP literals
// (IPv4 or IPv6) become .omitted so the TLS handshake omits SNI per
// RFC 6066. NIOSSL throws `cannotUseIPAddressInSNI` if an IP is
// passed as the serverHostname; this helper short-circuits that
// at the connect site so callers using bare IPs (no DNS, mTLS
// against an internal cluster, etc.) succeed without manual
// CH_TLS_SERVER_NAME plumbing.
@Suite("ClickHouseConnection — SNI hostname derivation")
struct ClickHouseSNIHostnameTests {

    @Test("a plain hostname passes through verbatim")
    func hostnamePassesThrough() {
        #expect(ClickHouseConnection.sniHostname(from: "clickhouse.example.com") == .present("clickhouse.example.com"))
    }

    @Test("a hostname with subdomains passes through verbatim")
    func subdomainHostnamePassesThrough() {
        #expect(ClickHouseConnection.sniHostname(from: "ch.prod.aws-apse2.example.com") == .present("ch.prod.aws-apse2.example.com"))
    }

    @Test("an IPv4 address returns .omitted so SNI is omitted")
    func ipv4ReturnsOmitted() {
        #expect(ClickHouseConnection.sniHostname(from: "192.0.2.10") == .omitted)
        #expect(ClickHouseConnection.sniHostname(from: "127.0.0.1") == .omitted)
        #expect(ClickHouseConnection.sniHostname(from: "192.0.2.1") == .omitted)
    }

    @Test("an IPv4 boundary value (0.0.0.0, 255.255.255.255) returns .omitted")
    func ipv4BoundaryReturnsOmitted() {
        #expect(ClickHouseConnection.sniHostname(from: "0.0.0.0") == .omitted)
        #expect(ClickHouseConnection.sniHostname(from: "255.255.255.255") == .omitted)
    }

    @Test("an IPv6 address returns .omitted so SNI is omitted")
    func ipv6ReturnsOmitted() {
        #expect(ClickHouseConnection.sniHostname(from: "::1") == .omitted)
        #expect(ClickHouseConnection.sniHostname(from: "2001:db8::1") == .omitted)
        #expect(ClickHouseConnection.sniHostname(from: "fe80::1") == .omitted)
    }

    @Test("an IPv4-mapped IPv6 address returns .omitted")
    func ipv4MappedIPv6ReturnsOmitted() {
        #expect(ClickHouseConnection.sniHostname(from: "::ffff:192.0.2.1") == .omitted)
    }

    @Test("a hostname that looks like an octet-by-name passes through")
    func hostnameWithIPLikeNamePartsPassesThrough() {
        // Not a valid IP (extra component, alpha chars), so it's a
        // hostname and SNI must carry it.
        #expect(ClickHouseConnection.sniHostname(from: "10-110-96-51.internal") == .present("10-110-96-51.internal"))
    }

    @Test("an empty string passes through (caller will fail later, not a parser concern)")
    func emptyPassesThrough() {
        #expect(ClickHouseConnection.sniHostname(from: "") == .present(""))
    }

}
