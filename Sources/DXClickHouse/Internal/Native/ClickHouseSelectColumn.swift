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

// One column in a SELECT result block: `name` is the column's
// projected name (post-AS), `typeName` is the ClickHouse wire type
// (e.g. `"Nullable(String)"`, `"Array(Int32)"`), and `values` is
// the typed-array union of all rows for that column. Consumers
// pattern-match `values` to extract the row array of the expected
// type, or use the higher-level Codable path via `selectStream`
// if their target is a Decodable struct.
public struct ClickHouseSelectColumn: Sendable {

    public let name: String
    public let typeName: String
    public let values: ClickHouseColumnEntry.Values

    public init(name: String, typeName: String, values: ClickHouseColumnEntry.Values) {
        self.name = name
        self.typeName = typeName
        self.values = values
    }

}
