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

import NIOCore

// CH's binary protocol has no per-packet length prefix — the connection
// has to attempt to parse a packet and back off if the buffer doesn't
// hold the full body yet. This helper centralizes the save/try/rewind
// dance so individual codecs stay free of framing concerns.
//
// Recoverable errors (the parse blew through the end of the buffer mid-
// codec) cause the reader index to be restored to its pre-attempt
// position so the caller can re-attempt after appending more bytes.
// Fatal errors (malformed wire data, value overflows, unknown types)
// propagate as-is — no amount of additional bytes will let them recover.
enum ClickHouseFraming {

    enum FrameResult<T: Sendable>: Sendable {

        case complete(T)
        case needsMoreBytes

    }

    static func tryFrame<T: Sendable>(
        from buffer: inout ByteBuffer,
        parse: (inout ByteBuffer) throws -> T
    ) throws -> FrameResult<T> {
        let savedReaderIndex = buffer.readerIndex
        do {
            return .complete(try parse(&buffer))
        } catch let error as ClickHouseError where Self.isRecoverable(error) {
            buffer.moveReaderIndex(to: savedReaderIndex)
            return .needsMoreBytes
        }
    }

    private static func isRecoverable(_ error: ClickHouseError) -> Bool {
        switch error {
        case .truncatedBuffer, .uvarintIncomplete, .stringLengthExceedsBuffer,
             .compressionFrameTruncated:
            return true
        default:
            return false
        }
    }

}
