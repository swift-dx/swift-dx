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

enum NatsProtocolBytes {

    static let hpubOp: [UInt8] = Array("HPUB ".utf8)
    static let msgOp: [UInt8] = Array("MSG ".utf8)
    static let hmsgOp: [UInt8] = Array("HMSG ".utf8)
    static let infoOp: [UInt8] = Array("INFO ".utf8)
    static let errOp: [UInt8] = Array("-ERR".utf8)
    static let pingControl: [UInt8] = Array("PI".utf8)
    static let pongControl: [UInt8] = Array("PO".utf8)
    static let pongResponse: [UInt8] = Array("PONG\r\n".utf8)
    static let pingResponse: [UInt8] = Array("\r\nPING\r\n".utf8)
    static let crlf: [UInt8] = Array("\r\n".utf8)
    static let doubleCrlf: [UInt8] = Array("\r\n\r\n".utf8)
    static let messageIdHeaderPrefix: [UInt8] = Array("NATS/1.0\r\nNats-Msg-Id: ".utf8)
    static let nonceKey: [UInt8] = Array("\"nonce\"".utf8)

    static let crlfLength: Int = crlf.count
    static let doubleCrlfLength: Int = doubleCrlf.count
    static let fieldSeparatorLength: Int = 1
}
