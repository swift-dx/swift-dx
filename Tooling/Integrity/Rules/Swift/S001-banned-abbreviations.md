# S001 — Banned Abbreviations

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Code reads orders of magnitude more often than it is written. Saving
typist keystrokes by abbreviating names costs every future reader a
parse step. Policy: write the full word.

## Rule

A Swift source file fails this rule when an identifier whose name is
exactly one of the configured banned tokens appears in the code
outside of comments and string literals.

The banned list is configured per-project via the rule's `banned`
field. A common starter list for general-purpose Swift codebases:

```
cfg, msg, idx, seq, ptr, info, opts, params, args,
desc, temp, tmp, auth, addr, req, resp, ctx, mgr, Manager
```

Match is case-sensitive and word-boundary aware: `processInfo`,
`configValue`, `requestID` do NOT match (the banned token is not the
full identifier). `let cfg = ...`, `func handle(msg:)`, `Manager()` DO
match.

String-literal contents and comments are excluded from the scan by
AST parsing (`StringLiteralExpr`, comment trivia). Identifiers inside
`\"`, raw strings (`#"..."#`), and multi-line strings (`"""..."""`)
are correctly ignored.

## What it does NOT check

- Capitalised variants. `Cfg`, `Msg`, `Idx` are not in the default ban
  list. If the same word appears in `PascalCase` and is undesirable,
  add the cased variant to the configuration.
- Domain-of-art short forms allowed by the consuming project's style
  guide (e.g. `ack`, `nonce`, `pub` / `sub` as literal protocol verbs).
  These are NOT in the default ban list.
- Industry-standard acronyms in their domain: `URL`, `HTTP`, `JWT`,
  `JSON`, `XML`, `ID`, `UUID`, `RFC`, `RTT`, `TCP`, `UDP`, `TLS`,
  `SSL`, `gRPC`, `OAuth`, `OIDC`. None of these match the banned
  tokens directly so no carve-out is needed.

## Rationale

A new contributor (human or AI) reading code with `cfg`, `mgr`, `ctx`,
`tmp` spends mental cycles disambiguating each abbreviation. The
two-second cost on the typist side is paid back hundreds of times by
the reader. Domain meaning carried by full words is auditable; meaning
hidden inside abbreviations is not.

## Configuration

The `banned` list is the only configuration. The `message` field
provides the violation text. See the consuming project's
`integrity.json` for the live configuration.
