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

public struct SchemaResource: Sendable {

    public let uri: String
    public let json: [UInt8]

    public init(uri: String, json: [UInt8]) {
        self.uri = uri
        self.json = json
    }

    public init(uri: String, json: String) {
        self.uri = uri
        self.json = Array(json.utf8)
    }
}
