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

import Logging

final class CapturingLogHandler: LogHandler, @unchecked Sendable {

    struct Entry: Sendable {

        let level: Logger.Level
        let message: String
        let metadata: Logger.Metadata
    }

    private(set) var entries: [Entry] = []
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata mergedMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let combined: Logger.Metadata = mergedMetadata ?? [:]
        entries.append(Entry(level: level, message: message.description, metadata: combined))
    }

    func metadataString(at index: Int, key: String) -> String {
        switch entries[index].metadata[key] {
        case .some(.string(let stringValue)): return stringValue
        case .some(let other): return "\(other)"
        case .none: return ""
        }
    }
}
