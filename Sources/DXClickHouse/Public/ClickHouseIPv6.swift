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

// A value destined for a ClickHouse IPv6 column: the 16 address bytes in
// network order. Fewer than 16 bytes are right-padded with zeros at
// encode time; more than 16 is rejected.
public struct ClickHouseIPv6: Sendable, Hashable, Codable {

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // Parses RFC 4291 textual IPv6, including a single "::" run-of-zeros
    // compression, into the 16 network-order bytes. Round-trips with the
    // canonical `description`. The IPv4-embedded form (::ffff:1.2.3.4) is not
    // accepted; supply hextets.
    public init(_ string: String) throws(ClickHouseError) {
        let groups = try Self.expandedGroups(string)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for group in groups {
            bytes.append(UInt8(group >> 8))
            bytes.append(UInt8(truncatingIfNeeded: group))
        }
        self.bytes = bytes
    }

    private static func expandedGroups(_ string: String) throws(ClickHouseError) -> [UInt16] {
        let parts = string.components(separatedBy: "::")
        if parts.count == 1 {
            return try fixedEightGroups(parts[0], source: string)
        }
        return try compressedGroups(parts, source: string)
    }

    private static func fixedEightGroups(_ text: String, source: String) throws(ClickHouseError) -> [UInt16] {
        let groups = try hexGroups(text, source: source)
        guard groups.count == 8 else { throw invalid(source) }
        return groups
    }

    private static func compressedGroups(_ parts: [String], source: String) throws(ClickHouseError) -> [UInt16] {
        guard parts.count == 2 else { throw invalid(source) }
        let leading = try hexGroups(parts[0], source: source)
        let trailing = try hexGroups(parts[1], source: source)
        let fill = 8 - leading.count - trailing.count
        guard fill >= 1 else { throw invalid(source) }
        return leading + Array(repeating: 0, count: fill) + trailing
    }

    private static func hexGroups(_ text: String, source: String) throws(ClickHouseError) -> [UInt16] {
        if text.isEmpty { return [] }
        var groups: [UInt16] = []
        for piece in text.components(separatedBy: ":") {
            groups.append(try hexGroup(piece, source: source))
        }
        return groups
    }

    private static func hexGroup(_ piece: String, source: String) throws(ClickHouseError) -> UInt16 {
        guard piece.count <= 4, let group = UInt16(piece, radix: 16) else { throw invalid(source) }
        return group
    }

    private static func invalid(_ string: String) -> ClickHouseError {
        .protocolError(stage: "ipv6", message: "'\(string)' is not a valid IPv6 address")
    }
}
