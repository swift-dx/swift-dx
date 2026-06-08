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

/// The schema search order a connection adopts at startup, set once in the
/// startup packet so every statement on the connection resolves unqualified names
/// against it without a per-query `SET` or `SET LOCAL`.
///
/// `serverDefault` leaves the server's configured `search_path` untouched.
/// `schemas` sends the listed schemas in order; an unqualified name resolves to
/// the first schema that holds it. Each name is sent as a quoted identifier, so a
/// schema whose name needs quoting (mixed case, reserved word) is handled
/// correctly and a name can never be read as `search_path` syntax.
public enum PostgresSearchPath: Sendable, Equatable {

    case serverDefault
    case schemas([String])
}
