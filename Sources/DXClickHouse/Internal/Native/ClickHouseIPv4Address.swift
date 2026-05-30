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

// Typed wrapper over the UInt32 representation that ClickHouse uses
// for `IPv4` columns. The raw value is the host-order integer that
// `IPv4StringToNum` produces server-side: `127.0.0.1` becomes
// `0x7F000001`. The wire codec serializes it as a regular UInt32, so
// the rawValue passes straight through.
//
// Pure-Swift parsing/formatting — no `inet_pton` import — keeps this
// type usable on every platform the library targets.
public struct ClickHouseIPv4Address: Sendable, Equatable, Hashable {

    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // Parses the dotted-quad form `"a.b.c.d"`. Throws
    // `ClickHouseError.malformedIPv6Address` for any input that's not
    // exactly four decimal octets in 0…255 separated by `.`. (The error
    // case name reads `IPv6` for historical reasons; it carries the
    // parse-failure semantic for both IPv4 and IPv6 literals.)
    // Leading-zero forms like `"127.0.000.1"` are accepted as long as
    // each octet remains within range.
    public init(string: String) throws(ClickHouseError) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw ClickHouseError.malformedIPv6Address
        }
        switch Self.packOctets(parts: parts) {
        case .packed(let value): self.rawValue = value
        case .invalid: throw ClickHouseError.malformedIPv6Address
        }
    }

    private enum OctetPackResult {

        case packed(UInt32)
        case invalid

    }

    private static func packOctets(parts: [Substring]) -> OctetPackResult {
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, let octet = UInt8(part) else { return .invalid }
            result = (result << 8) | UInt32(octet)
        }
        return .packed(result)
    }

    // Standard `a.b.c.d` form. Always emits without leading zeros and
    // without zone or port information (those don't apply to bare
    // IPv4 addresses).
    public var stringValue: String {
        let b3 = UInt8((rawValue >> 24) & 0xFF)
        let b2 = UInt8((rawValue >> 16) & 0xFF)
        let b1 = UInt8((rawValue >> 8) & 0xFF)
        let b0 = UInt8(rawValue & 0xFF)
        return "\(b3).\(b2).\(b1).\(b0)"
    }

    // Common literals exposed for diagnostics and tests. `127.0.0.1`
    // is the loopback; `255.255.255.255` is the broadcast.
    public static let zero = ClickHouseIPv4Address(0)
    public static let loopback = ClickHouseIPv4Address(0x7F00_0001)
    public static let broadcast = ClickHouseIPv4Address(0xFFFF_FFFF)

}
