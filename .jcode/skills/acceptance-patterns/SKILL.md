---
name: acceptance-patterns
description: Testing patterns (Arrange-Act-Assert, Playwright E2E, React Testing Library) and WCAG 2.1 AA accessibility checklist. Load when reviewing test coverage, writing acceptance tests, or auditing accessibility.
---

# Acceptance Patterns

Two reference documents for acceptance-test authoring and accessibility auditing.

## References

- **`references/testing-patterns.md`** — JavaScript/TypeScript testing patterns: Arrange-Act-Assert structure, naming conventions, common assertions, mock discipline, React/component testing, API/integration testing, Playwright E2E, and test anti-patterns. Stack-agnostic principles with JS/TS-specific syntax.
- **`references/accessibility-checklist.md`** — WCAG 2.1 AA compliance checklist: keyboard navigation, focus management, ARIA patterns, live regions, testing tools (axe-core, pa11y, Lighthouse), and common anti-patterns.

## When to load

- Writing or reviewing acceptance tests for a feature
- Auditing a deployed page for WCAG 2.1 AA compliance
- Reviewing test coverage gaps (unit → integration → E2E ladder)
- Verifying Playwright locator discipline (getByRole/getByLabel over CSS selectors)

## Output contract

Produce a findings report with:
1. **Test coverage assessment** — which acceptance criteria have tests, which don't, gaps in the unit→integration→E2E ladder
2. **Accessibility findings** — WCAG 2.1 AA violations with severity (critical/serious/moderate), element selector, and remediation
3. **Verdict** — `PASS` | `FAIL (N critical, M serious)` | `UNPROVEN (insufficient test coverage)`