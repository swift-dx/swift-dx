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

// A value destined for a ClickHouse Enum8(...) column. The `mapping` is
// the complete ordered name-to-value table that defines the column type
// and must be identical on every row of the column; `value` is the row's
// selected ordinal and must appear in the mapping. The encoder verifies
// both and that every mapping value fits Int8.
public struct ClickHouseEnum8: Sendable, Hashable, Codable {

    public let value: Int8
    public let mapping: [ClickHouseEnumPair]

    public init(value: Int8, mapping: [ClickHouseEnumPair]) {
        self.value = value
        self.mapping = mapping
    }
}
