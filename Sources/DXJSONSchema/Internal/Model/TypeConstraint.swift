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

import DXCore

struct TypeConstraint: Sendable, Equatable {

    let allowed: Set<JSONValueKind>

    func permits(_ kind: JSONValueKind) -> Bool {
        if allowed.contains(kind) { return true }
        return kind == .integer && allowed.contains(.number)
    }
}
