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

// The coordinate dimensionality of a WKB geometry, controlling how many float8
// values each position carries on the wire and which Z/M flags appear in the
// EWKB type word.
enum WKBDimension: Sendable, Equatable {

    case xy
    case xyz
    case xym
    case xyzm

    var hasZ: Bool {
        self == .xyz || self == .xyzm
    }

    var hasM: Bool {
        self == .xym || self == .xyzm
    }
}
