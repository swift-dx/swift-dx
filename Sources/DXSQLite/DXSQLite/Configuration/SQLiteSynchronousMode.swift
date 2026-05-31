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

/// How durably a write must reach stable storage before a commit returns.
///
/// This maps directly to SQLite's `synchronous` pragma and is the central
/// durability-versus-throughput decision for a deployment. Under WAL:
/// `full` fsyncs the write-ahead log on every commit, so a committed
/// transaction survives a power loss; `normal` fsyncs only at checkpoints, so a
/// commit survives an application crash but a power loss can roll back the most
/// recent transactions; `off` hands durability entirely to the operating system
/// and can corrupt the database on power loss; `extra` adds an fsync of the
/// directory entry on top of `full` for the strictest guarantee.
public enum SQLiteSynchronousMode: Sendable, Equatable {

    case off
    case normal
    case full
    case extra
}

extension SQLiteSynchronousMode {

    var pragmaKeyword: String {
        switch self {
        case .off: "OFF"
        case .normal: "NORMAL"
        case .full: "FULL"
        case .extra: "EXTRA"
        }
    }
}
