# G006 — One Top-Level Public Type Per File

**Area:** Generic
**Status:** Enforced
**Severity:** Error

## Intent

Single Responsibility at the file boundary. A file owns one publicly-
visible type. The file's name and location announce what that type
is; opening the file gives a reader the entire public surface of that
unit without scrolling past other public concepts.

Files with multiple top-level public types accumulate accidental
coupling. Two types in the same file evolve together not because
they should, but because they live together. Renaming one becomes a
multi-symbol diff; testing one in isolation requires importing the
other; documentation must explain the relationship that the
filesystem implied.

Policy: every source file declares at most one top-level public type.
Internal types, file-private helpers, and extensions on the primary
type are unrestricted.

## Rule

A file fails this rule when more than one of its top-level
declarations is one of the following and carries a `public` or
`open` modifier:

- `class`
- `struct`
- `enum`
- `actor`
- `protocol`
- `typealias`

The first such declaration is treated as the file's primary public
type and accepted. Every subsequent matching declaration is flagged.

## What it does NOT check

- **Internal or `package` types** at the top level. The rule's scope
  is the publicly-visible surface; internal helpers do not pollute
  consumer dependency graphs and can coexist freely.
- **Extension declarations.** `extension Foo: Bar { ... }` does not
  introduce a new top-level type. A file is free to contain the
  primary type plus any number of extensions on it.
- **Nested types** declared inside a primary type. `struct Outer { public struct Inner { ... } }`
  declares `Inner` inside `Outer`'s scope, not at the file's top
  level.
- **Top-level `public let` / `public var` / `public func` declarations.**
  Those are top-level values, not types. A separate rule could
  address them if the consuming project requires it.

## Rationale

The filesystem is the cheapest available index. When the path
`Sources/MyLibrary/Subjects/Subject.swift` exists, a reader knows
that opening it is sufficient to learn everything about the public
`Subject` type. Adding a second public type to the same file breaks
that invariant: the reader now has to keep two concepts in mind, and
neither file name nor path narrows their search.
