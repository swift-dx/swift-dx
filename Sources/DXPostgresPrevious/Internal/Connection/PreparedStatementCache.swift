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

// Per-connection record of which SQL strings have already been parsed into named
// server-side prepared statements. A repeat of the same SQL reuses the statement
// name and skips the Parse message, so the server reuses its plan and the query
// text is not re-sent. The cache is bounded: once the limit is reached, further
// distinct statements run unnamed (parsed every time) rather than growing the
// server's prepared-statement set without limit. Prepared statements are scoped
// to a connection, so each connection owns its own cache.
struct PreparedStatementCache {

    enum Plan: Equatable {

        case prepared(name: String)
        case parseAndPrepare(name: String)
        case ephemeral

        var statementName: String {
            switch self {
            case .prepared(let name), .parseAndPrepare(let name): name
            case .ephemeral: ""
            }
        }

        var needsParse: Bool {
            switch self {
            case .prepared: false
            default: true
            }
        }
    }

    private var names: [String: String] = [:]
    private var counter = 0
    private let limit: Int

    init(limit: Int = 512) {
        self.limit = limit
    }

    mutating func plan(for sql: String) -> Plan {
        if let name = names[sql] {
            return .prepared(name: name)
        }
        guard names.count < limit else { return .ephemeral }
        counter += 1
        let name = "dxpg_s\(counter)"
        names[sql] = name
        return .parseAndPrepare(name: name)
    }

    mutating func evict(_ sql: String) {
        names[sql] = nil
    }
}
