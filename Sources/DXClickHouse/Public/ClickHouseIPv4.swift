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

// A value destined for a ClickHouse IPv4 column. The wire value is the
// 32-bit address with the first octet in the most significant byte, e.g.
// 127.0.0.1 is 0x7F00_0001.
public struct ClickHouseIPv4: Sendable, Hashable, Codable {

    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    // Parses dotted-quad text (e.g. "192.168.1.1") into the 32-bit address,
    // first octet in the high byte. Round-trips with `description`.
    public init(_ string: String) throws(ClickHouseError) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw Self.invalid(string) }
        self.raw = try Self.packOctets(parts, source: string)
    }

    private static func packOctets(_ parts: [Substring], source: String) throws(ClickHouseError) -> UInt32 {
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { throw invalid(source) }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    private static func invalid(_ string: String) -> ClickHouseError {
        .protocolError(stage: "ipv4", message: "'\(string)' is not a valid IPv4 dotted-quad address")
    }
}

extension ClickHouseIPv4: CustomStringConvertible {

    public var description: String {
        "\(raw >> 24 & 0xFF).\(raw >> 16 & 0xFF).\(raw >> 8 & 0xFF).\(raw & 0xFF)"
    }
}
