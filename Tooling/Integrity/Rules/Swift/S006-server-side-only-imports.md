# S006 — Server-Side Only Imports

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Server-side Swift projects target Linux as a first-class platform.
UI frameworks (`UIKit`, `SwiftUI`, `AppKit`) are Apple-platform-only
and do not exist on Linux; importing them breaks the Linux build and
signals a misunderstanding of the library's role.

## Rule

A Swift source file fails this rule when it contains any of the
following `import` declarations:

- `import UIKit`
- `import SwiftUI`
- `import AppKit`
- `import Cocoa`
- `import WatchKit`
- `import CarPlay`

The check looks at `ImportDecl` AST nodes; whitespace and module-path
attributes are normalised.

## What it does NOT check

- Conditional imports under `#if canImport(...)`. Those are flagged the
  same as unconditional imports today, because the only reason to
  import a UI framework from a server library is to do something on
  Apple platforms that has no Linux equivalent, which is itself a
  smell. If a documented carve-out becomes necessary later, the rule
  can be extended to honor `#if !os(Linux)` guards.

- Third-party UI frameworks (e.g. some custom `MyUIKit` from a private
  repo). The rule targets the specific platform frameworks that are
  load-bearing for Linux compilation.

## Rationale

Targets must compile on Linux. A failing Linux build means the change
is wrong, regardless of how cleanly it compiles on macOS.
