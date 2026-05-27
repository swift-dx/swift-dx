# Integrity

A deterministic, swift-syntax-based code-quality checker for Swift
projects. Ships as a SwiftPM library, an executable runner, a build-tool
plugin, and a command plugin. The plugin runs during `swift build` of
the host package and emits violations as compiler-style errors that
fail the build.

Any Swift project can adopt Integrity to encode its architectural
conventions as rules, attach the build plugin, and fail the build
when a convention is violated. The rules ship as a set of
single-responsibility, deterministic checks that decrease code
entropy over the long life of a codebase.

## Goals

- **Deterministic.** Every check runs against the AST produced by
  `swift-syntax`, not regex over text. Escape sequences, raw strings,
  multi-line strings, interpolations, and comments are all handled
  correctly by the parser.
- **Composable.** Rules are small and single-responsibility. A project
  selects which rules to enable per target. Rule parameters and edge-case
  handling are baked into the rules themselves; there are no per-project
  parameter overrides and no per-file exemptions.
- **Auditable.** Every rule has a plain-language specification under
  `Rules/Generic/` or `Rules/Swift/` keyed by a stable ID. The Swift
  implementation lives under the mirrored `Sources/Integrity/Rules/`
  layout. A reviewer reads the markdown to know what the rule is, then
  reads the matching Swift file to know how it is enforced.
- **Decreasing entropy.** Rules encode conventions that outlive any one
  feature. They exist to prevent slow drift away from established
  patterns. Each rule is timeless: it states a principle the codebase
  has committed to, and the build refuses to land code that violates
  it.

## Built-in rules

| ID   | Area    | Spec                                               | Summary                                                       |
|------|---------|----------------------------------------------------|---------------------------------------------------------------|
| G001 | Generic | `Rules/Generic/G001-file-header.md`                | Require a configured marker in every source file's header.    |
| G002 | Generic | `Rules/Generic/G002-no-mark-comment.md`            | Forbid `// MARK:` section comments.                           |
| G003 | Generic | `Rules/Generic/G003-no-todo-comment.md`            | Forbid `TODO` / `FIXME` / `XXX` / `HACK` comments.            |
| G004 | Generic | `Rules/Generic/G004-no-ai-attribution.md`          | Forbid AI-attribution phrases in source.                      |
| G005 | Generic | `Rules/Generic/G005-trailing-newline.md`           | Require every source file to end with exactly one trailing newline. |
| G006 | Generic | `Rules/Generic/G006-one-top-level-public-type-per-file.md` | One top-level public type per file.           |
| S001 | Swift   | `Rules/Swift/S001-banned-abbreviations.md`         | Forbid configured banned identifier abbreviations.            |
| S002 | Swift   | `Rules/Swift/S002-no-optionals.md`                 | Forbid Optional types; `weak var` exempt by language.         |
| S003 | Swift   | `Rules/Swift/S003-no-async-suffix.md`              | Forbid `Async` suffix on functions declared `async`.          |
| S004 | Swift   | `Rules/Swift/S004-no-impl-suffix-on-public-type.md`| Forbid `Impl` suffix on public types.                         |
| S006 | Swift   | `Rules/Swift/S006-server-side-only-imports.md`     | Forbid imports of UIKit / SwiftUI / AppKit on a server target.|
| S007 | Swift   | `Rules/Swift/S007-no-force-unwrap.md`              | Forbid `!` force-unwrap, `try!`, `as!`.                       |
| S008 | Swift   | `Rules/Swift/S008-no-singleton.md`                 | Forbid static singleton-style properties.                     |
| S009 | Swift   | `Rules/Swift/S009-no-empty-catch.md`               | Forbid empty catch blocks.                                    |
| S010 | Swift   | `Rules/Swift/S010-require-typed-throws-on-public.md` | Require typed throws on every public/open throwing function. |
| S011 | Swift   | `Rules/Swift/S011-max-cyclomatic-complexity.md`    | Forbid functions whose cyclomatic complexity exceeds the configured maximum. |

The full rule catalogue is also exposed in code:

```swift
import Integrity

for rule in BuiltInRules.catalogue {
    print("[\(rule.id)] \(rule.area): \(rule.summary)")
}
```

## Quickstart for a third-party Swift project

### 1. Depend on the package

```swift
// Package.swift of MyProject
let package = Package(
    name: "MyProject",
    dependencies: [
        .package(url: "https://github.com/swift-dx/swift-integrity", from: "0.1.0"),
        // ...
    ],
    targets: [
        .target(
            name: "MyLibrary",
            plugins: [
                .plugin(name: "IntegrityBuildPlugin", package: "swift-integrity"),
            ]
        ),
    ]
)
```

The plugin runs during `swift build` of `MyLibrary`. Plugin code is
NOT linked into `MyLibrary` — it is build-time only.

If your library is consumed by downstream packages and you do not
want the plugin to appear in their dependency graph, gate the plugin
attachment on an environment variable in your `Package.swift`. Read
`SWIFTDX_INTEGRITY` (or any name you choose) in `Package.swift` and
only declare the dependency and attach the plugin when the variable
is set. Contributors export the variable in their shell rc; consumers
do not, and so see no Integrity entry in their `Package.resolved`.

### 2. Add `integrity.json` at the package root

```json
{
  "targets": {
    "default": [
      "G001", "G002", "G003", "G004", "G005", "G006",
      "S001", "S002", "S003", "S004", "S006",
      "S007", "S008", "S009", "S010", "S011"
    ],
    "MyLibrary": "default",
    "MyLibraryTests": "default"
  }
}
```

That's the entire schema. The consumer's config declares only **which
rules apply to which target**. Rule definitions, default parameters,
and detection logic all live inside the Integrity package itself.
There are no `type` discriminators, no parameter overrides, and no
exemptions — by design.

### 3. Build

```bash
swift build
```

Violations appear as compiler-style errors and fail the build.

### Manual invocation

```bash
swift run --package-path Tooling/Integrity IntegrityRunner \
    --path Sources/MyLibrary \
    --config integrity.json \
    --target MyLibrary
```

## Configuration

### Per-target rule selection

`targets` is the only top-level key. It is a dictionary keyed by
SwiftPM target name (matching the name the build plugin passes when
it invokes the runner). Each value is either:

- **An array of rule IDs** — the explicit list of rules to enable for
  this target.
- **A string** — the name of another target whose rule list to inherit.
  `"default"` is the conventional name for the baseline list.

If a target is not present in the dictionary, the runner falls back to
the `default` entry.

### Why no overrides or exemptions

Built-in rules ship opinionated defaults — the SPDX marker for G001,
the canonical banned-abbreviation list for S001, `max: 3` for S011.
Projects do not tune these via config. A project that wants different
behaviour writes its own rule type (see "Writing a custom rule" below)
under a new ID, registers it alongside the built-ins, and references
that new ID in its target list. Exemptions are not a concept — each
rule either passes or it does not, and the rule's own logic must
recognise its legitimate edge cases (e.g. S002 NoOptionals skips
`weak var` declarations because Swift requires Optional storage there).

## Composing rule sets in code

```swift
import Integrity

let rules: [any IntegrityRule] = BuiltInRules.all + [MyCustomRule()]

let engine = RuleEngine(rules: rules)
let result = try engine.run(against: "Sources/")
ConsoleReporter().report(result)
exit(result.hasErrors ? 1 : 0)
```

`BuiltInRules.all` returns every built-in rule pre-configured with its
canonical defaults. `BuiltInRules.catalogue` exposes each rule's
metadata (id, name, area, summary, path to spec) for documentation
generation or rule discovery.

## Writing a custom rule

Conform to `IntegrityRule`:

```swift
import Integrity
import SwiftSyntax

public struct NoEmptyCatchRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoEmptyCatch"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid empty catch blocks; if you catch, you handle."

    public init(ruleID: String = "X001") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = EmptyCatchVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { position in
            Violation(
                file: file.path,
                line: file.lineNumber(of: position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "empty catch block",
                severity: .error
            )
        }
    }
}

private final class EmptyCatchVisitor: SyntaxVisitor {

    var findings: [AbsolutePosition] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        if node.body.statements.isEmpty {
            findings.append(node.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }
}
```

For line-based rules that do not need an AST, use `file.lines` and a
regular expression on each line — see `Rules/Generic/` for examples.

## How it works

- **Build plugin** (`IntegrityBuildPlugin`) registers a pre-compile
  build step on each target it is attached to. The step invokes the
  bundled `IntegrityRunner` executable with `--path` (the target's
  source directory), `--config` (the host package's `integrity.json`),
  `--target` (the SwiftPM target name), and a `--stamp-file` path
  SwiftPM uses to track invalidation. The runner reads the config,
  resolves the rule list for the target, scans the source files,
  prints violations, and exits non-zero on failure. SwiftPM treats
  non-zero exit as a build error.
- **Command plugin** (`IntegrityCommandPlugin`) supports manual
  invocation via `swift package integrity-check`. It scans the host
  package's full source tree against the `default` target rule list
  unless given other arguments.
- **Library** (`Integrity`) is the public API. `import Integrity` in
  your own executable to compose custom rule pipelines or implement
  new `IntegrityRule` types.

## Why a plugin

SwiftPM build plugins are the right mechanism because they:

- Run during compilation, not at runtime.
- Are NOT compiled into the host package's binary output.
- Surface errors through SwiftPM's normal error reporting.
- Can be enabled per-target.
- Have full access to a target's source files via the plugin context.

## License

Apache 2.0.
