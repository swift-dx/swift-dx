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

// A bound client that can hand a subscription the connection target it needs to
// open its own dedicated, self-healing connection, so ambient `subscribe` and
// `watchTable` work from the bound client without the caller repeating the
// configuration. A pooled client opened from a configuration provides a
// reconnectable source; a client with no rebuildable target provides `.fixed`.
protocol PostgresSubscriptionProvider {

    var listenerSource: ListenerSource { get }

    func acquireSubscriptionPermit() throws(PostgresError) -> SubscriptionPermit
}
