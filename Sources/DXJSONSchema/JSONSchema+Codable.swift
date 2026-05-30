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

extension JSONSchema {

    /// Encodes `instance` with a default `JSONEncoder`, then validates the resulting JSON.
    ///
    /// A default `JSONEncoder` represents `Date` as numeric seconds and applies Foundation's
    /// default number and `Data` formatting, so a schema expecting ISO-8601 date strings (or
    /// any other representation) will not match that output. To control the JSON representation,
    /// encode the instance with a configured encoder and pass the bytes to ``validate(_:)``.
    public func validate<Instance: Encodable & Sendable>(encoding instance: Instance) -> SchemaValidationResult {
        do {
            return validate(Array(try JSONEncoder().encode(instance)))
        } catch {
            return .instanceNotValidJSON(byteOffset: 0, hint: "instance could not be encoded to JSON")
        }
    }
}
