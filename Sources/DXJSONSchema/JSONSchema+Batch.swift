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

extension JSONSchema {

    public func validate<Instances: Sequence & Sendable>(batch instances: Instances) -> [SchemaValidationResult] where Instances.Element == [UInt8] {
        var results: [SchemaValidationResult] = []
        for instance in instances {
            results.append(validate(instance))
        }
        return results
    }
}
