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

public enum ClickHouseIdentifier {

    // Wraps an identifier in backticks per ClickHouse's quoted-name
    // syntax. Embedded backticks are doubled per the SQL-standard
    // identifier-escape rule, preserving the caller's intent
    // losslessly. The server rejects an identifier whose un-doubled
    // form is malformed, which is the right behaviour for both
    // legitimate-but-weird names and attempted injection (the
    // server's identifier parser sees the doubled form as a single
    // literal backtick inside the quoted name).
    public static func escape(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

}
