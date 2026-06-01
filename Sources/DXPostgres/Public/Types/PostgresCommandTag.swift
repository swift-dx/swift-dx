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

/// The command tag PostgreSQL returns when a statement completes, for example
/// `INSERT 0 3`, `UPDATE 5`, `DELETE 2`, or `SELECT 10`. The raw tag is exposed
/// verbatim; ``affectedRows`` extracts the trailing row count that `INSERT`,
/// `UPDATE`, `DELETE`, and `SELECT` report, returning zero for tags that carry
/// no count.
public struct PostgresCommandTag: Sendable, Equatable {

    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    public var affectedRows: Int {
        guard let trailing = raw.split(separator: " ").last, let count = Int(trailing) else {
            return 0
        }
        return count
    }
}

extension PostgresCommandTag: CustomStringConvertible {

    public var description: String {
        raw
    }
}
