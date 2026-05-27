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

import Testing
import NIOCore
@testable import DXJetStream

@Suite
struct FrameBuilderEdgeCaseTests {

    @Test
    func emptyPayload_pubFrameContainsZeroLength() {
        let buf = FrameBuilder.buildPublishBatchPlain(
            allocator: ByteBufferAllocator(),
            subject: "s",
            inboxPrefixBytes: Array("_INBOX.x".utf8),
            payloads: [[]],
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        #expect(text.contains(" 0\r\n"))
    }

    @Test
    func base36Zero_writesSingleZeroDigit() {
        var storage = [UInt8](repeating: 0, count: 8)
        storage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            FrameBuilder.writeBase36(dst: base, off: &offset, value: 0, length: 1)
            #expect(offset == 1)
            #expect(base[0] == UInt8(ascii: "0"))
        }
    }

    @Test
    func decimalZero_writesSingleZeroDigit() {
        var storage = [UInt8](repeating: 0, count: 8)
        storage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            FrameBuilder.writeDecimal(dst: base, off: &offset, value: 0, length: 1)
            #expect(offset == 1)
            #expect(base[0] == UInt8(ascii: "0"))
        }
    }
}
