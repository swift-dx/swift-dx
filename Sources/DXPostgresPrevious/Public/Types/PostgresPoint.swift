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

/// A PostgreSQL `point`: a coordinate pair on the plane. It is the building block
/// of the other geometric types (`lseg`, `box`, `path`, `polygon`, `circle`).
public struct PostgresPoint: Sendable, Equatable {

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

extension PostgresPoint: CustomStringConvertible {

    public var description: String {
        "(\(x),\(y))"
    }
}
