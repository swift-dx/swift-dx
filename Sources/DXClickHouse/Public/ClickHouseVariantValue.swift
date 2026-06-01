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

// The value carried by one row of a ClickHouse Variant(...) column. The
// enum is CLOSED: it has an explicit `.null` case plus exactly one case
// per member type SwiftDX supports inside a Variant. A Variant row is
// always exactly one of these alternatives, which is why a closed enum
// (rather than an optional or a type-erased box) is the correct surface:
// each row's permutation is named and the compiler enforces exhaustive
// handling at every call site.
//
// Adding a member case later is a source-breaking change because it
// breaks downstream exhaustive switches. That is the documented and
// accepted SemVer cost of giving callers a closed, exhaustively-checked
// value surface.
public enum ClickHouseVariantValue: Sendable, Hashable, Codable {

    case null
    case string(String)
    case int64(Int64)
    case uint64(UInt64)
    case float64(Double)
}
