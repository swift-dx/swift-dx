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

import Foundation

extension SchemaRegistry {

    public func validate<Instance: Encodable & Sendable>(encoding instance: Instance, type: String) -> SchemaValidationResult {
        do {
            return validate(Array(try JSONEncoder().encode(instance)), type: type)
        } catch {
            return .instanceNotValidJSON(byteOffset: 0, hint: "instance could not be encoded to JSON")
        }
    }
}
