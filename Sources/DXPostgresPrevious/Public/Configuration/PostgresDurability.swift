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

/// The durability a single transaction demands of its `COMMIT`, expressed as the
/// PostgreSQL `synchronous_commit` level applied with `SET LOCAL` so it scopes to
/// exactly that transaction and reverts automatically afterwards. Choosing it
/// per transaction means one connection pool serves every level; connections are
/// never pinned to a durability and never leak a session-wide setting to the next
/// caller.
///
/// This knob is specific to PostgreSQL. Engines without an equivalent (such as
/// YugabyteDB) do not expose it, so it lives only on the PostgreSQL surface and is
/// never implied by the cross-engine query API.
///
/// In every case the rule is the same: a `COMMIT` only reports success once the
/// server has accepted it to the chosen level. A relaxed level can lose the most
/// recent commits in a crash, but never reports a commit the server rejected.
public enum PostgresDurability: Sendable, Equatable {

    /// `synchronous_commit = on`: the `COMMIT` waits until the record is flushed to
    /// the local write-ahead log, and to a synchronous standby when one is
    /// configured, before returning. A reported commit survives a crash.
    case synchronous

    /// `synchronous_commit = off`: the `COMMIT` returns before the write-ahead-log
    /// flush completes. A crash can lose the most recent commits; nothing the
    /// server rejected is ever reported as committed. Fastest for high-volume,
    /// loss-tolerant writes.
    case asynchronous

    /// `synchronous_commit = local`: wait for the local write-ahead-log flush but
    /// not for any standby. Durable on this node, not yet confirmed replicated.
    case localFlush

    /// `synchronous_commit = remote_write`: wait until a synchronous standby has
    /// received the record into its operating-system buffers.
    case remoteWrite

    /// `synchronous_commit = remote_apply`: wait until a synchronous standby has
    /// applied the record, so a read on that standby observes it.
    case remoteApply

    var synchronousCommitValue: String {
        switch self {
        case .synchronous: "on"
        case .asynchronous: "off"
        case .localFlush: "local"
        case .remoteWrite: "remote_write"
        case .remoteApply: "remote_apply"
        }
    }
}
