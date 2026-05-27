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

public enum FetchWait: Sendable, Hashable {

    /// Wake when the response buffer holds `batch` messages or the server
    /// closes the request with a 404/408 status. Throughput mode.
    case fill
    /// Wake as soon as at least one message has arrived, returning whatever
    /// is currently in the buffer up to `batch`. Latency mode for bursty
    /// publishers.
    case anyAvailable
    /// Wake when at least `count` messages have arrived. Clamped to `1...batch`.
    case atLeast(Int)
}
