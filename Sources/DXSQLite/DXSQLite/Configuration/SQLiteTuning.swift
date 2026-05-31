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

/// Per-connection storage-engine tuning, applied to every connection a
/// ``SQLiteDatabase`` opens (the writer and each pooled reader).
///
/// The defaults reproduce SQLite's own behavior, so an unconfigured database is
/// unchanged. Override these for large databases or stricter durability:
///
/// - `synchronous` is the durability level (see ``SQLiteSynchronousMode``).
/// - `cacheSizeKibibytes` is the page cache held in memory per connection,
///   expressed in kibibytes. Larger values keep more of the working set (and an
///   index's upper levels) resident, which matters once a database outgrows the
///   default. Applied as a negative `cache_size` so the unit is memory, not a
///   page count.
/// - `mmapSizeBytes` is the upper bound on memory-mapped I/O; `0` disables it.
/// - `pageSize` is the database page size in bytes. It only takes effect on a
///   newly created database (before any table exists); on an existing database
///   it is ignored unless the database is rebuilt.
public struct SQLiteTuning: Sendable, Equatable {

    public let synchronous: SQLiteSynchronousMode
    public let cacheSizeKibibytes: Int
    public let mmapSizeBytes: Int
    public let pageSize: Int

    public init(synchronous: SQLiteSynchronousMode = .normal, cacheSizeKibibytes: Int = 2000, mmapSizeBytes: Int = 0, pageSize: Int = 4096) {
        self.synchronous = synchronous
        self.cacheSizeKibibytes = cacheSizeKibibytes
        self.mmapSizeBytes = mmapSizeBytes
        self.pageSize = pageSize
    }
}
