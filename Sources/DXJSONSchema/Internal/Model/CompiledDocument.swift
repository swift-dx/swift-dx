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

struct CompiledDocument: Sendable {

    let nodes: [Subschema]
    let root: Int
    let refTargets: [Int]
    let usesUnevaluated: Bool
    let usesDynamicScope: Bool
    let nodeAnchors: [Int: String]
    let dynamicResources: [Int: [String: Int]]
    let nodeResource: [Int: Int]

    func node(at index: Int) -> Subschema {
        nodes[index]
    }

    func refTarget(at slot: Int) -> Int {
        refTargets[slot]
    }

    func dynamicAnchorName(at index: Int) -> Lookup<String> {
        guard let name = nodeAnchors[index] else { return .notFound }
        return .found(name)
    }

    func resource(of index: Int) -> Int {
        guard let resource = nodeResource[index] else { return index }
        return resource
    }

    func dynamicAnchorTarget(inResource index: Int, name: String) -> Lookup<Int> {
        guard let target = dynamicResources[index]?[name] else { return .notFound }
        return .found(target)
    }
}
