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

/// A PostgreSQL `line`: an infinite line represented by the coefficients of
/// `Ax + By + C = 0`.
public struct PostgresLine: Sendable, Equatable {

    public let a: Double
    public let b: Double
    public let c: Double

    public init(a: Double, b: Double, c: Double) {
        self.a = a
        self.b = b
        self.c = c
    }
}

extension PostgresLine: CustomStringConvertible {

    public var description: String {
        "{\(a),\(b),\(c)}"
    }
}
