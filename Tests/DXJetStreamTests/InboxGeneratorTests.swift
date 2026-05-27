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
@testable import DXJetStream

@Suite
struct InboxGeneratorTests {

    @Test
    func inboxGenerator_startsWithInboxPrefix() {
        let inbox = InboxGenerator.newPrefix()
        #expect(inbox.hasPrefix("_INBOX."))
    }

    @Test
    func inboxGenerator_producesHexSuffixOfExpectedLength() {
        let inbox = InboxGenerator.newPrefix()
        let suffix = inbox.dropFirst("_INBOX.".count)
        #expect(suffix.count == 24)
        for character in suffix {
            #expect(isLowercaseHexCharacter(character))
        }
    }

    private func isLowercaseHexCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return isAsciiDigit(scalar) || isAsciiLowerHex(scalar)
    }

    private func isAsciiDigit(_ scalar: UInt32) -> Bool {
        scalar >= 0x30 && scalar <= 0x39
    }

    private func isAsciiLowerHex(_ scalar: UInt32) -> Bool {
        scalar >= 0x61 && scalar <= 0x66
    }

    @Test
    func inboxGenerator_returnsUniquePrefixes() {
        var seen: Set<String> = []
        for _ in 0..<1000 {
            seen.insert(InboxGenerator.newPrefix())
        }
        #expect(seen.count == 1000)
    }
}
