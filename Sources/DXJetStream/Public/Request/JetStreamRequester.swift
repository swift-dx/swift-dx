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

public protocol JetStreamRequester: Sendable {
    func request(at subject: Subject, payload: [UInt8]) async throws(JetStreamError) -> NatsMessage
}
