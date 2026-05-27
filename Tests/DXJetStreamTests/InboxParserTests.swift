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
import Testing
@testable import DXJetStream

@Suite
struct InboxParserTests {

    @Test
    func inboxParser_parseSuffixDecodesBase36() {
        let bytes = Array("_INBOX.deadbeef.7n".utf8)
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        let view = buf.readableBytesView
        let prefix = Array("_INBOX.deadbeef".utf8)
        let result = InboxParser.parseSuffix(view, start: view.startIndex, end: view.endIndex, prefixBytes: prefix)
        #expect(result == .matched(UInt64(7 * 36 + 23)))
    }

    @Test
    func inboxParser_parseSuffixRejectsMismatchedPrefix() {
        let bytes = Array("_INBOX.other.7n".utf8)
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        let view = buf.readableBytesView
        let prefix = Array("_INBOX.deadbeef".utf8)
        let result = InboxParser.parseSuffix(view, start: view.startIndex, end: view.endIndex, prefixBytes: prefix)
        #expect(result == .notMatched)
    }

    @Test
    func inboxParser_parseSuffixRejectsInvalidBase36() {
        let bytes = Array("_INBOX.deadbeef.7Z!".utf8)
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        let view = buf.readableBytesView
        let prefix = Array("_INBOX.deadbeef".utf8)
        let result = InboxParser.parseSuffix(view, start: view.startIndex, end: view.endIndex, prefixBytes: prefix)
        #expect(result == .notMatched)
    }
}
