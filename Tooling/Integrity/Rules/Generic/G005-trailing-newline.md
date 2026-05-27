# G005 — Trailing Newline

**Area:** Generic
**Status:** Enforced
**Severity:** Error

## Intent

Every source file must end with exactly one trailing newline.

Unix tools assume text files end with `\n`. A missing trailing newline
causes `cat`, `grep`, `sed`, and most diff viewers to display the last
line jammed against the next command's prompt or the next file's first
line. Editors that add the newline on save then produce a one-byte
"phantom" diff in version control. The rule eliminates both classes
of noise.

## Rule

A file fails this rule when EITHER:

1. The file is empty (zero bytes).
2. The last byte of the file is NOT `\n`.
3. The file ends with two or more consecutive newlines.

Equivalently: the file's contents must end with exactly one `\n`.

## What it does NOT check

- Line endings inside the file (no `\r\n` vs `\n` enforcement).
- Maximum file length.
- Blank lines at the start of the file.

Those belong to other rules if needed.

## Rationale

Mechanical hygiene. Every Unix tool, every code review interface, and
every line-counting utility expects a newline at end of file. Treating
the trailing newline as mandatory rather than incidental removes a
class of cosmetic diffs and aligns the codebase with the tooling
ecosystem around it.
