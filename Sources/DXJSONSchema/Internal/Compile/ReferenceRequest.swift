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

struct ReferenceRequest: Sendable, Equatable {

    let reference: String
    let base: String
    let location: String
}

enum ReferenceKind: Sendable, Equatable {

    case root
    case pointer(String)
    case anchor(String)
    case external
}
