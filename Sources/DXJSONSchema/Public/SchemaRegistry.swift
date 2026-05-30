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
import Synchronization
import DXCore

public final class SchemaRegistry: Sendable {

    let current: ManagedAtomic<RegistrySnapshot>
    let writeLock: Mutex<Int>

    public init() {
        self.current = ManagedAtomic(RegistrySnapshot(types: [:], generation: 0))
        self.writeLock = Mutex(0)
    }

    public var generation: RegistryGeneration {
        RegistryGeneration(current.load(ordering: .acquiring).generation)
    }

    public var registeredTypes: [String] {
        Array(current.load(ordering: .acquiring).types.keys)
    }

    public func revisionCount(ofType type: String) -> Int {
        current.load(ordering: .acquiring).schemas(for: type).count
    }

    public func validate(_ instance: [UInt8], type: String) -> SchemaValidationResult {
        Self.validate(instance, against: current.load(ordering: .acquiring).schemas(for: type), type: type)
    }

    static func validate(_ instance: [UInt8], against revisions: [JSONSchema], type: String) -> SchemaValidationResult {
        guard !revisions.isEmpty else { return .schemaNotRegistered(type: type) }
        do {
            return firstAccepting(try JSONParser.parse(instance, limits: .strict), revisions, type)
        } catch {
            return .instanceNotValidJSON(byteOffset: JSONParseFailure.byteOffset(error), hint: JSONParseFailure.hint(error))
        }
    }

    static func firstAccepting(_ value: JSONValue, _ revisions: [JSONSchema], _ type: String) -> SchemaValidationResult {
        for schema in revisions where schema.validate(value).isValid {
            return .valid
        }
        return rejectedByAll(type)
    }

    static func rejectedByAll(_ type: String) -> SchemaValidationResult {
        .invalid([SchemaViolation(
            instanceLocation: "",
            keywordLocation: "",
            keyword: "type",
            message: "instance does not satisfy any registered schema for type '\(type)'"
        )])
    }
}
