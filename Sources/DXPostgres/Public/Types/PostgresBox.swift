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

/// A PostgreSQL `box`: an axis-aligned rectangle given by two opposite corners.
/// PostgreSQL normalizes the corners so `upperRight` holds the larger coordinates
/// and `lowerLeft` the smaller, and renders them in that order.
public struct PostgresBox: Sendable, Equatable {

    public let upperRight: PostgresPoint
    public let lowerLeft: PostgresPoint

    public init(upperRight: PostgresPoint, lowerLeft: PostgresPoint) {
        self.upperRight = upperRight
        self.lowerLeft = lowerLeft
    }
}

extension PostgresBox: CustomStringConvertible {

    public var description: String {
        "\(upperRight),\(lowerLeft)"
    }
}
