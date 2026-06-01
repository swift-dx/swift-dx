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

public enum ColumnType: Sendable, Equatable {

    case null
    case integer
    case real
    case text
    case blob
}

extension ColumnType: CustomStringConvertible {

    public var description: String {
        switch self {
        case .null: "null"
        case .integer: "integer"
        case .real: "real"
        case .text: "text"
        case .blob: "blob"
        }
    }
}
