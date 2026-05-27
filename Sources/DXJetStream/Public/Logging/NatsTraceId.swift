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

public struct NatsTraceId: Sendable, Hashable, CustomStringConvertible {

    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    public var description: String {
        String(value, radix: 36)
    }
}
