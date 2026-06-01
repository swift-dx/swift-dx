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

/// A PostgreSQL `circle`: a center point and a radius.
public struct PostgresCircle: Sendable, Equatable {

    public let center: PostgresPoint
    public let radius: Double

    public init(center: PostgresPoint, radius: Double) {
        self.center = center
        self.radius = radius
    }
}

extension PostgresCircle: CustomStringConvertible {

    public var description: String {
        "<\(center),\(radius)>"
    }
}
