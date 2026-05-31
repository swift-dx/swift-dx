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

/// Per-aggregation state for a custom aggregate SQL function.
///
/// One instance is created for each aggregation the query performs (via the
/// ``SQLiteAggregate/makeAggregator`` factory), `step` is called once per input
/// row, and `finalize` produces the result. An aggregator lives entirely on the
/// connection thread running the query, so it does not need to be `Sendable`.
public protocol SQLiteAggregator: AnyObject {

    func step(_ arguments: [SQLiteValue]) throws

    func finalize() throws -> SQLiteValue
}
