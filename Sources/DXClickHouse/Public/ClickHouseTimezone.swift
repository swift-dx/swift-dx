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

// Timezone metadata attached to `DateTime` and `DateTime64` column
// specs. The timezone never travels on the wire — it is purely type-
// name metadata that affects how the server displays and parses
// timestamp literals.
//
// `.serverDefault` produces the bare type name (`DateTime`,
// `DateTime64(3)`) and instructs the server to interpret values in
// its session timezone. `.explicit` pins a specific IANA zone name
// (e.g. `"Pacific/Auckland"`) and produces the parenthesised form
// (`DateTime('Pacific/Auckland')`).
public enum ClickHouseTimezone: Sendable, Hashable {

    case serverDefault
    case explicit(String)

}
