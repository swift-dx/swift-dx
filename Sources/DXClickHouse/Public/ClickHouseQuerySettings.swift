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

// Ordered collection of server-side setting overrides applied to one
// query. The wire encoding is a sequence of (name, flags, value)
// triples terminated by an empty-name string. The collection is a value
// type so callers can build setting bundles up-front and reuse them
// across queries without worrying about aliasing.
public struct ClickHouseQuerySettings: Sendable, Equatable {

    public static let empty = ClickHouseQuerySettings([])

    public let entries: [ClickHouseQuerySetting]

    public init(_ entries: [ClickHouseQuerySetting] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    static let flagImportant: UInt64 = 0x01
    static let flagCustom: UInt64 = 0x02
    static let flagObsolete: UInt64 = 0x04

    // Encode the full settings block (entries + empty-name terminator)
    // into a [UInt8] using ClickHouse Native wire framing.
    func encode(into output: inout [UInt8]) throws(ClickHouseError) {
        for entry in entries {
            if entry.name.isEmpty {
                throw .protocolError(stage: "settings", message: "empty setting name")
            }
            ClickHouseWire.writeString(entry.name, into: &output)
            ClickHouseWire.writeUVarInt(encodeFlagsFor(entry), into: &output)
            ClickHouseWire.writeString(entry.value, into: &output)
        }
        ClickHouseWire.writeString("", into: &output)
    }

    private func encodeFlagsFor(_ entry: ClickHouseQuerySetting) -> UInt64 {
        let pairs: [(Bool, UInt64)] = [
            (entry.important, Self.flagImportant),
            (entry.custom, Self.flagCustom),
            (entry.obsolete, Self.flagObsolete),
        ]
        return pairs.reduce(into: 0) { accumulator, pair in
            if pair.0 { accumulator |= pair.1 }
        }
    }
}
