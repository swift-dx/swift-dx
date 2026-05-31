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

// One server-side setting override that applies for the duration of a
// single query. Settings are stringly-typed on the wire even when they
// map to numeric or enum types server-side; the server parses the value.
//
// `important` (bit 0 of the wire flags field) is the common case: the
// server rejects the query if it does not recognise the setting name.
// `custom` (bit 1) marks user-defined settings outside ClickHouse's
// built-in list. `obsolete` (bit 2) marks server-deprecated settings.
public struct ClickHouseQuerySetting: Sendable, Equatable {

    public let name: String
    public let value: String
    public let important: Bool
    public let custom: Bool
    public let obsolete: Bool

    public init(
        name: String,
        value: String,
        important: Bool = true,
        custom: Bool = false,
        obsolete: Bool = false
    ) {
        self.name = name
        self.value = value
        self.important = important
        self.custom = custom
        self.obsolete = obsolete
    }
}

extension ClickHouseQuerySetting {

    // Idempotency key for an INSERT. ClickHouse drops a block whose token
    // matches one already inserted into the same table, so retrying an
    // INSERT after an ambiguous failure cannot double-write. Sent with the
    // `important` flag so the server rejects the query rather than silently
    // ignoring the token on an engine that does not support deduplication.
    public static func insertDeduplicationToken(_ token: String) -> ClickHouseQuerySetting {
        ClickHouseQuerySetting(name: "insert_deduplication_token", value: token)
    }
}
