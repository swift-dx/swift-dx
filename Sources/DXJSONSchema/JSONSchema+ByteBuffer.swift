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

import NIOCore

extension JSONSchema {

    public static func compile(_ schema: ByteBuffer) throws(JSONSchemaError) -> JSONSchema {
        try compile(Array(schema.readableBytesView))
    }

    public static func compile(_ schema: ByteBuffer, formats: FormatAssertionMode) throws(JSONSchemaError) -> JSONSchema {
        try compile(Array(schema.readableBytesView), formats: formats)
    }

    public func validate(_ instance: ByteBuffer) -> SchemaValidationResult {
        validate(Array(instance.readableBytesView))
    }
}
