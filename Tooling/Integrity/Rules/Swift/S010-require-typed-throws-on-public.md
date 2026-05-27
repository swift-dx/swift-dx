# S010 — Require Typed Throws on Public API

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Untyped `throws` on a public API is an open contract: the function
claims it can fail, but the type of failure is undocumented. Callers
cannot exhaustively switch on a typed enum, cannot decide which errors
to map to a higher-level domain, and cannot tell whether a new error
case has been added without reading the implementation.

Typed throws closes the contract:

```swift
public func parse(_ data: Data) throws(ParseError) -> Document
```

A consumer reading the signature knows the failure surface is exactly
`ParseError`, the compiler refuses to let an unmodelled error escape
the function, and adding a new `ParseError` case is a recognised
SemVer-breaking change because exhaustive `switch` statements at the
call site stop compiling.

Policy: every public function and public initializer that declares
`throws` declares a thrown type.

## Rule

A Swift source file fails this rule when a `FunctionDeclSyntax` or
`InitializerDeclSyntax` satisfies ALL of the following:

1. Carries a `public` or `open` modifier.
2. Declares `throws` in its effect specifiers (the `throwsClause`
   exists and its `throwsSpecifier` token is the `throws` keyword).
3. The `throwsClause` has no `type` (the parenthesised typed-error
   syntax is absent).

Triggering examples:

```swift
public func parse(_ data: Data) throws -> Document             // FAIL
public init(rawValue: String) throws                           // FAIL
open class func make() throws -> Self                          // FAIL
```

Passing examples:

```swift
public func parse(_ data: Data) throws(ParseError) -> Document // OK
public init(rawValue: String) throws(ValidationError)          // OK
public func internalHelper() throws -> Int                     // OK (not public)
public func fetch() async throws(NetworkError) -> Data         // OK
```

## What it does NOT check

- **`rethrows`**. The thrown error type is, by definition, the
  caller's. Typed throws does not apply. The rule passes any
  function whose `throwsSpecifier` is `rethrows` rather than `throws`.
- **Internal, fileprivate, or private functions**. The rule scope is
  the published API surface, where consumers depend on the contract.
- **Properties with throwing accessors** (`var foo: Int { get throws { … } }`)
  and **subscript declarations**. They can also be typed; if the
  consuming project requires it, extend the rule. Today the rule
  targets only top-level function and initializer declarations.

## Rationale

A public API states two contracts: what it returns when it succeeds,
and how it fails when it does not. Half a contract is worse than
none — it tricks consumers into believing they have handled all
cases when they have not. Typed throws keeps both halves explicit
and lets the compiler enforce them.
