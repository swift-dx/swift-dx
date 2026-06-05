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
        guard revision >= Self.revisionWithQueryParameters else {
            try requireEmptyForUnsupportedRevision(revision: revision)
            return
        }
        for entry in entries {
            try emit(entry, into: &output)
        }
        ClickHouseWire.writeString("", into: &output)
    }

    // The query-parameters field does not exist on the wire before
    // revision 54_459, so it is correct to emit nothing there. But
    // silently emitting nothing while the caller bound parameters would
    // leave the `{name:Type}` placeholders unresolved in the SQL and
    // surface as an opaque server-side error. Fail loudly at the boundary
    // instead so the caller learns the server is too old for binding.
    private func requireEmptyForUnsupportedRevision(revision: UInt64) throws(ClickHouseError) {
        guard entries.isEmpty else {
            throw .protocolError(
                stage: "parameters",
                message: "server protocol revision \(revision) does not support query parameters (requires \(Self.revisionWithQueryParameters)); \(entries.count) bound parameter(s) would be silently dropped, leaving unresolved {name:Type} placeholders in the query"
            )
        }
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
