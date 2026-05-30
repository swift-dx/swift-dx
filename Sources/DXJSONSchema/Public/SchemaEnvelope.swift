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

public struct SchemaEnvelope: Sendable {

    public let type: String
    public let schema: [UInt8]

    public init(type: String, schema: [UInt8]) {
        self.type = type
        self.schema = schema
    }

    public init(type: String, schema: String) {
        self.type = type
        self.schema = Array(schema.utf8)
    }
}
