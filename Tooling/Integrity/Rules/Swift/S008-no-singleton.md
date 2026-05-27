# S008 — No Singleton

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Singletons are hidden global state. A property like
`static let shared: Self` looks like an encapsulated owner of its
type's behaviour, but every consumer that reaches for it becomes
implicitly coupled to that one instance. Tests cannot substitute a
fake; lifecycle cannot be controlled; concurrency surfaces depend on
the singleton's internal locking, which is invisible from the call
site.

A long-lived codebase that accumulates singletons accumulates hidden
global state that resists refactoring. Each new singleton makes every
caller harder to test and every behaviour harder to override.

Policy: explicit ownership. The component that creates the instance
owns it. Consumers receive it by injection (initializer parameter,
property, environment, dependency container) so the test harness can
provide a substitute and the production lifecycle is explicit.

## Rule

A Swift source file fails this rule when a static or class-level
property declared on a type uses one of the configured singleton
property names. By default the names are:

```
shared, instance, current, default
```

Triggering examples:

```swift
public final class Logger {
    public static let shared = Logger()         // FAIL
}

public actor Cache {
    public static var current: Cache = .init()  // FAIL
}

public struct Config {
    public static let `default` = Config()      // FAIL
}
```

The check is structural: any `static` or `class` property declaration
whose binding identifier matches one of the configured names is
flagged. The check does not inspect the property's type or initial
value, so an alias like `static let shared = SomeOther()` still
trips.

## What it does NOT check

- **Instance properties** named `shared`, `instance`, etc. Only
  `static` and `class` properties qualify as singletons; instance
  properties do not.
- **Computed static properties** that return a new instance per call
  (e.g. `static var current: Self { .init() }`). They still trigger
  the rule by name. If the name carries singleton semantics, rename
  it (`makeCurrent()`, `freshInstance()`).
- **Constants of value types** that are not instances of the
  enclosing type (e.g. `static let defaultPort: Int = 4222` inside
  a `NatsEndpoint` struct). Those are constants, not singletons,
  and their name (`defaultPort`) does not match the configured list.

## Configuration

The banned property name list is configurable via the rule's
`names` field. To use a different list, configure it explicitly in
`integrity.json`:

```json
"S008": {
  "type": "no-singleton",
  "names": ["shared", "instance", "current"]
}
```

## Rationale

A singleton is two design decisions glued into one: "one instance
exists" and "every consumer reaches the same instance". The first is
sometimes correct; the second is almost always wrong. Inject the
instance instead of letting consumers reach for it globally, and the
glue dissolves.
