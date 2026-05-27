# G004 — No AI Attribution in Source

**Area:** Generic
**Status:** Enforced
**Severity:** Error

## Intent

AI attribution lines do not belong in source files, commit messages,
or PR bodies. AI assistance is a tool, not a co-author. External
compliance reviewers should not see "Co-Authored-By: Claude" in the
git log of a library their organisation depends on.

This rule covers source files. Commit-message and PR-body enforcement
is a separate concern outside the SwiftPM build flow.

## Rule

A file fails this rule when any line contains any of the following
substrings (case-insensitive for the human phrases, case-sensitive for
brand names):

- `Co-Authored-By: Claude`
- `Co-Authored-By: Codex`
- `Generated with Claude Code`
- `Generated with Codex`
- `🤖` (robot emoji)
- `Anthropic` (case-sensitive)
- `OpenAI` (case-sensitive)

The check is plain substring search across the line. String literals,
URLs, comments, and code are all in scope. Removing the substring is
the only fix.

## What it does NOT check

- Words like `claude` or `gpt` used as part of legitimate identifiers
  (e.g. `claudeAPIClient` for a project building a client to the Claude
  API). The rule targets specific attribution phrases, not all mentions
  of AI products.

## Rationale

Public auditability. Enterprise consumers reviewing the source of a
dependency they pin should see only human-written-and-reviewed claims of
authorship. AI tooling that produced any portion of a change is
expected to leave no trace beyond the diff and the human's commit
message.
