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

import NIOCore

extension ClickHouseClient {

    // Policy for verifying an idle connection is still alive before
    // handing it back to a caller. `never` returns idle entries as-is
    // (suitable only when every request is short and connections cycle
    // frequently). `afterIdleFor` Ping's a connection that has not
    // been used for at least the supplied duration; a failed Ping
    // closes the connection and opens a fresh one. Critical for
    // long-lived services: TCP keepalive defaults to ~2 h, so without
    // preflight a connection idle for an hour through a network
    // partition can return to the caller dead.
    public enum PoolPreflightPing: Sendable, Equatable {

        case never
        case afterIdleFor(TimeAmount)

    }

}
