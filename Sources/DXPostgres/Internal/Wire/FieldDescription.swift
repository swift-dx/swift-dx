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

// One column's metadata from a `RowDescription` message: the column name, the
// table and attribute it came from (zero when the column is computed), the data
// type OID and its size/modifier, and the wire format the values will use. This
// is the internal wire shape; the public projection is ``PostgresColumn``.
struct FieldDescription: Sendable, Equatable {

    let name: String
    let tableObjectID: Int32
    let columnAttributeNumber: Int16
    let dataTypeObjectID: UInt32
    let dataTypeSize: Int16
    let typeModifier: Int32
    let format: PostgresFormat
}
