# DESIGN Template

> Template for a consumer-site design system file (the DESIGN.md concept). Copy this file to the consumer repo root as `DESIGN.md` (or keep your existing file, restructured along these sections) and fill in the values. **An agent reads this file before designing any UI** — it is the design equivalent of `AGENTS.md`: a single, human-readable file that tells an agent how this product is supposed to look.
>
> Derivative of [superdesign-skill/DESIGN.md](https://github.com/superdesigndev/superdesign-skill) (MIT, © Superdesign). Adapted for the boucle loop: product context, tokens, motion, components — implementable **without the codebase**.

## Rules of use (for agents)

- **Read this file FIRST** before any UI/visual work — it overrides generic design recommendations (ui-ux-pro-max, frontend-design).
- **Implementable without the codebase**: an agent (or a person) must be able to build on-brand UI from this file alone.
- **Update it in the same MR** as any visual convention change (see `worker.md` "Doc maintenance").
- Keep it **human-readable**: tables and token values, not prose walls. Explicit/imperative tone ("MUST", "NEVER", "SHOULD").

---

## 1. Product context

- **What is being built:** <one sentence>
- **Who it's for:** <target audience>
- **Core value:** <the one thing the product delivers>
- **Key user journeys:** <the 2-5 journeys that matter most>
- **Tone / personality:** <e.g. serious, playful, editorial, minimal>

## 2. Design tokens

### Colors

| Token | HEX | Usage |
| ----- | --- | ----- |
| `--surface-base` | `#000000` | Page background |
| `--surface-raised` | `#000000` | Cards, modals |
| `--text-primary` | `#000000` | Headings, body |
| `--text-secondary` | `#000000` | Muted text |
| `--accent` | `#000000` | CTAs, links, focus |
| `--border` | `#000000` | Dividers, outlines |
| `--destructive` | `#000000` | Errors, destructive actions |

Contrast rules: primary text `>= 4.5:1`, secondary `>= 3:1` in every mode. Never hardcode ad-hoc colors outside these tokens.

### Typography

- **Font family:** <e.g. Inter, system stack>
- **Scale:** <size/weight per level: display, h1-h3, body, caption>
- **Rules:** line-height, letter-spacing, tabular-nums for data, `text-balance`/`text-pretty` where relevant.

### Spacing & layout

- **Grid unit:** <e.g. 4px / 8px>
- **Scale:** <the allowed spacing values>
- **Breakpoints / base viewport:** <e.g. mobile-first, 1440px base>
- **Radius scale / shadow scale:** <allowed values>

## 3. Motion

- **Duration & easing defaults** (interaction feedback `<= 200ms`, entrance `ease-out`).
- **Allowed properties:** compositor-only (`transform`, `opacity`); NEVER layout properties (`width`, `height`, `top`, `left`).
- **Reduced motion:** respect `prefers-reduced-motion`; never animate large `blur()`/`backdrop-filter` surfaces.

## 4. Components

| Component | Pattern / variant rules | Notes |
| --------- | ----------------------- | ----- |
| Buttons | <variant table: background, text, border, radius, height> | Usage notes |
| Inputs | <height, borders, focus states> | Error placement |
| Cards / surfaces | <padding, radius, shadow> | |
| Nav / layout | <header, footer, container rules> | |
| States | <focus, hover, disabled, loading, empty, error> | Accessibility notes |

## 5. Content & tone

How is copy written on this site? Agents must mirror it, not invent a new voice.

- **Voice:** <tone, formality, "I" vs "you", first vs third person>
- **Casing & punctuation:** <sentence case? title case? Oxford comma? emoji allowed?>
- **Examples:** <2-3 short on-brand copy samples — the more specific, the better>

## 6. Iconography

- **Icon system:** <built-in icon font, inline SVGs, CDN set (e.g. lucide, heroicons), unicode glyphs>
- **Style rules:** <stroke weight, fill style, size grid, color usage>
- **Assets:** <copy logos/icons/illustrations into the consumer repo — NEVER draw your own SVGs or generate substitute images; if a set is CDN-available, link it, otherwise flag the substitution>

## 7. Visual foundations

The brand's visual motifs — answer ALL of these.

- **Backgrounds:** <solid? gradients? images? full-bleed? repeating patterns/textures?>
- **Imagery vibe:** <warm? cool? b&w? grain?>
- **Hover / press states:** <opacity? darker? lighter? shrink?>
- **Borders & shadows:** <border widths, inner/outer shadow systems, protection gradients vs capsules>
- **Transparency / blur:** <when is it used?>
- **What cards look like:** <shadow, rounding, border — the shape of a default card>

## 8. Design system persistence (optional)

If the project uses `ui-ux-pro-max` `--persist` (MASTER.md + page overrides), the generated `design-system/MASTER.md` lives alongside this charter; this charter remains the **source of truth** and the MASTER.md mirrors it for the current session's work.
