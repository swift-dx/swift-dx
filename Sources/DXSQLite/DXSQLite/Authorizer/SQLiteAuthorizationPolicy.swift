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

/// Whether a database installs a compile-time authorizer on its connections.
///
/// `unrestricted` is the default and installs nothing, so statements compile
/// with no per-action checks and zero overhead. `custom` installs the supplied
/// decision function on every connection the database opens — the writer and
/// each pooled reader — so a policy (reject writes, hide a column, block
/// `ATTACH` or `PRAGMA`) is enforced uniformly wherever a statement runs. The
/// function is `@Sendable` because the same closure is invoked from the writer
/// thread and every reader thread, and it must not block.
public enum SQLiteAuthorizationPolicy: Sendable {

    case unrestricted
    case custom(@Sendable (SQLiteAuthorizerAction) -> SQLiteAuthorizerDecision)
}
