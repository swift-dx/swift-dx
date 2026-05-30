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

import Foundation
import NIOCore

// A payload delivered to a subscription handler. The bytes are exposed in
// whichever form the caller wants — raw, UTF-8 string, NIO buffer, or a decoded
// Codable value — mirroring the read surface of the rest of the client. The
// channel a message arrived on is delivered as a separate handler argument, so
// this type carries the payload only.
public struct RedisMessage: Sendable {

    public let buffer: ByteBuffer

    public init(buffer: ByteBuffer) {
        self.buffer = buffer
    }

    public func bytes() -> [UInt8] {
        Array(buffer.readableBytesView)
    }

    public func string() throws(RedisError) -> String {
        guard let decoded = String(bytes: buffer.readableBytesView, encoding: .utf8) else {
            throw RedisError.utf8DecodingFailed
        }
        return decoded
    }

    public func decode<Value: Decodable & Sendable>(as type: Value.Type) throws(RedisError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: Data(buffer.readableBytesView))
        } catch {
            throw RedisError.jsonDecodingFailed(typeName: String(describing: type), reason: String(describing: error))
        }
    }
}
