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

public enum BuiltInRules {

    public static func makeRule(id: String) throws(ConfigError) -> any IntegrityRule {
        switch id {
        case "G001": return FileHeaderRule(ruleID: id)
        case "G002": return NoMarkCommentRule(ruleID: id)
        case "G003": return NoTodoCommentRule(ruleID: id)
        case "G004": return NoAIAttributionRule(ruleID: id)
        case "G005": return TrailingNewlineRule(ruleID: id)
        case "G006": return OneTopLevelPublicTypePerFileRule(ruleID: id)
        case "S001": return BannedAbbreviationsRule(ruleID: id)
        case "S002": return NoOptionalsRule(ruleID: id)
        case "S003": return NoAsyncSuffixRule(ruleID: id)
        case "S004": return NoImplSuffixRule(ruleID: id)
        case "S006": return ServerSideImportsRule(ruleID: id)
        case "S007": return NoForceUnwrapRule(ruleID: id)
        case "S008": return NoSingletonRule(ruleID: id)
        case "S009": return NoEmptyCatchRule(ruleID: id)
        case "S010": return RequireTypedThrowsOnPublicRule(ruleID: id)
        case "S011": return MaxCyclomaticComplexityRule(ruleID: id)
        default: throw ConfigError.unknownRuleID(id)
        }
    }

    public static let all: [any IntegrityRule] = [
        FileHeaderRule(),
        NoMarkCommentRule(),
        NoTodoCommentRule(),
        NoAIAttributionRule(),
        TrailingNewlineRule(),
        OneTopLevelPublicTypePerFileRule(),
        BannedAbbreviationsRule(),
        NoOptionalsRule(),
        NoAsyncSuffixRule(),
        NoImplSuffixRule(),
        ServerSideImportsRule(),
        NoForceUnwrapRule(),
        NoSingletonRule(),
        NoEmptyCatchRule(),
        RequireTypedThrowsOnPublicRule(),
        MaxCyclomaticComplexityRule(),
    ]

    public static let catalogue: [BuiltInRuleDescriptor] = [
        BuiltInRuleDescriptor(
            id: "G001",
            name: "FileHeader",
            area: .generic,
            summary: "Require an SPDX-License-Identifier line in every source file.",
            specFile: "Rules/Generic/G001-file-header.md"
        ),
        BuiltInRuleDescriptor(
            id: "G002",
            name: "NoMarkComment",
            area: .generic,
            summary: "Forbid // MARK: section comments; split the file by responsibility instead.",
            specFile: "Rules/Generic/G002-no-mark-comment.md"
        ),
        BuiltInRuleDescriptor(
            id: "G003",
            name: "NoTodoComment",
            area: .generic,
            summary: "Forbid TODO / FIXME / XXX / HACK comments; track deferred work in the issue tracker.",
            specFile: "Rules/Generic/G003-no-todo-comment.md"
        ),
        BuiltInRuleDescriptor(
            id: "G004",
            name: "NoAIAttribution",
            area: .generic,
            summary: "Forbid AI-attribution phrases in source.",
            specFile: "Rules/Generic/G004-no-ai-attribution.md"
        ),
        BuiltInRuleDescriptor(
            id: "G005",
            name: "TrailingNewline",
            area: .generic,
            summary: "Require every source file to end with exactly one trailing newline.",
            specFile: "Rules/Generic/G005-trailing-newline.md"
        ),
        BuiltInRuleDescriptor(
            id: "G006",
            name: "OneTopLevelPublicTypePerFile",
            area: .generic,
            summary: "Forbid more than one top-level public type declaration per file.",
            specFile: "Rules/Generic/G006-one-top-level-public-type-per-file.md"
        ),
        BuiltInRuleDescriptor(
            id: "S001",
            name: "BannedAbbreviations",
            area: .swift,
            summary: "Forbid identifier abbreviations from the canonical banned list.",
            specFile: "Rules/Swift/S001-banned-abbreviations.md"
        ),
        BuiltInRuleDescriptor(
            id: "S002",
            name: "NoOptionals",
            area: .swift,
            summary: "Forbid Optional types; weak var and subscript signatures exempt.",
            specFile: "Rules/Swift/S002-no-optionals.md"
        ),
        BuiltInRuleDescriptor(
            id: "S003",
            name: "NoAsyncSuffix",
            area: .swift,
            summary: "Forbid 'Async' suffix on functions already declared async.",
            specFile: "Rules/Swift/S003-no-async-suffix.md"
        ),
        BuiltInRuleDescriptor(
            id: "S004",
            name: "NoImplSuffix",
            area: .swift,
            summary: "Forbid 'Impl' suffix on public types.",
            specFile: "Rules/Swift/S004-no-impl-suffix-on-public-type.md"
        ),
        BuiltInRuleDescriptor(
            id: "S006",
            name: "ServerSideImports",
            area: .swift,
            summary: "Forbid imports of Apple-platform-only UI modules unavailable on Linux.",
            specFile: "Rules/Swift/S006-server-side-only-imports.md"
        ),
        BuiltInRuleDescriptor(
            id: "S007",
            name: "NoForceUnwrap",
            area: .swift,
            summary: "Forbid force-unwrap on optionals (!), try!, and as!; handle absence explicitly.",
            specFile: "Rules/Swift/S007-no-force-unwrap.md"
        ),
        BuiltInRuleDescriptor(
            id: "S008",
            name: "NoSingleton",
            area: .swift,
            summary: "Forbid static singleton-style properties; inject instances instead of exposing global access.",
            specFile: "Rules/Swift/S008-no-singleton.md"
        ),
        BuiltInRuleDescriptor(
            id: "S009",
            name: "NoEmptyCatch",
            area: .swift,
            summary: "Forbid empty catch blocks; if you catch, you handle.",
            specFile: "Rules/Swift/S009-no-empty-catch.md"
        ),
        BuiltInRuleDescriptor(
            id: "S010",
            name: "RequireTypedThrowsOnPublic",
            area: .swift,
            summary: "Require typed throws on every public/open throwing function or initializer.",
            specFile: "Rules/Swift/S010-require-typed-throws-on-public.md"
        ),
        BuiltInRuleDescriptor(
            id: "S011",
            name: "MaxCyclomaticComplexity",
            area: .swift,
            summary: "Forbid functions whose cyclomatic complexity exceeds 3.",
            specFile: "Rules/Swift/S011-max-cyclomatic-complexity.md"
        ),
    ]
}

public struct BuiltInRuleDescriptor: Sendable, Equatable {

    public let id: String
    public let name: String
    public let area: RuleArea
    public let summary: String
    public let specFile: String

    public init(id: String, name: String, area: RuleArea, summary: String, specFile: String) {
        self.id = id
        self.name = name
        self.area = area
        self.summary = summary
        self.specFile = specFile
    }
}
