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

/// The result of looking up an optional field on a ``PostgresServerError``.
/// A field the server did not send is ``absent``; a field it did send is
/// ``present(_:)`` with its text. Modeling absence as a named case keeps the
/// surface free of optionals while still distinguishing "no such field" from
/// "field present but empty".
public enum PostgresFieldValue: Sendable, Equatable {

    case absent
    case present(String)
}
