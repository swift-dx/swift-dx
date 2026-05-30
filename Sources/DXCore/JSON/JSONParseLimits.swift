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

package struct JSONParseLimits: Sendable, Equatable {

    package enum DuplicateKeyPolicy: Sendable, Equatable {

        case lastValueWins
        case reject
    }

    package let maxDepth: Int
    package let maxByteLength: Int
    package let duplicateKeys: DuplicateKeyPolicy

    package init(maxDepth: Int, maxByteLength: Int, duplicateKeys: DuplicateKeyPolicy) {
        self.maxDepth = maxDepth
        self.maxByteLength = maxByteLength
        self.duplicateKeys = duplicateKeys
    }

    package static var standard: JSONParseLimits {
        .init(maxDepth: 256, maxByteLength: 1 << 26, duplicateKeys: .lastValueWins)
    }

    package static var strict: JSONParseLimits {
        .init(maxDepth: 256, maxByteLength: 1 << 26, duplicateKeys: .reject)
    }
}
