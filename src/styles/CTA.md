# CTA — Charte des appels à l'action

> Charter for the two CTA (call-to-action) variants used across the site.
> Lives next to `tokens.css` so the visual vocabulary and the design tokens
> stay co-located. Every implementation MUST consume the tokens listed below
> — no ad-hoc colour, font, or radius values.

---

## Overview

The site uses **exactly two CTA variants**, each clearly distinguishable by
intent:

| Variant | Intent | Background | Clickable |
| --- | --- | --- | --- |
| **A** | clickable / internal navigation | single red block | yes |
| **B** | general / non-clickable | two stacked blocks (green + red) | no |

Both variants share the same brand-signalling posture:

- hard-edged rectangle (no border radius);
- uppercase heading face (`var(--font-heading)`);
- white text (high contrast against flag colours);
- brand colours reserved exclusively for accent / CTA moments.

---

## Tokens consumed

Both variants are built from the following tokens, all declared in
[`tokens.css`](./tokens.css):

| Token | Role |
| --- | --- |
| `--color-flag-red` | CTA fill / action colour (Variant A, Variant B lower block) |
| `--color-flag-red-deep` | hover / pressed state |
| `--color-flag-green` | title colour (Variant B upper block) |
| `--color-flag-green-deep` | hover / pressed state |
| `--color-flag-white` | text colour on flag backgrounds |
| `--font-heading` | heading face, mandatory for CTA labels |
| `--radius-sharp` | hard-edged rectangle (`0`) — new token, see below |

---

## Variant A — Clickable / internal navigation CTA

Hard-edged red rectangle acting as a single, high-contrast action target.
Used whenever the CTA actually navigates somewhere (internal page, signed
form, etc.).

**Reference:** `static/collectif/cta-creer-un-collectif.png`.

### Visual recipe

| Property | Value |
| --- | --- |
| background | `var(--color-flag-red)` |
| text colour | `var(--color-flag-white)` |
| font | `var(--font-heading)` |
| text-transform | `uppercase` |
| border-radius | `var(--radius-sharp)` |
| padding | `var(--space-m) var(--space-l)` (≥ 44×44 px hit area) |
| hover | `background: var(--color-flag-red-deep)` |

### Snippet

```html
<a class="cta cta--clickable" href="/collectif/creer">
  Je crée un collectif local
</a>
```

```css
.cta--clickable {
	display: inline-flex;
	align-items: center;
	justify-content: center;
	min-height: 44px;
	padding: var(--space-m) var(--space-l);
	background: var(--color-flag-red);
	color: var(--color-flag-white);
	font-family: var(--font-heading);
	font-weight: var(--weight-bold);
	font-size: var(--text-lg);
	text-transform: uppercase;
	letter-spacing: var(--tracking-wide);
	text-decoration: none;
	border: 0;
	border-radius: var(--radius-sharp);
	cursor: pointer;
	transition: background var(--duration-fast) var(--ease-out);
}

.cta--clickable:hover,
.cta--clickable:focus-visible {
	background: var(--color-flag-red-deep);
}

@media (prefers-reduced-motion: reduce) {
	.cta--clickable {
		transition: none;
	}
}
```

---

## Variant B — General non-clickable CTA

Two stacked solid blocks (no link, no button). The upper block carries the
short title on flag-green, the lower block carries the shorter call on
flag-red. Both use the same heading face, uppercase, white text.

### Visual recipe

| Property | Upper block (title) | Lower block (call) |
| --- | --- | --- |
| background | `var(--color-flag-green)` | `var(--color-flag-red)` |
| text colour | `var(--color-flag-white)` | `var(--color-flag-white)` |
| font | `var(--font-heading)` | `var(--font-heading)` |
| text-transform | `uppercase` | `uppercase` |
| border-radius | `var(--radius-sharp)` | `var(--radius-sharp)` |
| padding | `var(--space-m) var(--space-l)` | `var(--space-m) var(--space-l)` |

### Snippet

```html
<div class="cta cta--display" role="group" aria-label="Appel à mobilisation">
  <p class="cta__title">Créer un collectif local</p>
  <p class="cta__call">Je m’engage</p>
</div>
```

```css
.cta--display {
	display: grid;
	grid-template-columns: 1fr;
	border-radius: var(--radius-sharp);
	overflow: hidden;
}

.cta__title,
.cta__call {
	margin: 0;
	padding: var(--space-m) var(--space-l);
	font-family: var(--font-heading);
	font-weight: var(--weight-bold);
	color: var(--color-flag-white);
	text-transform: uppercase;
	letter-spacing: var(--tracking-wide);
}

.cta__title {
	background: var(--color-flag-green);
	font-size: var(--text-xl);
}

.cta__call {
	background: var(--color-flag-red);
	font-size: var(--text-lg);
}
```

The two blocks share the same width and abut directly with no gutter; the
shared `border-radius` on the parent (`overflow: hidden`) crops the corners
of each child block into one continuous hard-edged silhouette.

---

## WCAG reminder

Implementers MUST respect the following when shipping these CTAs:

- **Contrast ≥ 4.5:1** — white (`var(--color-flag-white)`) on
  `var(--color-flag-red)` and on `var(--color-flag-green)` both clear the AA
  ratio for normal-size text. Verify against the final rendered OKLCH value
  before shipping; do not lower it via transparency overlays.
- **Clickable target ≥ 44×44 px** — the interactive Variant A MUST have
  `min-height: 44px` (and ideally ≥ 48 px for comfortable touch); padding
  alone is not enough — the hit area must be measured at runtime.
- **`:focus-visible` MUST NOT be removed or suppressed** — the global
  `:focus-visible` outline (`outline: 2px solid var(--color-accent)`) is
  the only visual indicator that a keyboard user has reached the control.
  Do not set `outline: none` without replacing it with an equivalent ring
  styled with `var(--color-flag-white)` against the red fill.
- **`prefers-reduced-motion: reduce`** — disable all transition/animation
  on hover/focus for these CTAs (see Variant A snippet above for the
  canonical pattern).

---

## See also

- [`tokens.css`](./tokens.css) — single source of truth for all design
  tokens, including `--radius-sharp`.
- Parent issue: #16 (Style des CTA).
