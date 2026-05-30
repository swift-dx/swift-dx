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

public struct RedisCommand: Sendable, Hashable {

    public let arguments: [[UInt8]]

    public init(arguments: [[UInt8]]) {
        self.arguments = arguments
    }

    public init(_ tokens: String...) {
        self.arguments = tokens.map { Array($0.utf8) }
    }

    public init(words: [String]) {
        self.arguments = words.map { Array($0.utf8) }
    }
}

extension RedisCommand: ExpressibleByArrayLiteral {

    public init(arrayLiteral elements: String...) {
        self.arguments = elements.map { Array($0.utf8) }
    }
}
