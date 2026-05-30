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

enum SchemaVocabulary: Sendable {

    case core
    case applicator
    case unevaluated
    case validation
    case metaData
    case formatAnnotation
    case content
}

extension SchemaVocabulary {

    static let all: Set<SchemaVocabulary> = [
        .core, .applicator, .unevaluated, .validation, .metaData, .formatAnnotation, .content,
    ]
}

extension SchemaVocabulary: Hashable {}
