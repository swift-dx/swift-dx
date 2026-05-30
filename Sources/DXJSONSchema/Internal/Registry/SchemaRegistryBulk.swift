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

extension SchemaRegistry {

    public func apply(_ envelopes: [SchemaEnvelope]) throws(JSONSchemaError) {
        let grouped = try compileGrouped(envelopes)
        writeLock.withLock { _ in
            current.store(current.load(ordering: .acquiring).withTypes(grouped), ordering: .releasing)
        }
    }

    public func merge(_ envelopes: [SchemaEnvelope]) throws(JSONSchemaError) {
        let grouped = try compileGrouped(envelopes)
        writeLock.withLock { _ in
            current.store(current.load(ordering: .acquiring).merging(grouped), ordering: .releasing)
        }
    }

    func compileGrouped(_ envelopes: [SchemaEnvelope]) throws(JSONSchemaError) -> [String: [JSONSchema]] {
        let metaGate = try Self.metaSchemaGate()
        var grouped: [String: [JSONSchema]] = [:]
        for envelope in envelopes {
            try addEnvelope(envelope, metaGate, into: &grouped)
        }
        return grouped
    }

    func addEnvelope(_ envelope: SchemaEnvelope, _ metaGate: JSONSchema, into grouped: inout [String: [JSONSchema]]) throws(JSONSchemaError) {
        guard !envelope.type.isEmpty else { throw .invalidSchemaType }
        grouped[envelope.type, default: []].append(try compileValidated(envelope.schema, type: envelope.type, metaGate))
    }

    func compileValidated(_ bytes: [UInt8], type: String, _ metaGate: JSONSchema) throws(JSONSchemaError) -> JSONSchema {
        let compiled = try JSONSchema.compile(bytes)
        try requireMetaValid(bytes, type: type, metaGate)
        return compiled
    }

    func requireMetaValid(_ bytes: [UInt8], type: String, _ metaGate: JSONSchema) throws(JSONSchemaError) {
        guard case .invalid = metaGate.validate(bytes) else { return }
        throw .invalidSchemaStructure(type: type)
    }

    static func metaSchemaGate() throws(JSONSchemaError) -> JSONSchema {
        try JSONSchema.compile(metaSchemaReference, resources: JSONSchema.draft2020MetaSchemaResources)
    }
}

private let metaSchemaReference = Array(##"{"$ref":"https://json-schema.org/draft/2020-12/schema"}"##.utf8)
