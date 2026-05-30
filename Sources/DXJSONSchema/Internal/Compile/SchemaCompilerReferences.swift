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

extension SchemaCompiler {

    mutating func applyIdentifier(_ object: JSONObject, node: Int, at location: String) {
        guard case .found(.string(let identifier)) = object.lookup("$id") else { return }
        registerIdentifier(identifier.value, node: node, at: location)
    }

    mutating func registerIdentifier(_ identifier: String, node: Int, at location: String) {
        let resolved = resolveUri(currentBase, stripFragment(identifier))
        currentBase = resolved
        currentResourceNode = node
        idToNode[resolved] = node
        idToLocation[resolved] = location
    }

    mutating func compileResources(_ resources: [ResourceDocument]) throws(JSONSchemaError) {
        for resource in resources {
            try compileResource(resource)
        }
    }

    mutating func compileResource(_ resource: ResourceDocument) throws(JSONSchemaError) {
        currentBase = resource.uri
        currentResourceNode = nodes.count
        let node = try compileSubschema(resource.value, at: resource.uri)
        registerResourceRoot(resource.uri, node: node)
    }

    mutating func registerResourceRoot(_ uri: String, node: Int) {
        idToNode[uri] = node
        idToLocation[uri] = uri
    }

    mutating func registerReferenceRequest(_ value: JSONValue, keyword: String, at location: String) throws(JSONSchemaError) -> Int {
        let reference = try requireString(value, keyword: keyword, at: location)
        referenceRequests.append(ReferenceRequest(reference: reference, base: currentBase, location: location + "/$ref"))
        return referenceRequests.count - 1
    }

    mutating func compileDefinitions(_ value: JSONValue, at location: String) throws(JSONSchemaError) {
        guard case .object(let object) = value else {
            throw .keywordValueMalformed(keyword: "$defs", keywordLocation: location, expected: "an object of schemas")
        }
        try compileDefinitionMembers(object, at: location)
    }

    mutating func compileDefinitionMembers(_ object: JSONObject, at location: String) throws(JSONSchemaError) {
        for member in object.members {
            _ = try compileSubschema(member.value, at: location + "/$defs/" + member.key.value)
        }
    }

    mutating func registerDynamicAnchor(_ value: JSONValue, node: Int, at location: String) throws(JSONSchemaError) {
        let name = try requireString(value, keyword: "$dynamicAnchor", at: location)
        usesDynamicScope = true
        anchorToNode[currentBase + "#" + name] = node
        nodeAnchors[node] = name
        dynamicResources[currentResourceNode, default: [:]][name] = node
    }

    mutating func compileDynamicRef(_ value: JSONValue, keyword: String, at location: String, into keywords: inout [CompiledKeyword]) throws(JSONSchemaError) {
        let reference = try requireString(value, keyword: keyword, at: location)
        usesDynamicScope = true
        referenceRequests.append(ReferenceRequest(reference: reference, base: currentBase, location: location + "/$dynamicRef"))
        keywords.append(.dynamicReference(name: fragmentOf(reference), fallbackSlot: referenceRequests.count - 1))
    }

    mutating func registerAnchor(_ value: JSONValue, node: Int, at location: String) throws(JSONSchemaError) {
        let name = try requireString(value, keyword: "$anchor", at: location)
        anchorToNode[currentBase + "#" + name] = node
    }

    mutating func linkReferences() throws(JSONSchemaError) {
        for request in referenceRequests {
            referenceTargets.append(try resolveReference(request))
        }
    }

    func resolveReference(_ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        switch classifyReference(request.reference) {
        case .root: return resolveRoot(request)
        case .pointer(let fragment): return try resolvePointer(fragment, request)
        case .anchor(let name): return try resolveScopedAnchor(name, request)
        case .external: return try resolveExternal(request)
        }
    }

    func classifyReference(_ reference: String) -> ReferenceKind {
        guard reference.hasPrefix("#") else { return .external }
        return classifyFragment(String(reference.dropFirst()))
    }

    func classifyFragment(_ fragment: String) -> ReferenceKind {
        if fragment.isEmpty { return .root }
        if fragment.hasPrefix("/") { return .pointer(fragment) }
        return .anchor(fragment)
    }

    func resolveRoot(_ request: ReferenceRequest) -> Int {
        guard case .found(let index) = idLookup(request.base) else { return rootIndex }
        return index
    }

    func resolvePointer(_ fragment: String, _ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        guard case .found(let prefix) = locationForBase(request.base) else {
            throw .unresolvedReference(reference: request.reference, keywordLocation: request.location)
        }
        guard case .found(let index) = lookupPointer(prefix + decodePointer(fragment)) else {
            throw .unresolvedReference(reference: request.reference, keywordLocation: request.location)
        }
        return index
    }

    func locationForBase(_ base: String) -> Lookup<String> {
        guard let location = idToLocation[base] else { return .notFound }
        return .found(location)
    }

    func resolveScopedAnchor(_ name: String, _ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        guard case .found(let index) = anchorLookup(request.base + "#" + name) else {
            throw .unresolvedReference(reference: request.reference, keywordLocation: request.location)
        }
        return index
    }

    func resolveExternal(_ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        let resolved = resolveUri(request.base, stripFragment(request.reference))
        return try resolveAbsolute(resolved, fragmentOf(request.reference), request)
    }

    func resolveAbsolute(_ base: String, _ fragment: String, _ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        guard fragment.isEmpty else { return try resolveAbsoluteFragment(base, fragment, request) }
        guard case .found(let index) = idLookup(base) else {
            throw .unresolvedReference(reference: request.reference, keywordLocation: request.location)
        }
        return index
    }

    func resolveAbsoluteFragment(_ base: String, _ fragment: String, _ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        guard fragment.hasPrefix("/") else { return try resolveAbsoluteAnchor(base, fragment, request) }
        let scoped = ReferenceRequest(reference: request.reference, base: base, location: request.location)
        return try resolvePointer(fragment, scoped)
    }

    func resolveAbsoluteAnchor(_ base: String, _ fragment: String, _ request: ReferenceRequest) throws(JSONSchemaError) -> Int {
        guard case .found(let index) = anchorLookup(base + "#" + fragment) else {
            throw .unresolvedReference(reference: request.reference, keywordLocation: request.location)
        }
        return index
    }

    func lookupPointer(_ pointer: String) -> Lookup<Int> {
        guard let index = pointerToNode[pointer] else { return .notFound }
        return .found(index)
    }

    func anchorLookup(_ key: String) -> Lookup<Int> {
        guard let index = anchorToNode[key] else { return .notFound }
        return .found(index)
    }

    func idLookup(_ uri: String) -> Lookup<Int> {
        guard let index = idToNode[uri] else { return .notFound }
        return .found(index)
    }

    func decodePointer(_ fragment: String) -> String {
        percentDecode(fragment).replacing("~1", with: "/").replacing("~0", with: "~")
    }

    func percentDecode(_ text: String) -> String {
        guard text.contains("%") else { return text }
        return decodePercent(Array(text.utf8))
    }

    func decodePercent(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            index = appendDecoded(bytes, at: index, into: &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    func appendDecoded(_ bytes: [UInt8], at index: Int, into out: inout [UInt8]) -> Int {
        guard bytes[index] == 0x25, index + 2 < bytes.count else {
            out.append(bytes[index])
            return index + 1
        }
        out.append(hexNibble(bytes[index + 1]) << 4 | hexNibble(bytes[index + 2]))
        return index + 3
    }

    func hexNibble(_ byte: UInt8) -> UInt8 {
        if byte >= 0x30, byte <= 0x39 { return byte - 0x30 }
        return hexLetterNibble(byte)
    }

    func hexLetterNibble(_ byte: UInt8) -> UInt8 {
        if byte >= 0x41, byte <= 0x46 { return byte - 0x41 + 10 }
        if byte >= 0x61, byte <= 0x66 { return byte - 0x61 + 10 }
        return 0
    }

    func resolveUri(_ base: String, _ reference: String) -> String {
        guard !hasScheme(reference) else { return reference }
        guard !base.isEmpty, !reference.isEmpty else { return reference }
        return resolveRelative(base, reference)
    }

    func resolveRelative(_ base: String, _ reference: String) -> String {
        let authority = authorityPrefix(base)
        guard !reference.hasPrefix("/") else { return authority + normalizePath(reference) }
        return authority + normalizePath(mergePath(base, authority, reference))
    }

    func authorityPrefix(_ uri: String) -> String {
        guard let scheme = uri.firstRange(of: "://") else { return "" }
        return authorityUpToPath(uri, from: scheme.upperBound)
    }

    func authorityUpToPath(_ uri: String, from start: String.Index) -> String {
        guard let slash = uri[start...].firstIndex(of: "/") else { return uri }
        return String(uri[..<slash])
    }

    func mergePath(_ base: String, _ authority: String, _ reference: String) -> String {
        let path = String(base.dropFirst(authority.count))
        guard let slash = path.lastIndex(of: "/") else { return "/" + reference }
        return String(path[...slash]) + reference
    }

    func normalizePath(_ path: String) -> String {
        var output: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            applyPathSegment(segment, into: &output)
        }
        return output.joined(separator: "/")
    }

    func applyPathSegment(_ segment: Substring, into output: inout [Substring]) {
        switch segment {
        case ".": break
        case "..": dropPathSegment(&output)
        default: output.append(segment)
        }
    }

    func dropPathSegment(_ output: inout [Substring]) {
        guard output.count > 1 else { return }
        output.removeLast()
    }

    func hasScheme(_ reference: String) -> Bool {
        guard let colon = reference.firstIndex(of: ":") else { return false }
        return schemeIsValid(reference, before: colon)
    }

    func schemeIsValid(_ reference: String, before colon: String.Index) -> Bool {
        let scheme = reference[..<colon]
        guard !scheme.isEmpty, !scheme.contains("/") else { return false }
        return isAsciiLetter(scheme[scheme.startIndex])
    }

    func isAsciiLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    func stripFragment(_ reference: String) -> String {
        guard let hash = reference.firstIndex(of: "#") else { return reference }
        return String(reference[..<hash])
    }

    func fragmentOf(_ reference: String) -> String {
        guard let hash = reference.firstIndex(of: "#") else { return "" }
        return String(reference[reference.index(after: hash)...])
    }
}
