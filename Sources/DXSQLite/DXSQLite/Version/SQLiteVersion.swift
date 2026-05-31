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

import CSQLite

public struct SQLiteVersion: Sendable, Equatable {

    public let number: Int32
    public let text: String
    public let sourceID: String

    public init(number: Int32, text: String, sourceID: String) {
        self.number = number
        self.text = text
        self.sourceID = sourceID
    }
}

extension SQLiteVersion {

    public static func current() -> SQLiteVersion {
        let text = String(cString: sqlite3_libversion())
        let sourceID = String(cString: sqlite3_sourceid())
        return .init(number: sqlite3_libversion_number(), text: text, sourceID: sourceID)
    }
}
