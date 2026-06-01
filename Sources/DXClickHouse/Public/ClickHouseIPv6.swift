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

// A value destined for a ClickHouse IPv6 column: the 16 address bytes in
// network order. Fewer than 16 bytes are right-padded with zeros at
// encode time; more than 16 is rejected.
public struct ClickHouseIPv6: Sendable, Hashable, Codable {

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}
