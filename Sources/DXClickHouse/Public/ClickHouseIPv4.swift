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

// A value destined for a ClickHouse IPv4 column. The wire value is the
// 32-bit address with the first octet in the most significant byte, e.g.
// 127.0.0.1 is 0x7F00_0001.
public struct ClickHouseIPv4: Sendable, Hashable, Codable {

    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }
}
