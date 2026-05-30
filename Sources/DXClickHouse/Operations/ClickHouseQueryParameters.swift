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

// Server-side substitution parameter for a single query. Referenced in
// the SQL via the `{name:Type}` syntax that ClickHouse parses (e.g.
// `SELECT * FROM t WHERE id = {id:UInt64}`). The server validates the
// value against the declared type, providing SQL-injection-safe
// parameter substitution.
//
// The wire format reuses the Setting (name, flags, value) triple, but
// the flags field is always Custom (bit 1) for parameters.
public struct ClickHouseQueryParameter: Sendable, Equatable {

    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

// Ordered collection of server-side parameter substitutions. Wire
// encoding is a sequence of (name, customFlag, value) triples followed
// by an empty-name terminator string. Available on server revision
// 54_459 and later; callers can build the collection unconditionally
// and the encode path skips emission on older negotiated revisions.
public struct ClickHouseQueryParameters: Sendable, Equatable {

    public static let empty = ClickHouseQueryParameters([])

    static let revisionWithQueryParameters: UInt64 = 54_459

    public let entries: [ClickHouseQueryParameter]

    public init(_ entries: [ClickHouseQueryParameter] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var count: Int { entries.count }

    func encode(into output: inout [UInt8], revision: UInt64) throws(ClickHouseError) {
        guard revision >= Self.revisionWithQueryParameters else { return }
        for entry in entries {
            if entry.name.isEmpty {
                throw .protocolError(stage: "parameters", message: "empty parameter name")
            }
            ClickHouseWire.writeString(entry.name, into: &output)
            ClickHouseWire.writeUVarInt(ClickHouseQuerySettings.flagCustom, into: &output)
            ClickHouseWire.writeString(entry.value, into: &output)
        }
        ClickHouseWire.writeString("", into: &output)
    }
}
