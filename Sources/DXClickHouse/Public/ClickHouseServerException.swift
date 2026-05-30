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

// Decoded server-side ClickHouse exception. Carries the structured
// contents of a Server Exception packet (type=2) so callers can route
// on the numeric `code` rather than a textual blob. `nested` holds a
// recursively-decoded inner exception when the server attached one
// (the wire format chains exceptions via a `has_nested` flag).
public struct ClickHouseServerException: Sendable, Equatable, CustomStringConvertible {

    public let code: Int32
    public let name: String
    public let message: String
    public let stackTrace: String
    public let nested: [ClickHouseServerException]

    public init(
        code: Int32,
        name: String,
        message: String,
        stackTrace: String = "",
        nested: [ClickHouseServerException] = []
    ) {
        self.code = code
        self.name = name
        self.message = message
        self.stackTrace = stackTrace
        self.nested = nested
    }

    public var description: String {
        if nested.isEmpty {
            return "code=\(code) name=\(name) message=\(message)"
        }
        let nestedDescription = nested.map { $0.description }.joined(separator: " -> ")
        return "code=\(code) name=\(name) message=\(message) nested=[\(nestedDescription)]"
    }
}
