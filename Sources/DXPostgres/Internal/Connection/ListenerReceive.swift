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

// Which side of a listener's wait woke it: the connection has bytes to read, or
// the interrupt descriptor was signaled so a queued control command (a new
// subscription, an unsubscription, or a stop) should be applied.
enum ListenerWakeup: Sendable {

    case readable
    case interrupt
}

// The result of decoding the next complete message already sitting in the read
// buffer without blocking for more bytes: either a notification is ready, or the
// buffer holds no further complete message and the caller must read from the
// socket before trying again.
enum BufferedNotification: Sendable {

    case notification(PostgresNotification)
    case needMore
}

// Why a listener's receive loop ended: a stop was requested (a clean shutdown that
// finishes the stream without error) or the connection failed (which finishes the
// stream with that error).
enum ListenerLoopOutcome: Sendable {

    case stopped
    case failed(PostgresError)
}

// The result of one receive-loop cycle: keep running, or terminate with an outcome.
enum ListenerStep: Sendable {

    case keepGoing
    case terminated(ListenerLoopOutcome)
}

// How a subscription obtains and re-obtains its connection: a fixed connection that
// cannot be rebuilt (used by hermetic tests), or a target the loop reconnects to
// forever after a drop.
enum ListenerSource: Sendable {

    case fixed
    case reconnectable(PostgresConnectionTarget)
}

// The decision after a subscription's connection fails: a fresh connection was
// established (and stored as the current connection) so the loop resumes, a stop
// was requested so it finishes cleanly, or the source cannot reconnect so the
// failure ends the stream.
enum ListenerRecovery: Sendable {

    case reconnected
    case stop
    case fail(PostgresError)
}
