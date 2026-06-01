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

// The variants of the backend `Authentication` message ('R'), distinguished by
// the Int32 subtype that follows the message length. Methods DXPostgres does not
// implement (Kerberos, GSSAPI, SSPI) are carried as `unsupported` so the
// handshake can fail with a precise method name rather than a generic error.
enum AuthenticationRequest: Sendable, Equatable {

    case ok
    case cleartextPassword
    case md5Password(salt: [UInt8])
    case saslMechanisms([String])
    case saslContinue(data: [UInt8])
    case saslFinal(data: [UInt8])
    case unsupported(code: Int32)
}
