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

enum NKeyPrefix: UInt8 {

    case seed = 144
    case user = 160
    case account = 0
    case server = 104
    case cluster = 16
    case operatorEntity = 112
    case curve = 184
}
