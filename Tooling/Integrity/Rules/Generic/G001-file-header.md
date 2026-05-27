# G001 — File Header

**Area:** Generic
**Status:** Enforced
**Severity:** Error

## Intent

Every source file in a project should begin with a standardised
license / copyright header. The header is read by compliance auditors
at downstream consumers; missing or mismatched headers block release.

## Rule

A file under scan must contain the configured marker substring.

The marker is configured per-project via the rule's `marker` field.
The marker should be a stable phrase guaranteed to appear in every
properly-headed file, regardless of year or author. Suggested form:

```
This source file is part of the <Project> open source project
```

Files that do not contain the configured marker phrase, anywhere in
the file, fail the rule.

## What it does NOT check

- Year ranges in the copyright line.
- Author attribution.
- Surrounding banner formatting.

Those belong to file-format style enforced separately by project
scripts and CI. This rule is the minimum invariant: "this file claims
the configured project's provenance."

## Rationale

Open-source license correctness. Every shipped file states what
project owns it and under what license it is distributed. The marker
phrase is the deterministic signal that the header is present.
