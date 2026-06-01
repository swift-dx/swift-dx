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

/// The name of the database to connect to. PostgreSQL would otherwise default an
/// omitted database to the role name; DXPostgres requires it explicitly so the
/// target database is always visible at the call site rather than implied.
public struct PostgresDatabaseName: Sendable, Hashable {

    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

extension PostgresDatabaseName: CustomStringConvertible {

    public var description: String {
        value
    }
}
