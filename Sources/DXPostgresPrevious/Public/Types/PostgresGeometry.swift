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

/// A PostGIS `geometry` or `geography` value: a spatial reference identifier
/// paired with a shape. An ``srid`` of `0` is PostGIS's "unspecified reference
/// system" sentinel and is encoded without the EWKB SRID flag; any other value
/// is written as the geometry's SRID. Decoded from and encoded to Extended
/// Well-Known Binary, the format PostGIS uses on the wire (and as hex text).
///
/// PostGIS is a PostgreSQL extension; YugabyteDB does not provide it, so this
/// type is PostgreSQL-only. The built-in geometric types (``PostgresPoint`` and
/// the others) remain the cross-database geometry primitives.
public struct PostgresGeometry: Sendable, Equatable {

    public let srid: Int32
    public let shape: PostgresGeometryShape

    public init(srid: Int32, shape: PostgresGeometryShape) {
        self.srid = srid
        self.shape = shape
    }
}
