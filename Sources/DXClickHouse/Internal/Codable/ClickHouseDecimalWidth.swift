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

enum ClickHouseDecimalWidth {

    static func bytes(forPrecision precision: UInt8) -> Int {
        switch precision {
        case 0...9: 4
        case 10...18: 8
        case 19...38: 16
        default: 32
        }
    }
}
