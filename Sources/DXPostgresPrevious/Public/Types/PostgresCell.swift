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

/// A single column value within a row as it arrived on the wire. SQL NULL is a
/// first-class state, ``sqlNull``, distinct from a present-but-empty value
/// (``bytes(_:)`` with an empty array). The bytes are interpreted against the
/// owning column's data type and format when decoded into a Swift value.
public enum PostgresCell: Sendable, Equatable {

    case sqlNull
    case bytes([UInt8])
}
