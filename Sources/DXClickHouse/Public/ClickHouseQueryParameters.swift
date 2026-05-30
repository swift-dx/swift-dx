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
            try emit(entry, into: &output)
        }
        ClickHouseWire.writeString("", into: &output)
    }

    private func emit(_ entry: ClickHouseQueryParameter, into output: inout [UInt8]) throws(ClickHouseError) {
        if entry.name.isEmpty {
            throw .protocolError(stage: "parameters", message: "empty parameter name")
        }
        ClickHouseWire.writeString(entry.name, into: &output)
        ClickHouseWire.writeUVarInt(ClickHouseQuerySettings.flagCustom, into: &output)
        ClickHouseWire.writeString(entry.value, into: &output)
    }
}
