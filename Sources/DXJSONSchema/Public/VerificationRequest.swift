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

public struct VerificationRequest<ID: Sendable>: Sendable {

    public let id: ID
    public let type: String
    public let payload: [UInt8]

    public init(id: ID, type: String, payload: [UInt8]) {
        self.id = id
        self.type = type
        self.payload = payload
    }

    public init(id: ID, type: String, payload: String) {
        self.id = id
        self.type = type
        self.payload = Array(payload.utf8)
    }
}
