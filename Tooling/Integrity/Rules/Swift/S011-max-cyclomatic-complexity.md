# S011 — Maximum Cyclomatic Complexity

**Area:** Swift
**Status:** Enforced
**Severity:** Error

## Intent

Cyclomatic complexity measures the number of linearly independent
execution paths through a function. Each branch (`if`, `for`,
`switch case`, `catch`, `&&`, `||`, ternary) adds one path. A high
number means a function does too many things: many decisions, many
states, many ways to be wrong. The cost of understanding the function
grows super-linearly with the number of paths.

Policy: any function whose complexity exceeds the configured maximum
fails this rule. The default maximum is 3.

A function above the threshold is a signal to extract: pull a clause
into a guard at the boundary, factor a switch into a separate
dispatch helper, hoist a complex boolean expression into a named
predicate. Each extraction lowers the parent's complexity and gives
the extracted piece a name a reader can reason about.

## Rule

A function or initializer fails this rule when its computed
cyclomatic complexity exceeds the configured maximum (default 3).

The complexity counter starts at 1 (the base execution path) and
adds 1 for each of:

- `if` statement (including `else if`)
- `guard` statement
- `for` loop
- `while` loop
- `repeat-while` loop
- `switch` case (each `case`; `default` does not add)
- `catch` clause (each `catch`; the structural presence of `do/catch`
  itself does not add until a `catch` clause exists)
- Ternary `?:` expression
- `&&` operator
- `||` operator

The walk does NOT descend into:

- Nested function declarations (each gets its own complexity score).
- Closure expressions (each evaluated separately when the rule is
  applied to it, if applicable).

## What it does NOT check

- **Type-level complexity** (number of properties, number of methods).
  Other rules address Single Responsibility at the type and file
  level.
- **Cognitive complexity** — a different metric that weights nesting
  depth. The cyclomatic count is structurally simpler and
  deterministic; cognitive metrics require additional weighting
  choices.
- **Computed properties** and **subscripts**. They can carry complex
  bodies but are not visited today; extend the rule if the consuming
  project requires it.

## Configuration

```json
"S011": {
  "type": "max-cyclomatic-complexity",
  "max": 3
}
```

The `max` field is optional; default is 3.

## Rationale

A function with complexity ≤ 3 has at most two decision points. Two
decisions is the threshold at which a reader can hold the entire
function state in their head while reading it linearly. Above three
decisions, readers begin guessing about state, and guesses become
defects.

Granularity is the cure for complexity. Each extraction names a
piece of the original function's intent, and the named piece becomes
testable and reusable. The cumulative function structure flattens
out into a graph of small, named, low-complexity units — exactly the
shape a long-lived codebase can maintain.
