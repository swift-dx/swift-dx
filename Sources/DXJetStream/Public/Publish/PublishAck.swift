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

public struct PublishAck: Sendable, Hashable {

    public let stream: String
    public let sequence: UInt64
    public let duplicate: Bool

    public init(stream: String, sequence: UInt64, duplicate: Bool) {
        self.stream = stream
        self.sequence = sequence
        self.duplicate = duplicate
    }

    public static func parse(_ payload: [UInt8]) throws(JetStreamError) -> PublishAck {
        try PublishAckParser.parse(payload)
    }
}
