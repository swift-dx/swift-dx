# S003 — No `Async` Suffix on `async` Functions

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

The `async` keyword is part of the function signature. Adding `Async`
to the function name duplicates the semantic and adds visual noise to
every call site.

## Rule

A Swift source file fails this rule when a function declaration's name
ends in the four characters `Async` AND the function is declared
`async` in its effects clause.

Examples that fail:

```swift
func fetchAsync() async throws -> Data
func loadAsync() async
```

Fix: rename to drop `Async`.

```swift
func fetch() async throws -> Data
func load() async
```

## What it does NOT check

- Non-async functions whose name happens to end in `Async`. A
  function named `publishBatchAsync` that is NOT declared `async` (it
  returns a handle / future, completion is asynchronous but the call
  returns synchronously) is allowed. The Async suffix in that case is
  semantic, not redundant.

  ```swift
  // OK: returns a handle, completion is async but the call is sync.
  func publishBatch(subject: Subject, payloads: [[UInt8]]) -> PublishBatchHandle
  ```

  The rule only forbids the redundant `Async` suffix on functions
  that are already `async`. It does not enforce a particular sync /
  async pair naming convention.

- Type names ending in `Async` (`AsyncStream`, `AsyncSequence`,
  `AsyncContext`). The rule targets function declarations only.

## Rationale

The `async` keyword already conveys the asynchronous nature; adding
`Async` to the name is duplication.
