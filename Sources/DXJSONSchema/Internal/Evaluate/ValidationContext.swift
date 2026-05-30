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

final class ValidationContext {

    static let maxRecursion = 5_000

    let document: CompiledDocument
    let tracksEvaluation: Bool
    let tracksLocations: Bool
    let tracksDynamicScope: Bool
    var violations: [SchemaViolation]
    var instanceTokens: [PathToken]
    var keywordTokens: [String]
    var recursionDepth: Int
    var frames: [EvaluationFrame]
    var dynamicScope: [Int]

    init(document: CompiledDocument, tracksLocations: Bool) {
        self.document = document
        self.tracksEvaluation = document.usesUnevaluated
        self.tracksLocations = tracksLocations
        self.tracksDynamicScope = document.usesDynamicScope
        self.violations = []
        self.instanceTokens = []
        self.keywordTokens = []
        self.recursionDepth = 0
        self.frames = []
        self.dynamicScope = []
    }

    func pushResource(at index: Int) -> Bool {
        let resource = document.resource(of: index)
        guard !topResourceEquals(resource) else { return false }
        dynamicScope.append(resource)
        return true
    }

    func topResourceEquals(_ resource: Int) -> Bool {
        guard !dynamicScope.isEmpty else { return false }
        return dynamicScope[dynamicScope.count - 1] == resource
    }

    func popResource() {
        dynamicScope.removeLast()
    }

    func dynamicTarget(_ name: String, fallback: Int) -> Int {
        for resource in dynamicScope {
            guard case .found(let node) = document.dynamicAnchorTarget(inResource: resource, name: name) else { continue }
            return node
        }
        return fallback
    }

    var currentFrame: EvaluationFrame {
        frames[frames.count - 1]
    }

    func pushFrame() {
        frames.append(EvaluationFrame())
    }

    func popFrame() {
        frames.removeLast()
    }

    func markProperty(_ name: String) {
        guard tracksEvaluation else { return }
        currentFrame.evaluatedProperties.insert(name)
    }

    func markItems(upTo count: Int) {
        guard tracksEvaluation else { return }
        currentFrame.raiseItemCount(count)
    }

    func markContains(_ index: Int) {
        guard tracksEvaluation else { return }
        currentFrame.containsMatched.insert(index)
    }

    func absorb(_ frame: EvaluationFrame) {
        currentFrame.absorb(frame)
    }

    func descend() -> Bool {
        guard recursionDepth < Self.maxRecursion else { return false }
        recursionDepth += 1
        return true
    }

    func ascend() {
        recursionDepth -= 1
    }

    func pushInstanceKey(_ key: String) {
        guard tracksLocations else { return }
        instanceTokens.append(.key(key))
    }

    func pushInstanceIndex(_ index: Int) {
        guard tracksLocations else { return }
        instanceTokens.append(.index(index))
    }

    func popInstance() {
        guard tracksLocations else { return }
        instanceTokens.removeLast()
    }

    func pushKeyword(_ token: String) {
        guard tracksLocations else { return }
        keywordTokens.append(token)
    }

    func popKeyword() {
        guard tracksLocations else { return }
        keywordTokens.removeLast()
    }

    func instanceLocationString() -> String {
        guard tracksLocations else { return "" }
        return PointerRenderer.instance(instanceTokens)
    }

    func keywordPathString() -> String {
        guard tracksLocations else { return "" }
        return PointerRenderer.path(keywordTokens)
    }

    func keywordLocationString(_ keyword: String) -> String {
        guard tracksLocations else { return "" }
        return PointerRenderer.keyword(keywordTokens, keyword: keyword)
    }

    func record(keyword: String, message: String) {
        violations.append(SchemaViolation(
            instanceLocation: instanceLocationString(),
            keywordLocation: keywordLocationString(keyword),
            keyword: keyword,
            message: message
        ))
    }

    func recordNever() {
        violations.append(SchemaViolation(
            instanceLocation: instanceLocationString(),
            keywordLocation: keywordPathString(),
            keyword: "false",
            message: "no value is allowed by a false schema"
        ))
    }

    func recordRecursionLimit() {
        violations.append(SchemaViolation(
            instanceLocation: instanceLocationString(),
            keywordLocation: keywordPathString(),
            keyword: "$ref",
            message: "maximum reference recursion depth exceeded"
        ))
    }
}
