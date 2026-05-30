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

// Two-state enum that models the wire-level Nullable(T) value: either
// the column has a present value at this row, or the row's null mask
// byte was set and the inner sentinel byte sequence is meaningless.
//
// Why an enum rather than `T?`: the project's No-Optionals rule forbids
// Optional in source code. The enum carries the same two states with
// named, exhaustive cases that downstream switches must handle, and the
// Codable conformance below lets a downstream caller still spell their
// struct field as `T?` if they prefer — the Swift Codable runtime maps
// that field through `encodeIfPresent` / `decodeIfPresent` and the
// encoder/decoder bridges to RawClickHouseNullable at the wire boundary.
public enum RawClickHouseNullable<Wrapped: Sendable>: Sendable {

    case present(Wrapped)
    case absent

    public var isAbsent: Bool {
        switch self {
        case .present: false
        case .absent: true
        }
    }
}

extension RawClickHouseNullable: Equatable where Wrapped: Equatable {}
