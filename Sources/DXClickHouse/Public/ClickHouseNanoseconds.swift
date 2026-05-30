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

import Foundation

// 64-bit-integer-backed timestamp at exact nanosecond resolution since
// Unix epoch. Use this when nanosecond fidelity matters and `Date`'s
// `Double` precision (~microseconds at year-2024 timestamps) is not
// sufficient.
//
// This type is intentionally local to the ClickHouse module so the
// module can be extracted into a standalone Swift package without a
// hard dependency on app-level shared code.
public struct ClickHouseNanoseconds: Sendable, Equatable, Hashable {

    // Exact nanoseconds since 1970-01-01T00:00:00Z. Negative values
    // are valid (pre-epoch). Range covers ~292 years either side of
    // the epoch — sufficient for any column ClickHouse can store.
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    // Lossy: `Date` is `Double`-backed, so high-precision timestamps
    // beyond microsecond fidelity are rounded to the nearest
    // representable double before conversion. Use the `Int64`-based
    // initializer for exact construction.
    public init(date: Date) {
        let seconds = Int64(date.timeIntervalSince1970)
        let fractional = date.timeIntervalSince1970 - Double(seconds)
        let nanos = Int64((fractional * 1_000_000_000).rounded())
        self.rawValue = seconds * 1_000_000_000 + nanos
    }

    // Reverse of `init(date:)`. Same `Double` precision caveat applies
    // when converting back to `Date`. Use `rawValue` to keep nanosecond
    // fidelity.
    public var date: Date {
        let seconds = rawValue / 1_000_000_000
        let nanos = rawValue % 1_000_000_000
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    public static var now: ClickHouseNanoseconds {
        ClickHouseNanoseconds(date: Date())
    }

}
