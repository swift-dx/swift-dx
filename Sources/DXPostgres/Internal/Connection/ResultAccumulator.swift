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

// Folds the backend messages of one request into a PostgresQueryResult.
// `absorb` returns true when ReadyForQuery ends the request. An ErrorResponse is
// captured rather than thrown immediately: the protocol still sends ReadyForQuery
// afterward, so the request keeps reading until the end and then `result()`
// surfaces the captured server error. Asynchronous messages (NoticeResponse,
// ParameterStatus, NotificationResponse) and the extended-protocol
// acknowledgements are absorbed without affecting the result.
struct ResultAccumulator {

    private enum ErrorSlot {

        case empty
        case captured(PostgresServerError)
    }

    private var columns: [PostgresColumn] = []
    private var rows: [PostgresRow] = []
    private var commandTag = ""
    private var errorSlot: ErrorSlot = .empty

    mutating func absorb(_ message: BackendMessage) throws(PostgresError) -> Bool {
        switch message {
        case .rowDescription(let fields): setColumns(fields); return false
        case .dataRow(let cells): appendRow(cells); return false
        case .commandComplete(let tag): commandTag = tag; return false
        case .readyForQuery: return true
        case .error(let error): capture(error); return false
        case .emptyQueryResponse, .noData, .notice, .parameterStatus, .parseComplete, .bindComplete, .closeComplete, .parameterDescription, .copyInResponse, .portalSuspended, .backendKeyData, .notification: return false
        case .authentication: throw PostgresError.protocolError(reason: "unexpected authentication message after startup completed")
        }
    }

    func result() throws(PostgresError) -> PostgresQueryResult {
        if case .captured(let error) = errorSlot {
            throw PostgresError.server(error)
        }
        return PostgresQueryResult(columns: columns, rows: rows, commandTag: PostgresCommandTag(raw: commandTag))
    }

    private mutating func setColumns(_ fields: [FieldDescription]) {
        columns = fields.map { PostgresColumn(field: $0) }
    }

    private mutating func appendRow(_ cells: [PostgresCell]) {
        rows.append(PostgresRow(columns: columns, cells: cells))
    }

    private mutating func capture(_ error: PostgresServerError) {
        guard case .empty = errorSlot else { return }
        errorSlot = .captured(error)
    }
}
