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

import Atomics
import DXCore

final class RegistrySnapshot: Sendable, AtomicReference {

    let types: [String: [JSONSchema]]
    let generation: UInt64

    init(types: [String: [JSONSchema]], generation: UInt64) {
        self.types = types
        self.generation = generation
    }

    func schemas(for type: String) -> [JSONSchema] {
        guard let revisions = types[type] else { return [] }
        return revisions
    }

    func withTypes(_ replacement: [String: [JSONSchema]]) -> RegistrySnapshot {
        RegistrySnapshot(types: replacement, generation: generation + 1)
    }

    func merging(_ additions: [String: [JSONSchema]]) -> RegistrySnapshot {
        var copy = types
        copy.merge(additions) { _, replacement in replacement }
        return RegistrySnapshot(types: copy, generation: generation + 1)
    }
}
