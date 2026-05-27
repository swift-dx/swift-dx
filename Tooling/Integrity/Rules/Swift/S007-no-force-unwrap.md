# S007 — No Force Unwrap

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Force-unwrap (`!`) turns the absence of a value into an unrecoverable
runtime crash. The expression carries no error information, no
diagnostic context, and no recovery path. In a long-lived codebase,
every force-unwrap is a hidden land mine waiting on a future input
the author did not consider.

Policy: explicit handling at every optional boundary. `guard let`,
`if let`, `switch case let`, `?? defaultValue`, or `try`/`throw`. The
codebase pays a one-time clarity cost at the boundary in exchange for
eliminating an entire class of crashes.

This rule pairs with the No-Optionals rule (S002). Even when the
project's own code declares no Optional types, third-party APIs do.
Force-unwrap is the loophole that lets a Optional from `Dictionary[key]`
or `URL(string:)` propagate through the codebase unchecked. This rule
closes the loophole.

## Rule

A Swift source file fails this rule when any of the following AST
patterns appear:

1. **Postfix force-unwrap** on an expression: `expression!`
   - `let value = optional!`
   - `someFunction()!`
   - `dictionary[key]!`

2. **`try!`** — force-try, which converts a thrown error into a crash.
   - `let value = try! decoder.decode(...)`

3. **`as!`** — forced down-cast, which crashes on type mismatch.
   - `let value = thing as! String`

## What it does NOT check

- **Implicitly-unwrapped optional type declarations** (`var x: Int!`)
  — those are caught by S002 No Optionals at the declaration site.
- **`try?`, `as?`** — these produce an Optional, which is handled
  safely at the consumer (guard / if let / nil-coalesce). The rule
  does not forbid them because the absence is explicit and the
  control flow is forced to handle it.
- **`!` as a logical-not prefix** (`!boolean`). The AST distinguishes
  the prefix logical-not from the postfix force-unwrap, and only the
  latter is flagged.

## Rationale

Each force-unwrap concentrates fragility in one source line and pushes
the failure off until runtime. Replacing it with explicit handling
moves the question "what should happen if this is absent?" to the
type system, where the compiler enforces an answer.

The cost of explicit handling is bounded (a few extra lines per
boundary). The savings compound: every replaced force-unwrap is one
fewer way the production system can crash with no useful diagnostic.
