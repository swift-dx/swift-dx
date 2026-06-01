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

// A value destined for a ClickHouse UInt128 column: an unsigned 128-bit
// integer stored little-endian (16 bytes).
public struct ClickHouseUInt128: Sendable, Hashable, Codable {

    public let value: UInt128

    public init(_ value: UInt128) {
        self.value = value
    }
}
