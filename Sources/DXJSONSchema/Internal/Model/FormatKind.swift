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

enum FormatKind: Sendable, Equatable {

    case dateTime
    case date
    case time
    case duration
    case email
    case hostname
    case ipv4
    case ipv6
    case uri
    case uriReference
    case uuid
    case jsonPointer
    case relativeJsonPointer
    case regularExpression
    case unrecognized

    init(_ name: String) {
        self = FormatKind.byName(name)
    }

    static func byName(_ name: String) -> FormatKind {
        switch name {
        case "date-time": .dateTime
        case "date": .date
        case "time": .time
        case "duration": .duration
        case "email": .email
        case "hostname": .hostname
        case "ipv4": .ipv4
        case "ipv6": .ipv6
        case "uri": .uri
        case "uri-reference": .uriReference
        case "uuid": .uuid
        case "json-pointer": .jsonPointer
        case "relative-json-pointer": .relativeJsonPointer
        case "regex": .regularExpression
        default: .unrecognized
        }
    }
}
