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

/// A PostgreSQL `interval`: a span of time stored as independent month, day, and
/// microsecond components, matching how PostgreSQL represents it (months and days
/// are calendar-relative and not collapsed into a fixed number of microseconds).
public struct PostgresInterval: Sendable, Equatable {

    public let months: Int32
    public let days: Int32
    public let microseconds: Int64

    public init(months: Int32 = 0, days: Int32 = 0, microseconds: Int64 = 0) {
        self.months = months
        self.days = days
        self.microseconds = microseconds
    }
}

extension PostgresInterval: CustomStringConvertible {

    public var description: String {
        "\(months) months \(days) days \(microseconds) microseconds"
    }
}
