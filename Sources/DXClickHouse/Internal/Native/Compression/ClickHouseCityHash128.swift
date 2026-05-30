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

struct ClickHouseCityHash128: Sendable, Equatable {

    let low: UInt64
    let high: UInt64

    init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

}
