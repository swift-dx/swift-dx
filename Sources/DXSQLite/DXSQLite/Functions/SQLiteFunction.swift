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

/// A custom scalar SQL function, declared in ``SQLiteConfiguration`` and
/// registered on every connection the database opens.
///
/// Because SQLite serializes writes to one connection and runs reads on a pool
/// of others, a function must exist on all of them to be callable from any
/// query. Declaring functions up front in the configuration registers them at
/// each connection's open, with no runtime registration races. The body is
/// `@Sendable` because the same closure is invoked from the writer thread and
/// every reader thread.
public struct SQLiteFunction: Sendable {

    public let name: String
    public let argumentCount: Int
    public let body: @Sendable ([SQLiteValue]) throws -> SQLiteValue

    public init(name: String, argumentCount: Int, body: @escaping @Sendable ([SQLiteValue]) throws -> SQLiteValue) {
        self.name = name
        self.argumentCount = argumentCount
        self.body = body
    }
}
