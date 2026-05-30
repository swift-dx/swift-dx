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

enum PointerRenderer {

    static func instance(_ tokens: [PathToken]) -> String {
        var result = ""
        for token in tokens {
            result += "/" + escapedToken(token)
        }
        return result
    }

    static func escapedToken(_ token: PathToken) -> String {
        switch token {
        case .key(let key): escape(key)
        case .index(let index): String(index)
        }
    }

    static func keyword(_ tokens: [String], keyword: String) -> String {
        path(tokens) + "/" + escape(keyword)
    }

    static func path(_ tokens: [String]) -> String {
        var result = ""
        for token in tokens {
            result += "/" + escape(token)
        }
        return result
    }

    static func escape(_ token: String) -> String {
        var result = ""
        for character in token {
            result += escapedCharacter(character)
        }
        return result
    }

    static func escapedCharacter(_ character: Character) -> String {
        switch character {
        case "~": "~0"
        case "/": "~1"
        default: String(character)
        }
    }
}
