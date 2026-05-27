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

enum InboxGenerator {

    static func newPrefix() -> String {
        "_INBOX." + HexIdGenerator.newLowerHexString(byteCount: 12)
    }
}
