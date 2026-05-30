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

public struct RedisEndpoint: Sendable, Hashable {

    public let host: String
    public let port: Int

    public init(host: String, port: Int = 6379) {
        self.host = host
        self.port = port
    }
}
