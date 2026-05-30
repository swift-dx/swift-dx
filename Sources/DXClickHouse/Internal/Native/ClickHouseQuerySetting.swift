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

// One server-side setting override applied for the duration of a single
// query. Settings are stringly-typed on the wire even when they map to
// numeric or enum types server-side; the server parses the value string.
//
// `important` (bit 0 of the flags field) is the common case: when set,
// the server rejects the query if it doesn't recognize the setting.
// `custom` (bit 1) marks user-defined settings outside the canonical
// list. `obsolete` (bit 2) is a hint that the setting has been
// deprecated.
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
