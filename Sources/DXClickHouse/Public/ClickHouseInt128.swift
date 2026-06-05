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

// A value destined for a ClickHouse Int128 column: a signed 128-bit
// integer stored little-endian (16 bytes).
public struct ClickHouseInt128: Sendable, Hashable, Codable {

    public let value: Int128

    public init(_ value: Int128) {
        self.value = value
    }
}

extension ClickHouseInt128: CustomStringConvertible {

    public var description: String {
        value.description
    }
}
