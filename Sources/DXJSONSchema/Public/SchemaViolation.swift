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

public struct SchemaViolation: Sendable, Equatable {

    public let instanceLocation: String
    public let keywordLocation: String
    public let keyword: String
    public let message: String

    public init(instanceLocation: String, keywordLocation: String, keyword: String, message: String) {
        self.instanceLocation = instanceLocation
        self.keywordLocation = keywordLocation
        self.keyword = keyword
        self.message = message
    }
}
