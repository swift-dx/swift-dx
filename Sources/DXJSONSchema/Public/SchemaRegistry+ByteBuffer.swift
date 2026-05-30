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

extension SchemaRegistry {

    public func validate(_ instance: ByteBuffer, type: String) -> SchemaValidationResult {
        validate(Array(instance.readableBytesView), type: type)
    }
}

extension SchemaEnvelope {

    public init(type: String, schema: ByteBuffer) {
        self.init(type: type, schema: Array(schema.readableBytesView))
    }
}
