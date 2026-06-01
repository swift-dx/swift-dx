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

import Foundation

/// A PostgreSQL `inet` or `cidr` value: an IPv4 or IPv6 host or network address
/// with a prefix length. The Swift standard library has no IP-address type, so
/// this carries the raw address bytes (four for IPv4, sixteen for IPv6) and the
/// prefix; ``description`` renders the canonical `address/prefix` text.
public struct PostgresInet: Sendable, Equatable {

    public let isIPv6: Bool
    public let address: [UInt8]
    public let prefixLength: UInt8
    public let isCIDR: Bool

    public init(isIPv6: Bool, address: [UInt8], prefixLength: UInt8, isCIDR: Bool) {
        self.isIPv6 = isIPv6
        self.address = address
        self.prefixLength = prefixLength
        self.isCIDR = isCIDR
    }

    private var host: String {
        isIPv6 ? PostgresInet.ipv6Text(address) : PostgresInet.ipv4Text(address)
    }

    private static func ipv4Text(_ address: [UInt8]) -> String {
        address.map { String($0) }.joined(separator: ".")
    }

    private static func ipv6Text(_ address: [UInt8]) -> String {
        stride(from: 0, to: address.count, by: 2)
            .map { String(format: "%x", Int(address[$0]) << 8 | Int(address[$0 + 1])) }
            .joined(separator: ":")
    }
}

extension PostgresInet: CustomStringConvertible {

    public var description: String {
        "\(host)/\(prefixLength)"
    }
}
