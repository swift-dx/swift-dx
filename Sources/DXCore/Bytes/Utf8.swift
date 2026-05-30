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

package enum Utf8 {

    package static func isValid(_ bytes: some Sequence<UInt8>) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        var outcome = decoder.decode(&iterator)
        while case .scalarValue = outcome {
            outcome = decoder.decode(&iterator)
        }
        return reachedEnd(outcome)
    }

    private static func reachedEnd(_ outcome: UnicodeDecodingResult) -> Bool {
        switch outcome {
        case .emptyInput: true
        case .scalarValue: false
        case .error: false
        }
    }
}
