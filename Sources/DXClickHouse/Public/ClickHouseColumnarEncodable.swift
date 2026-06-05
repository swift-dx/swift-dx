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

// A type inserted through the columnar fast path instead of Codable. Codable
// allocates an encoding container per row, which dominates the cost of an
// INSERT of millions of rows. A ClickHouseColumnarEncodable instead encodes a
// whole batch column-by-column in one pass, appending each column's typed
// array to the sink with no per-row allocation.
//
// Conform by hand, or apply the `@ClickHouseRow` macro to generate
// `encodeColumnar` from the stored properties alongside the decode side.
public protocol ClickHouseColumnarEncodable {

    static func encodeColumnar(_ rows: [Self], into sink: inout ClickHouseColumnSink)
}
