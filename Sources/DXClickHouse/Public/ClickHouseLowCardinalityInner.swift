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

// The element type wrapped by a ClickHouse LowCardinality(...) column.
// Only String and FixedString(N) inner types are supported.
public enum ClickHouseLowCardinalityInner: Sendable, Hashable, Codable {

    case string
    case fixedString(length: Int)
}

extension ClickHouseLowCardinalityInner {

    var typeName: String {
        switch self {
        case .string: "String"
        case .fixedString(let length): "FixedString(\(length))"
        }
    }
}
