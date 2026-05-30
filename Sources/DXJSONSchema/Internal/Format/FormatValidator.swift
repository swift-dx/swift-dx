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

enum FormatValidator {

    static func check(_ kind: FormatKind, _ string: String) -> Bool {
        switch kind {
        case .dateTime: FormatTemporal.isDateTime(string)
        case .date: FormatTemporal.isDate(string)
        case .time: FormatTemporal.isTime(string)
        case .duration: FormatTemporal.isDuration(string)
        case .email: FormatNetwork.isEmail(string)
        case .hostname: FormatNetwork.isHostname(string)
        case .ipv4: FormatNetwork.isIPv4(string)
        case .ipv6: FormatNetwork.isIPv6(string)
        case .uri: FormatNetwork.isURI(string)
        case .uriReference: FormatNetwork.isURIReference(string)
        case .uuid: FormatStructural.isUUID(string)
        case .jsonPointer: FormatStructural.isJSONPointer(string)
        case .relativeJsonPointer: FormatStructural.isRelativeJSONPointer(string)
        case .regularExpression: FormatStructural.isRegularExpression(string)
        case .unrecognized: true
        }
    }
}
