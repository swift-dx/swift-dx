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

/// A PostgreSQL `path`: an ordered list of points that is either closed (renders
/// with parentheses) or open (renders with square brackets).
public struct PostgresPath: Sendable, Equatable {

    public let isClosed: Bool
    public let points: [PostgresPoint]

    public init(isClosed: Bool, points: [PostgresPoint]) {
        self.isClosed = isClosed
        self.points = points
    }
}

extension PostgresPath: CustomStringConvertible {

    public var description: String {
        let joined = points.map(\.description).joined(separator: ",")
        return isClosed ? "(\(joined))" : "[\(joined)]"
    }
}
