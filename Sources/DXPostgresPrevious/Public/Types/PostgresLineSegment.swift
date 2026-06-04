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

/// A PostgreSQL `lseg`: a finite line segment between two endpoints.
public struct PostgresLineSegment: Sendable, Equatable {

    public let start: PostgresPoint
    public let end: PostgresPoint

    public init(start: PostgresPoint, end: PostgresPoint) {
        self.start = start
        self.end = end
    }
}

extension PostgresLineSegment: CustomStringConvertible {

    public var description: String {
        "[\(start),\(end)]"
    }
}
