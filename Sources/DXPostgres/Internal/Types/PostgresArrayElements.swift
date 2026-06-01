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

// The flattened elements of a PostgreSQL array column: the element type OID, the
// wire format the element bytes are in, and one cell per element (SQL NULL or
// raw bytes). The row decoder turns each cell into the requested Swift element
// type with that type's PostgresDecodable conformance.
struct PostgresArrayElements {

    let elementObjectID: UInt32
    let format: PostgresFormat
    let cells: [PostgresCell]
}
