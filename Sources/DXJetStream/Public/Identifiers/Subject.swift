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

public struct Subject: Sendable, Hashable {

    public let value: String

    public init(_ value: String) throws(JetStreamError) {
        try Self.validate(value)
        self.value = value
    }

    static func validate(_ value: String) throws(JetStreamError) {
        try validateNonEmpty(value)
        try validateBoundaryDots(value)
        try validateCharacters(value)
    }

    private static func validateNonEmpty(_ value: String) throws(JetStreamError) {
        guard !value.isEmpty else {
            throw JetStreamError.invalidSubject(value)
        }
    }

    private static func validateBoundaryDots(_ value: String) throws(JetStreamError) {
        guard value.first != ".", value.last != "." else {
            throw JetStreamError.invalidSubject(value)
        }
    }

    private static func validateCharacters(_ value: String) throws(JetStreamError) {
        var previousWasDot = false
        for byte in value.utf8 {
            previousWasDot = try absorb(byte: byte, previousWasDot: previousWasDot, value: value)
        }
    }

    private static func absorb(byte: UInt8, previousWasDot: Bool, value: String) throws(JetStreamError) -> Bool {
        switch byte {
        case Ascii.upperA...Ascii.upperZ,
             Ascii.lowerA...Ascii.lowerZ,
             Ascii.digitZero...Ascii.digitNine,
             Ascii.hyphen, Ascii.underscore, Ascii.asterisk, Ascii.greaterThan, Ascii.dollar:
            return false
        case Ascii.dot:
            return try acceptDot(previousWasDot: previousWasDot, value: value)
        default:
            throw JetStreamError.invalidSubject(value)
        }
    }

    private static func acceptDot(previousWasDot: Bool, value: String) throws(JetStreamError) -> Bool {
        guard !previousWasDot else {
            throw JetStreamError.invalidSubject(value)
        }
        return true
    }
}
