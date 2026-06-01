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

/// A PostgreSQL `polygon`: a closed shape defined by its ordered vertices.
public struct PostgresPolygon: Sendable, Equatable {

    public let points: [PostgresPoint]

    public init(points: [PostgresPoint]) {
        self.points = points
    }
}

extension PostgresPolygon: CustomStringConvertible {

    public var description: String {
        "(\(points.map(\.description).joined(separator: ",")))"
    }
}
