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

// Parses a SCRAM message into its comma-separated `key=value` attributes. SCRAM
// keys are single characters ('r' nonce, 's' salt, 'i' iteration count, 'v'
// verifier, 'e' error), but parsing tolerates any key so a future attribute does
// not break the split. A token without '=' is skipped rather than treated as an
// error here; the caller decides which keys are mandatory.
enum ScramAttributes {

    static func parse(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for token in text.split(separator: ",", omittingEmptySubsequences: true) {
            absorb(token, into: &attributes)
        }
        return attributes
    }

    private static func absorb(_ token: Substring, into attributes: inout [String: String]) {
        guard let separatorIndex = token.firstIndex(of: "=") else { return }
        let key = String(token[token.startIndex..<separatorIndex])
        let value = String(token[token.index(after: separatorIndex)...])
        attributes[key] = value
    }
}
