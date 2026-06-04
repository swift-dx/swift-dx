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

// The decoded EWKB type word: the low bits name the OGC geometry kind while the
// three high bits flag the presence of a Z dimension, an M measure, and an SRID
// prefix. The remaining high bits (such as PostGIS's internal bounding-box flag)
// are masked off and never appear in send-format output.
struct WKBTypeDescriptor {

    let wkbType: UInt32
    let hasZ: Bool
    let hasM: Bool
    let hasSRID: Bool

    init(_ typeWord: UInt32) {
        hasZ = typeWord & 0x8000_0000 != 0
        hasM = typeWord & 0x4000_0000 != 0
        hasSRID = typeWord & 0x2000_0000 != 0
        wkbType = typeWord & 0x0FFF_FFFF
    }

    var dimension: WKBDimension {
        switch (hasZ, hasM) {
        case (false, false): .xy
        case (true, false): .xyz
        case (false, true): .xym
        case (true, true): .xyzm
        }
    }
}
