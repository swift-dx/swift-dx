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

/// A Swift type that can be produced from a single non-NULL PostgreSQL column
/// value. The SQL NULL case is handled by the row's decode methods before this
/// is called, so conformers only handle present values and throw
/// ``PostgresError/typeDecodingFailed(type:reason:)`` when the bytes do not
/// represent a valid instance.
public protocol PostgresDecodable: Sendable {

    static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Self
}
