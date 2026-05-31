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

import Foundation

/// A custom collating sequence, declared in ``SQLiteConfiguration`` and
/// registered on every connection the database opens.
///
/// `compare` orders two text values (decoded as UTF-8) and is `@Sendable`
/// because SQLite invokes it from the writer thread and every reader thread.
public struct SQLiteCollation: Sendable {

    public let name: String
    public let compare: @Sendable (String, String) -> ComparisonResult

    public init(name: String, compare: @escaping @Sendable (String, String) -> ComparisonResult) {
        self.name = name
        self.compare = compare
    }
}
