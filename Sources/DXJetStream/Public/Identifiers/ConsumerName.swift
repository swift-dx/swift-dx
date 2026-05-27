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

public struct ConsumerName: Sendable, Hashable {

    public let value: String

    public init(_ value: String) throws(JetStreamError) {
        try Self.validate(value)
        self.value = value
    }

    static func validate(_ value: String) throws(JetStreamError) {
        guard !value.isEmpty, value.count <= JetStreamNameLimit.maxLength else {
            throw JetStreamError.invalidConsumerName(value)
        }
        for byte in value.utf8 {
            switch byte {
            case Ascii.upperA...Ascii.upperZ,
                 Ascii.lowerA...Ascii.lowerZ,
                 Ascii.digitZero...Ascii.digitNine,
                 Ascii.hyphen, Ascii.underscore:
                continue
            default:
                throw JetStreamError.invalidConsumerName(value)
            }
        }
    }
}
