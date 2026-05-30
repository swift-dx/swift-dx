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

final class EvaluationFrame {

    var evaluatedProperties: Set<String>
    var evaluatedItemCount: Int
    var containsMatched: Set<Int>

    init() {
        self.evaluatedProperties = []
        self.evaluatedItemCount = 0
        self.containsMatched = []
    }

    func absorb(_ other: EvaluationFrame) {
        evaluatedProperties.formUnion(other.evaluatedProperties)
        raiseItemCount(other.evaluatedItemCount)
        containsMatched.formUnion(other.containsMatched)
    }

    func raiseItemCount(_ count: Int) {
        guard count > evaluatedItemCount else { return }
        evaluatedItemCount = count
    }
}
