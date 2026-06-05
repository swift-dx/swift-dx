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

/// An asynchronous notification delivered by `LISTEN`/`NOTIFY`. `channel` is the
/// channel the notification was sent on, `payload` is the text a `NOTIFY` (or a
/// `pg_notify` call in a trigger) carried, and `processID` is the backend process
/// that sent it. A table-change trigger typically encodes the changed row as JSON
/// in `payload`.
public struct PostgresNotification: Sendable, Equatable {

    public let processID: Int32
    public let channel: String
    public let payload: String

    public init(processID: Int32, channel: String, payload: String) {
        self.processID = processID
        self.channel = channel
        self.payload = payload
    }
}
