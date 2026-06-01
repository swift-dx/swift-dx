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

// A value destined for a ClickHouse Time64(precision) column. The wire
// value is the signed tick count, i.e. the number of 10^-precision-second
// units, stored as an 8-byte little-endian Int64. The precision parameter
// mirrors the column declaration `Time64(P)`.
public struct ClickHouseTime64: Sendable, Hashable, Codable {

    public let ticks: Int64
    public let precision: UInt8

    public init(ticks: Int64, precision: UInt8) {
        self.ticks = ticks
        self.precision = precision
    }
}
