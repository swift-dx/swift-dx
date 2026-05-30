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

// Wraps a field whose presence on the wire depends on the negotiated
// ClickHouse protocol revision. `.unsupported` means the field was
// not emitted because the negotiated revision is below the field's
// introduction threshold. `.value` carries the parsed payload.
//
// Callers MUST switch exhaustively over both cases at every read
// site: the field's absence has structural meaning (the peer cannot
// represent it), distinct from "the peer sent a default-shaped value".
enum RevisionGated<T: Sendable & Equatable>: Sendable, Equatable {

    case unsupported
    case value(T)

    func unwrapOrDefault(_ fallback: T) -> T {
        switch self {
        case .unsupported: fallback
        case .value(let payload): payload
        }
    }
}

extension RevisionGated where T == UInt64 {

    var asWriteCounter: ClickHouseWriteCounter {
        switch self {
        case .unsupported: .notReported
        case .value(let count): .rows(count)
        }
    }

}
