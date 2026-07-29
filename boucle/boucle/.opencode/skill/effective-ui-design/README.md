# Effective UI Design

You've seen it happen: your AI agent generates a form with thin gray text, buttons that all look the same, and spacing that feels random. You fix it, move on, and next time it happens again.

This [Agent Skill](https://agentskills.io/) stops that cycle. Install it once, and every UI task follows professional design guidelines automatically. No reminding, no repeating yourself.

Works with Claude Code, Cursor, GitHub Copilot, Windsurf, Gemini CLI, and any other agent that supports the [Agent Skills format](https://agentskills.io/specification).

## How this differs from the frontend-design skill

Anthropic's [frontend-design](https://skills.sh/anthropics/skills/frontend-design) skill handles creative direction: picking a bold aesthetic, choosing distinctive fonts, avoiding generic "AI look" output. It's good at that.

It doesn't touch the technical layer. No contrast ratios, no spacing system, no form patterns, no accessibility rules, no SEO. A visually striking page that fails WCAG or ships without meta tags is still a problem.

This skill covers the engineering side. Concrete values, not creative direction:

| This skill | frontend-design |
|---|---|
| WCAG 2.1 AA contrast (4.5:1 text, 3:1 UI) | No contrast requirements |
| OKLCH palettes, `light-dark()`, relative color syntax | "Cohesive palette" (no method specified) |
| 8pt spacing grid, container queries, subgrid | "Generous negative space" (no system) |
| Fluid typography with `clamp()`, type scale, vertical rhythm | "Choose distinctive fonts" (no sizing rules) |
| Form validation, `:user-valid`/`:user-invalid`, field sizing | Not covered |
| Button hierarchy, target sizes, destructive action patterns | Not covered |
| Dark mode, reduced motion, screen reader support | Not covered |
| SEO meta tags, JSON-LD, Core Web Vitals | Not covered |

They work together. Use frontend-design for the mood. Use this one to make sure the result actually works for every user.

## The problem

AI agents have no design opinion. Without guidance they default to:

- Text that fails WCAG contrast requirements
- Buttons with no visual hierarchy (everything looks equally important)
- Forms with no validation feedback or sensible field sizing
- Arbitrary spacing with no system behind it
- No consideration for dark mode, reduced motion, or screen readers

You can fix this per-prompt, but that gets old after the third time.

## What this changes

The skill loads 10 reference files covering the decisions you'd otherwise make by hand:

| Topic | What it handles |
|-------|----------------|
| [Fundamentals](references/01-fundamentals.md) | Interaction cost, cognitive load, affordance, animation, reduced motion, semantic HTML |
| [Less is more](references/02-less-is-more.md) | Progressive disclosure, mobile-first, when to remove rather than add |
| [Colour](references/03-colour.md) | OKLCH palettes, contrast ratios (WCAG 2.1 AA), dark mode, `light-dark()`, relative color syntax |
| [Layout & spacing](references/04-layout-spacing.md) | 8pt grid, container queries, subgrid, responsive images, safe areas, intrinsic layouts |
| [Typography](references/05-typography.md) | Type scale, fluid sizing with `clamp()`, OpenType features, vertical rhythm |
| [Web fonts](references/05b-webfonts.md) | `font-display`, preloading, variable fonts, fallback matching |
| [Copywriting](references/06-copywriting.md) | Concise text, sentence case, error messages, empty states |
| [Buttons](references/07-buttons.md) | Primary/secondary/tertiary weights, destructive actions, undo over confirmation |
| [Forms](references/08-forms.md) | Single column layout, validation with `:user-valid`/`:user-invalid`, dropdowns vs alternatives |
| [SEO](references/09-seo.md) | Meta tags, structured data (JSON-LD), Core Web Vitals, internal linking |

Built on 20+ years of shipping web interfaces. Updated for modern CSS (Baseline 2023-2025) and current accessibility standards.

## What it doesn't do

This isn't a component library or a CSS framework. It doesn't pick your aesthetic direction or choose fonts for you. It's the technical layer underneath: the spacing, contrast, accessibility, and patterns that need to be right regardless of how the interface looks.

## Install

```bash
npx skills add sebastian-software/effective-ui-design-skill
```

Or manually via git:

```bash
git clone https://github.com/sebastian-software/effective-ui-design-skill.git ~/.claude/skills/effective-ui-design
```

The skill activates automatically whenever the agent works on frontend tasks. Nothing to configure.

## License

MIT — see [LICENSE](LICENSE) for details.

Copyright (c) 2026 [Sebastian Software GmbH](https://sebastian-software.de), Mainz, Germany.
