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

// A type decoded from a result block through the columnar fast path instead
// of Codable. Codable allocates a keyed-decoding-container box per row, which
// dominates the cost of reading millions of rows. A ClickHouseRowDecodable
// instead exposes its column names once and is constructed from a
// ClickHouseFastRow cursor that reads the already-parsed typed columns in
// place, with no per-row allocation.
//
// `clickHouseColumnNames` lists the destination columns in field order: the
// engine binds each name to a block column once, then hands the bound columns
// to `decodeBlock`, which pulls each typed array out once (field `i` is the
// bound column at index `i`) and builds the rows in a tight loop. Conform by
// hand, or apply the `@ClickHouseRow` macro to generate both requirements from
// the stored properties.
public protocol ClickHouseRowDecodable {

    static var clickHouseColumnNames: [String] { get }

    static func decodeBlock(_ block: ClickHouseColumnBlock) throws(ClickHouseError) -> [Self]
}
