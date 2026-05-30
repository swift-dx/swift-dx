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

// One server-side setting override that applies for the duration of a
// single query. Settings are stringly-typed on the wire even when they
// map to numeric or enum types server-side; the server parses the value.
//
// `important` (bit 0 of the wire flags field) is the common case: the
// server rejects the query if it does not recognise the setting name.
// `custom` (bit 1) marks user-defined settings outside ClickHouse's
// built-in list. `obsolete` (bit 2) marks server-deprecated settings.
public struct ClickHouseQuerySetting: Sendable, Equatable {

    public let name: String
    public let value: String
    public let important: Bool
    public let custom: Bool
    public let obsolete: Bool

    public init(
        name: String,
        value: String,
        important: Bool = true,
        custom: Bool = false,
        obsolete: Bool = false
    ) {
        self.name = name
        self.value = value
        self.important = important
        self.custom = custom
        self.obsolete = obsolete
    }
}

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
            ClickHouseWire.writeUVarInt(encodeFlags(entry), into: &output)
            ClickHouseWire.writeString(entry.value, into: &output)
        }
        ClickHouseWire.writeString("", into: &output)
    }

    private func encodeFlags(_ entry: ClickHouseQuerySetting) -> UInt64 {
        var flags: UInt64 = 0
        if entry.important { flags |= Self.flagImportant }
        if entry.custom { flags |= Self.flagCustom }
        if entry.obsolete { flags |= Self.flagObsolete }
        return flags
    }
}
