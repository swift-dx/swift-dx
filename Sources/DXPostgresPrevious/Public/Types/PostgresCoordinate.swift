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

/// A single position within a PostGIS geometry. PostGIS coordinates are always
/// two-dimensional and may additionally carry an elevation (`Z`) and/or a linear
/// measure (`M`); each case names exactly the components it holds, so an absent
/// dimension is unrepresentable rather than a defaulted or optional field.
public enum PostgresCoordinate: Sendable, Equatable {

    case xy(x: Double, y: Double)
    case xyz(x: Double, y: Double, z: Double)
    case xym(x: Double, y: Double, m: Double)
    case xyzm(x: Double, y: Double, z: Double, m: Double)

    public var x: Double {
        switch self {
        case .xy(let x, _), .xyz(let x, _, _), .xym(let x, _, _), .xyzm(let x, _, _, _): x
        }
    }

    public var y: Double {
        switch self {
        case .xy(_, let y), .xyz(_, let y, _), .xym(_, let y, _), .xyzm(_, let y, _, _): y
        }
    }

    var components: [Double] {
        switch self {
        case .xy(let x, let y): [x, y]
        case .xyz(let x, let y, let z): [x, y, z]
        case .xym(let x, let y, let m): [x, y, m]
        case .xyzm(let x, let y, let z, let m): [x, y, z, m]
        }
    }

    var dimension: WKBDimension {
        switch self {
        case .xy: .xy
        case .xyz: .xyz
        case .xym: .xym
        case .xyzm: .xyzm
        }
    }
}
