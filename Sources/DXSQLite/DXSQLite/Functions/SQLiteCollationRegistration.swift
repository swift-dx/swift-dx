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
import Foundation

// Holds the comparator; retained into SQLite's collation user-data for the
// function's lifetime and released by the xDestroy thunk. Sendable because the
// comparator closure is the only stored state.
final class SQLiteCollationBox: Sendable {

    let compare: @Sendable (String, String) -> ComparisonResult

    init(compare: @escaping @Sendable (String, String) -> ComparisonResult) {
        self.compare = compare
    }
}

// Capture-free @convention(c) comparator SQLite calls to order two keys. Both
// keys arrive as (length, bytes) UTF-8 buffers because the collation is
// registered with SQLITE_UTF8.
func dxCollationThunk(_ userData: UnsafeMutableRawPointer?, _ leftCount: Int32, _ leftBytes: UnsafeRawPointer?, _ rightCount: Int32, _ rightBytes: UnsafeRawPointer?) -> Int32 {
    guard let userData else { return 0 }
    let box = Unmanaged<SQLiteCollationBox>.fromOpaque(userData).takeUnretainedValue()
    let left = decodeCollationText(leftBytes, leftCount)
    let right = decodeCollationText(rightBytes, rightCount)
    switch box.compare(left, right) {
    case .orderedAscending: return -1
    case .orderedSame: return 0
    case .orderedDescending: return 1
    }
}

func dxCollationDestroyThunk(_ userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<SQLiteCollationBox>.fromOpaque(userData).release()
}

private func decodeCollationText(_ bytes: UnsafeRawPointer?, _ count: Int32) -> String {
    guard let bytes, count > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(count)), as: UTF8.self)
}
