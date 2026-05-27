# G003 — No `TODO` / `FIXME` / `XXX` / `HACK` Comments

**Area:** Generic
**Status:** Enforced
**Severity:** Error

## Intent

Temporary markers in source code outlive their context. They
accumulate and become defects. Policy: defer work via tracked issues,
not in-source markers.

## Rule

Any line in a source file matching the regular expression

```
//\s*(TODO|FIXME|XXX|HACK)\b
```

is a violation.

## What it does NOT check

- Block comments (`/* TODO: ... */`) are not currently flagged. They
  are rare in Swift code and not worth the parser complexity.
- Identifiers named `todoCount`, `fixmeBuffer`, etc. are not flagged.
  The pattern requires the marker to appear inside a `//` comment.

## Rationale

Any deferred work must have an owner and a removal trigger. Bare
in-source markers carry neither. Use the issue tracker; reference
issue IDs in commit messages, not in code comments.
