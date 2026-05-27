# Security Policy

SwiftDX is open-source software distributed under the Apache License,
Version 2.0. The software is provided **"AS IS"**, without warranty of any
kind, express or implied, including the implied warranties of
merchantability, fitness for a particular purpose, and noninfringement.
The SwiftDX Contributors are not liable for any claim, damages, or other
liability — including liabilities arising from security incidents —
resulting from the use of this software. The full disclaimer of warranties
and limitation of liability is set out in the LICENSE file and prevails
over any text in this document.

Consumers integrating SwiftDX into a production system are responsible for
their own security assessment, including code review, dependency review,
penetration testing where appropriate, and operational hardening sized to
their threat model. SwiftDX makes no representation that the software is
fit for any particular use, and adopters must perform their own due
diligence before deployment.

This document describes how the project handles security findings reported
by the community. It is **not** a service-level agreement and does not
create any contractual obligation.

## Reporting a Vulnerability

Report security issues privately to **security@swiftdx.dev**.

Do not open a public GitHub issue, pull request, or discussion for
security concerns. Public disclosure before a fix is available exposes
every downstream consumer to the same defect.

## What to Include

A useful report contains:

- The affected library and version (release tag or commit SHA).
- A description of the vulnerability and the impact you observed.
- Reproduction steps or a minimal proof-of-concept.
- Relevant logs, stack traces, or wire captures.
- Suggested mitigations, if you have any.

## Disclosure Process

Reports are triaged privately. The maintainers work with the reporter to
confirm the finding, coordinate a fix, and agree on a disclosure timeline.
Issues remain embargoed until a patched release is available. CVEs are
filed for vulnerabilities that warrant them and referenced in release
notes. Reporters who wish to be credited are credited in the release
notes and any CVE entry.

As an open-source project staffed by volunteers, SwiftDX commits to a
best-effort response and to shipping security patches as part of the
regular release cadence. Fixed response times are **not** guaranteed.

## Scope

All `DX*` library targets published from the swift-dx monorepo are in
scope. Code under `Tooling/`, `Examples/`, and `Benchmarks/` is out of
scope unless the same defect also affects a shipped library.

## Supported Versions

SwiftDX is pre-1.0. Only the latest tagged release receives security
fixes. Once 1.0 ships, the supported-versions policy will be revised
here.

## Limitation of Liability

Nothing in this policy modifies, replaces, or limits the disclaimer of
warranties and limitation of liability set out in the LICENSE file. Use
of SwiftDX is **at your own risk**. Consumers must perform their own
security assessment before deploying any SwiftDX library into production
systems and accept full responsibility for the consequences of doing so.
