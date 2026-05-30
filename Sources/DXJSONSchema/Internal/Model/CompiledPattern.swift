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

struct CompiledPattern: @unchecked Sendable {

    // A Regex value is immutable once constructed and firstMatch performs a
    // read-only traversal of that immutable program, so a single compiled
    // pattern is safe to share and match against from concurrent validators.
    let source: String
    let regex: Regex<AnyRegexOutput>

    init(_ source: String, at location: String) throws(JSONSchemaError) {
        self.source = source
        do {
            self.regex = try Regex(source)
        } catch {
            throw .patternNotValid(keywordLocation: location, pattern: source)
        }
    }

    func matches(_ string: String) -> Bool {
        switch try? regex.firstMatch(in: string) {
        case .some: true
        case .none: false
        }
    }
}
