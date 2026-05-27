# S002 — No Optional Types

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Optionals model "value is sometimes absent." Used widely in API design,
they push the disambiguation burden to every call site and hide domain
semantics behind `nil`. Policy is absolute: no optionals in
source code.

Replacements:

- Typed enums per permutation, where each case carries only the data
  relevant to that combination.
- Two methods instead of one with an optional parameter (`register` /
  `attach`, not one method with optional id).
- Throw a typed error at the boundary when input is invalid.
- Empty collections instead of nullable collections.
- Default initial values instead of "not yet set" optionals.

## Rule

A Swift source file fails this rule when any of the following AST
patterns appear:

1. **Optional type sugar** — `T?` written as the type in a
   declaration, parameter, return value, or property:
   - `var x: Int?`
   - `let y: String?`
   - `func foo(arg: Int?)`
   - `func foo() -> String?`
   - `case bar(value: Int?)`

2. **Optional generic** — `Optional<T>` written as the type:
   - `var x: Optional<Int>`
   - `func foo() -> Optional<String>`

3. **Implicitly-unwrapped optional** — `T!` written as the type:
   - `var x: Int!`
   - `func foo() -> String!`

Local variables inside function bodies are also in scope; optionals
hide design problems regardless of scope.

## What it does NOT check

- `try?`, `as?`, `is`, optional chaining (`foo?.bar`) — these are
  expression-level uses, not type declarations. Banning them would
  prevent interaction with Foundation / NIO / Crypto APIs that themselves
  return optionals. The cost is paid at the boundary; the optional is
  unwrapped before it propagates inward.
- Conditional binding (`if let x = ...`) — same reasoning.
- Pattern matching against `nil` (`switch x { case .none: ... }`) —
  same reasoning.
- `weak var <name>: <Type>?` declarations. The `weak` keyword in Swift
  requires the storage to be Optional because the reference can become
  `nil` when the referenced object is deallocated. This is a language
  constraint, not a design choice; no refactor eliminates it. The
  exemption applies only to declarations carrying the `weak` modifier.

The boundary-crossing exception is documented; reviewers verify that
optionals from third-party APIs are converted to typed enums or
throwing flows immediately, never stored as fields.

## Rationale

If a value is "sometimes absent", model the absence as a named state.
Optionals push the disambiguation work to every call site. Typed
enums move it to the type system, where the compiler exhaustively
checks every consumer.
