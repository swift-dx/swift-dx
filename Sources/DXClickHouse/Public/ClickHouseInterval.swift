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

// A value destined for a ClickHouse Interval column. The wire value is a
// signed 64-bit magnitude; `kind` selects the time unit and reproduces
// the server type name (for example `ClickHouseInterval(value: 5, kind:
// .day)` maps to the `IntervalDay` column type carrying 5).
public struct ClickHouseInterval: Sendable, Hashable, Codable {

    public let value: Int64
    public let kind: ClickHouseIntervalKind

    public init(value: Int64, kind: ClickHouseIntervalKind) {
        self.value = value
        self.kind = kind
    }

    public var typeName: String {
        kind.typeName
    }
}
