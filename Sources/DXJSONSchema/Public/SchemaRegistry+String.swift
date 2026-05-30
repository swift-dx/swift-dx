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

extension SchemaRegistry {

    public func validate(_ instance: String, type: String) -> SchemaValidationResult {
        validate(Array(instance.utf8), type: type)
    }
}
