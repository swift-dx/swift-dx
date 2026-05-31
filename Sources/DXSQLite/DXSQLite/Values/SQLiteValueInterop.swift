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

extension SQLiteValue {

    public static func json<T: Encodable>(_ value: T) throws(SQLiteError) -> SQLiteValue {
        do {
            let data = try JSONEncoder().encode(value)
            return .text(String(decoding: data, as: UTF8.self))
        } catch {
            throw SQLiteError.encodingFailed(type: String(describing: T.self), reason: String(describing: error))
        }
    }

    public init(blob buffer: ByteBuffer) {
        var readable = buffer
        self = .blob(readable.readBytes(length: readable.readableBytes) ?? [])
    }

    public func byteBuffer() throws(SQLiteError) -> ByteBuffer {
        ByteBuffer(bytes: try blob())
    }
}
