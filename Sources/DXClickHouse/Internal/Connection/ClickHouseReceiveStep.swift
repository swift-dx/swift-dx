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

// The outcome of reading the connection forward to the next result Data block.
// `readNextDataBlock` consumes (and delivers) exactly one Data block per call
// when one arrives, or reports that the result has ended at EndOfStream. Modeled
// as a named enum rather than an optional row count so the caller switches over
// an explicit, exhaustive set of outcomes.
package enum ClickHouseReceiveStep: Sendable {

    case block(rowCount: Int)
    case endOfStream
}
