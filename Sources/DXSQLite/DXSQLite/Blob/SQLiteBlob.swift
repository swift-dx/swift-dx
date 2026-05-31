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

/// An open handle to a single BLOB cell for incremental, offset-based reads and
/// writes without materializing the whole value.
///
/// A blob is valid only inside the ``SQLiteWriter/withBlob(table:column:rowID:_:)``
/// (or reader) closure that vends it; it is deliberately not `Sendable` so it
/// cannot escape that scope, and it is closed when the closure returns. Writes
/// occupy the cell's existing length — pre-size it by inserting `zeroblob(n)`.
public final class SQLiteBlob {

    private let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public var count: Int {
        Int(sqlite3_blob_bytes(handle))
    }

    public func read(count: Int, at offset: Int) throws(SQLiteError) -> [UInt8] {
        let length = try nonNegativeInt32(count, operation: "read")
        let start = try nonNegativeInt32(offset, operation: "read")
        var buffer = [UInt8](repeating: 0, count: count)
        let code = buffer.withUnsafeMutableBytes { destination in
            sqlite3_blob_read(handle, destination.baseAddress, length, start)
        }
        guard code == SQLITE_OK else {
            throw SQLiteError.blobFailed(operation: "read", code: code, message: String(cString: sqlite3_errstr(code)))
        }
        return buffer
    }

    public func write(_ bytes: [UInt8], at offset: Int) throws(SQLiteError) {
        let length = try nonNegativeInt32(bytes.count, operation: "write")
        let start = try nonNegativeInt32(offset, operation: "write")
        let code = bytes.withUnsafeBytes { source in
            sqlite3_blob_write(handle, source.baseAddress, length, start)
        }
        guard code == SQLITE_OK else {
            throw SQLiteError.blobFailed(operation: "write", code: code, message: String(cString: sqlite3_errstr(code)))
        }
    }

    private func nonNegativeInt32(_ value: Int, operation: String) throws(SQLiteError) -> Int32 {
        guard let narrowed = Int32(exactly: value), narrowed >= 0 else {
            throw SQLiteError.blobFailed(operation: operation, code: SQLITE_ERROR, message: "byte count and offset must be non-negative and within 32-bit range")
        }
        return narrowed
    }

    func close() {
        sqlite3_blob_close(handle)
    }
}
