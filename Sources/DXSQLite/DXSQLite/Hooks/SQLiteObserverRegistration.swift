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

// Unlike the hooks, the observer setters neither return the prior user-data nor
// take an xDestroy, so the connection OWNS each box: it keeps a strong reference
// and passes the box unretained to SQLite. Replacing drops the old reference
// after the new one is installed; the connection clears the C callbacks in
// deinit before the boxes are released. Each box holds only a @Sendable closure.
final class SQLiteTraceBox: Sendable {

    let handler: @Sendable (String) -> Void

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }
}

final class SQLiteBusyBox: Sendable {

    let handler: @Sendable (Int) -> Bool

    init(_ handler: @escaping @Sendable (Int) -> Bool) {
        self.handler = handler
    }
}

final class SQLiteProgressBox: Sendable {

    let handler: @Sendable () -> Bool

    init(_ handler: @escaping @Sendable () -> Bool) {
        self.handler = handler
    }
}

func dxTraceThunk(_ mask: UInt32, _ userData: UnsafeMutableRawPointer?, _ statement: UnsafeMutableRawPointer?, _ detail: UnsafeMutableRawPointer?) -> Int32 {
    guard let userData, let detail else { return 0 }
    Unmanaged<SQLiteTraceBox>.fromOpaque(userData).takeUnretainedValue().handler(String(cString: detail.assumingMemoryBound(to: CChar.self)))
    return 0
}

func dxBusyThunk(_ userData: UnsafeMutableRawPointer?, _ retryCount: Int32) -> Int32 {
    guard let userData else { return 0 }
    return Unmanaged<SQLiteBusyBox>.fromOpaque(userData).takeUnretainedValue().handler(Int(retryCount)) ? 1 : 0
}

func dxProgressThunk(_ userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let userData else { return 0 }
    return Unmanaged<SQLiteProgressBox>.fromOpaque(userData).takeUnretainedValue().handler() ? 0 : 1
}
