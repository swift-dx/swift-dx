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

public struct ClickHouseEnumValue<T: FixedWidthInteger & Sendable & Hashable>: Sendable, Hashable {

    public let name: String
    public let value: T

    public init(name: String, value: T) {
        self.name = name
        self.value = value
    }

}
