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

/// A custom aggregate SQL function, declared in ``SQLiteConfiguration`` and
/// registered on every connection the database opens.
///
/// `makeAggregator` is `@Sendable` because it is invoked from the writer thread
/// and every reader thread; each call must return a fresh ``SQLiteAggregator``
/// holding only that one aggregation's state.
public struct SQLiteAggregate: Sendable {

    public let name: String
    public let argumentCount: Int
    public let makeAggregator: @Sendable () -> any SQLiteAggregator

    public init(name: String, argumentCount: Int, makeAggregator: @escaping @Sendable () -> any SQLiteAggregator) {
        self.name = name
        self.argumentCount = argumentCount
        self.makeAggregator = makeAggregator
    }
}
