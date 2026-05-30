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

public struct ClickHouseColumnDefinition: Sendable, Hashable {

    public let name: String
    public let spec: ClickHouseColumnSpec

    public init(name: String, spec: ClickHouseColumnSpec) {
        self.name = name
        self.spec = spec
    }

    public var typeName: String {
        spec.typeName
    }

}
