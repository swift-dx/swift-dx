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

public struct NatsMessage: Sendable {

    public let subject: String
    public let sid: UInt64
    public let reply: ReplyAddress
    public let headers: [NatsHeader]
    public let payload: [UInt8]
    public let status: NatsMessageStatus

    public init(subject: String, sid: UInt64, reply: ReplyAddress, headers: [NatsHeader] = [], payload: [UInt8], status: NatsMessageStatus) {
        self.subject = subject
        self.sid = sid
        self.reply = reply
        self.headers = headers
        self.payload = payload
        self.status = status
    }
}
