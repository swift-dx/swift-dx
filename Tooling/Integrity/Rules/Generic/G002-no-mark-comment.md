# G002 — No `// MARK:` Comments

**Area:** Generic
**Status:** Enforced
**Severity:** Error

## Intent

`// MARK:` comments are section dividers used to break a long file
into visually-grouped regions. A file with multiple section dividers
is a file that should be split into multiple files along the same
dividing lines. A class or type with internal sections suggests
multiple responsibilities; extract them.

## Rule

Any line in a source file matching the regular expression

```
^\s*//\s*MARK:
```

is a violation.

## What it does NOT check

- `// MARK: -` is identical to `// MARK:` for the purposes of this rule.
- DocC headings (`/// # Section`) are not flagged. DocC is a different
  mechanism with a separate purpose (API documentation, not file
  navigation).

## Rationale

Single Responsibility Principle. A file containing more than one logical
section is a file containing more than one responsibility. Split it.
Names of the new files become navigable by file listing rather than
in-file `MARK:` jumping.
