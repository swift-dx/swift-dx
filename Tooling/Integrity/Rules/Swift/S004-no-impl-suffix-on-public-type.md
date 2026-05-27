# S004 — No `Impl` Suffix on Public Types

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

The `Impl` suffix is a Java-ism that leaks implementation choice into
the public surface. A public type called `FooImpl` tells consumers
"this is the implementation," which implies an interface (`Foo`) they
should be coding against instead. Policy: if you want consumers to
code against an interface, give them the interface as the only public
symbol and keep the concrete type internal.

## Rule

A Swift source file fails this rule when any of the following type
declarations:

- `class`
- `struct`
- `enum`
- `actor`

is declared `public` (or `open`) AND its name ends in `Impl`.

## What it does NOT check

- Internal types ending in `Impl`. The allowed use of the `Impl`
  suffix is precisely: an internal concrete type that shares the
  natural name with a public protocol it implements
  (e.g. `internal final class FooImpl: Foo` where `Foo` is the public
  protocol). This rule does NOT flag those; it targets only public
  visibility.

- Types ending in `Impl` that are not class/struct/enum/actor (e.g.
  typealiases, protocol names). The architectural problem the rule
  guards against is "consumers see a concrete `Impl` type"; those
  forms do not create that problem.

## Rationale

Public surface is the protocol or value type consumers code against.
Implementation choice stays inside the library.
