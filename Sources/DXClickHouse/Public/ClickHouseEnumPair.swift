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

// One name-to-value entry of a ClickHouse Enum8 / Enum16 mapping. The
// value is held as Int16 so a single pair type serves both widths; for an
// Enum8 column every value must fit Int8, which the encoder verifies. The
// name must be non-empty and free of quotes, commas, and backslashes.
public struct ClickHouseEnumPair: Sendable, Hashable, Codable {

    public let name: String
    public let value: Int16

    public init(name: String, value: Int16) {
        self.name = name
        self.value = value
    }
}
