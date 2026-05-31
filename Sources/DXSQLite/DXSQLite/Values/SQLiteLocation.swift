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

/// Where a database lives.
///
/// A file-backed database is the production case and the only one that supports
/// the writer-plus-readers pool against durable storage. The in-memory case
/// carries a name so that the writer connection and every reader connection
/// open the same shared-cache database (`file:<name>?mode=memory&cache=shared`)
/// rather than each getting a private, empty one.
public enum SQLiteLocation: Sendable, Equatable {

    case file(path: String)
    case inMemory(name: String)
}

extension SQLiteLocation {

    var resolvedPath: String {
        switch self {
        case .file(let path): path
        case .inMemory(let name): "file:\(name)?mode=memory&cache=shared"
        }
    }
}
