# Integrity Rule Catalogue

Plain-language specifications for every built-in rule. Each rule has a
stable ID, a mirrored Swift implementation under
`Tooling/Integrity/Sources/Integrity/Rules/`, and at least one
regression test under `Tooling/Integrity/Tests/IntegrityTests/`.

Rules are grouped by area:

- **Generic** — language-agnostic. Apply to any source file regardless
  of language. Checks operate on raw text or trivia.
- **Swift** — Swift-specific. Use `swift-syntax` to walk the AST.
  Only meaningful when applied to `.swift` files.

## Generic

| ID   | Name             | Summary                                                                 | Spec                                       |
|------|------------------|-------------------------------------------------------------------------|--------------------------------------------|
| G001 | FileHeader       | Require a configured marker substring in every source file's header.    | [G001](Generic/G001-file-header.md)        |
| G002 | NoMarkComment    | Forbid `// MARK:` section comments; split the file by responsibility.   | [G002](Generic/G002-no-mark-comment.md)    |
| G003 | NoTodoComment    | Forbid `TODO` / `FIXME` / `XXX` / `HACK` comments.                      | [G003](Generic/G003-no-todo-comment.md)    |
| G004 | NoAIAttribution  | Forbid AI-attribution phrases in source.                                | [G004](Generic/G004-no-ai-attribution.md)  |
| G005 | TrailingNewline  | Require every source file to end with exactly one trailing newline.     | [G005](Generic/G005-trailing-newline.md)   |
| G006 | OneTopLevelPublicTypePerFile | Forbid more than one top-level public type declaration per file. | [G006](Generic/G006-one-top-level-public-type-per-file.md) |

## Swift

| ID   | Name                     | Summary                                                                  | Spec                                                  |
|------|--------------------------|--------------------------------------------------------------------------|-------------------------------------------------------|
| S001 | BannedAbbreviations      | Forbid configured banned identifier abbreviations.                       | [S001](Swift/S001-banned-abbreviations.md)            |
| S002 | NoOptionals              | Forbid Optional types; `weak var` exempt by Swift language constraint.   | [S002](Swift/S002-no-optionals.md)                    |
| S003 | NoAsyncSuffix            | Forbid `Async` suffix on functions declared `async`.                     | [S003](Swift/S003-no-async-suffix.md)                 |
| S004 | NoImplSuffix             | Forbid `Impl` suffix on public types.                                    | [S004](Swift/S004-no-impl-suffix-on-public-type.md)   |
| S006 | ServerSideImports        | Forbid imports of Apple-platform-only UI modules unavailable on Linux.   | [S006](Swift/S006-server-side-only-imports.md)        |
| S007 | NoForceUnwrap            | Forbid `!` force-unwrap, `try!`, `as!`; handle absence explicitly.       | [S007](Swift/S007-no-force-unwrap.md)                 |
| S008 | NoSingleton              | Forbid static singleton-style properties; inject instead.                | [S008](Swift/S008-no-singleton.md)                    |
| S009 | NoEmptyCatch             | Forbid empty catch blocks; if you catch, you handle.                     | [S009](Swift/S009-no-empty-catch.md)                  |
| S010 | RequireTypedThrowsOnPublic | Require typed throws on every public/open throwing function or initializer. | [S010](Swift/S010-require-typed-throws-on-public.md) |
| S011 | MaxCyclomaticComplexity  | Forbid functions whose cyclomatic complexity exceeds a configured maximum (default 3). | [S011](Swift/S011-max-cyclomatic-complexity.md) |

## Adding a new rule

1. Reserve the next ID in the area (e.g. `S007`, `G005`).
2. Write the plain-language spec at `Rules/<Area>/<ID>-<short-name>.md`.
   Sections: **Intent**, **Rule**, **What it does NOT check**,
   **Rationale**.
3. Implement the Swift type at
   `Sources/Integrity/Rules/<Area>/<Name>Rule.swift`. Conform to
   `IntegrityRule`. Set `ruleID`, `ruleName`, `ruleArea`, `summary`.
4. Add at least one positive case and several negative cases in
   `Tests/IntegrityTests/<Name>RuleTests.swift`.
5. Add the rule to `BuiltInRules.catalogue` and the appropriate
   helper (`generic` or `swift`).
6. Register the rule's `type` string in
   `IntegrityConfig.buildRule(id:entry:)` so JSON configurations can
   instantiate it.
7. Update this catalogue.

## Rule design principles

- **Single responsibility.** One rule states one principle. If a rule
  has two unrelated failure modes, split it.
- **Stable ID.** Once published, a rule ID is never reused. New rules
  get a new ID.
- **Deterministic checking.** Same input, same output. No clock, no
  randomness, no machine-dependent ordering.
- **Plain-language spec.** A reviewer with no Swift expertise can read
  the spec and understand what the rule forbids and why.
- **Opinionated defaults baked into the rule.** Lists, markers, and
  thresholds (the banned-abbreviation set for S001, the SPDX marker
  for G001, `max: 3` for S011) live inside each rule's Swift source.
  Projects that need different behaviour write a new rule type with
  a new ID, not a config override.
- **Edge cases recognised by the rule, not exempted by config.** Where
  a rule has unavoidable carve-outs (e.g. `weak var` for the
  NoOptionals rule), the rule's own logic recognises and skips them.
  There are no per-file exemptions and no per-project config knobs.
