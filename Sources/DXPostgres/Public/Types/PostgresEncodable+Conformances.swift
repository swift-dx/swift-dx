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

extension String: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(self)
    }
}

extension Int: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(String(self))
    }
}

extension Int16: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(String(self))
    }
}

extension Int32: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(String(self))
    }
}

extension Int64: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(String(self))
    }
}

extension Double: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(String(self))
    }
}

extension Float: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(String(self))
    }
}

extension Bool: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(self ? "true" : "false")
    }
}

extension UUID: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(uuidString)
    }
}

extension Array: PostgresEncodable where Element == UInt8 {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.bytea(self)
    }
}

extension Decimal: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text("\(self)")
    }
}

extension Date: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.timestamp(self)
    }
}
