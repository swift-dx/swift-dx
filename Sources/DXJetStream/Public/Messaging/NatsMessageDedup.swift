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

/// How the JetStream broker should treat an outgoing message for the
/// purposes of duplicate detection.
///
/// JetStream streams configured with a deduplication window inspect the
/// `Nats-Msg-Id` header on each publish; messages that arrive with the
/// same ID inside the window are discarded as duplicates and acked
/// without being stored a second time. Messages without that header are
/// stored unconditionally.
public enum NatsMessageDedup: Sendable, Equatable {

    case noDedup
    case dedupId(String)
}
