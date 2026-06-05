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

extension PostgresError {

    // Runs an async body whose internal helpers throw untyped errors and narrows
    // the result to the library's typed surface: a PostgresError passes through
    // unchanged, a cancellation maps to .cancelled, and anything else is reported
    // as a transport failure. Public methods wrap their bodies in this so their
    // signatures can stay `throws(PostgresError)` while delegating to NIO and
    // other untyped-throwing code.
    static func bridge<Value>(_ body: () async throws -> Value) async throws(PostgresError) -> Value {
        do {
            return try await body()
        } catch {
            throw translate(error)
        }
    }

    // Narrows an arbitrary error to the typed surface without an async boundary,
    // used by the retry loop when classifying a caught failure. A cooperative
    // cancellation becomes `.cancelled` so it is neither retried nor mistaken for
    // a transport failure; anything else unknown is reported as a transport error.
    static func translate(_ error: Error) -> PostgresError {
        if let postgres = error as? PostgresError { return postgres }
        if error is CancellationError { return .cancelled }
        return .transportError(reason: String(describing: error))
    }
}
