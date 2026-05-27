# S009 — No Empty Catch

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

If you catch, you handle. An empty `catch { }` block visually claims
to handle the failure but in fact discards it. The error has been
caught, the stack frame is gone, no log line was emitted, no fallback
path was taken. The next time the same failure occurs in production,
the only signal is a wrong answer or missing side effect, far from
where the error originated.

Empty catch is the highest-entropy pattern in error handling: it
moves a known failure point into the "things that silently go wrong"
category, where it costs orders of magnitude more to diagnose.

Policy: every catch must do at least one of the following:

1. Throw a translated error.
2. Log the error.
3. Return a typed fallback value.
4. Update state in a way that observably reflects the failure.

If none of those apply, the surrounding code does not actually need
the `do/catch`. Remove the `do/catch` and let the error propagate.

## Rule

A Swift source file fails this rule when a `catch` clause has an
empty body.

An "empty body" is a `CodeBlockSyntax` whose `statements` list
contains zero elements. Whitespace and comments inside the braces do
not count as statements.

```swift
// FAIL: body has zero statements.
do {
    try work()
} catch {
}

// FAIL: same, even with whitespace.
do {
    try work()
} catch let error {
    
}

// OK: body has at least one statement.
do {
    try work()
} catch {
    logger.error("work failed: \(error)")
}
```

## What it does NOT check

- **Catch clauses that re-throw without any other statement** — e.g.
  `catch { throw error }`. That is a single-statement body and passes
  the rule.
- **`try?` expressions.** They discard the error but the discarding
  is explicit at the call site, not hidden in a structurally empty
  catch. A separate rule could address `try?` if a project's policy
  requires it.
- **Trailing comments inside otherwise-empty bodies.** Comments are
  not statements; the body remains empty as far as the rule is
  concerned.

## Rationale

Every error path is a piece of architectural information: this
operation can fail in this specific way. Empty catch destroys that
information at exactly the point a future engineer (or a future
self) needs it. The cost of writing a one-line `log` or `throw` at
the catch site is bounded; the cost of debugging a silently-swallowed
production failure is not.
