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

import DXCore
import Foundation

// Shared text-format encoders backing the PostgresEncodable conformances. A
// value becomes its UTF-8 text rendering wrapped in a PostgresCell; the server
// coerces that text to the destination column type during Bind.
enum PostgresTextEncoding {

    static func text(_ string: String) -> PostgresCell {
        .bytes(Array(string.utf8))
    }

    static func bytea(_ bytes: [UInt8]) -> PostgresCell {
        .bytes(Array("\\x\(Hex.encodeLower(bytes))".utf8))
    }

    static func timestamp(_ date: Date) -> PostgresCell {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return text(formatter.string(from: date))
    }
}
