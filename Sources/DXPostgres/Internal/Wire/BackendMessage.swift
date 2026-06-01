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

// A decoded backend (server-to-client) message of the PostgreSQL v3 protocol.
// Only the messages DXPostgres acts on are modeled; an unrecognized type tag is
// rejected at decode time as a protocol error rather than carried as an opaque
// case, so the connection never silently ignores something the server said.
enum BackendMessage: Sendable, Equatable {

    case authentication(AuthenticationRequest)
    case parameterStatus(name: String, value: String)
    case backendKeyData(processID: Int32, secretKey: Int32)
    case readyForQuery(transactionStatus: UInt8)
    case rowDescription([FieldDescription])
    case dataRow([PostgresCell])
    case commandComplete(tag: String)
    case emptyQueryResponse
    case noData
    case parseComplete
    case bindComplete
    case closeComplete
    case portalSuspended
    case parameterDescription([UInt32])
    case copyInResponse(binaryFormat: Bool)
    case error(PostgresServerError)
    case notice(PostgresServerError)
    case notification(processID: Int32, channel: String, payload: String)
}
