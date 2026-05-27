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

public struct NatsCredentials: Sendable, Hashable {

    public let jwt: String
    public let seed: String

    public init(jwt: String, seed: String) {
        self.jwt = jwt
        self.seed = seed
    }
}
