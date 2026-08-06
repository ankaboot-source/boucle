# CSS Architecture

Structure stylesheets with cascade layers, native nesting, scoped styles, and a custom properties architecture that scales from small projects to large design systems.

## Cascade Layers (`@layer`)

Cascade layers give CSS authors explicit control over cascade priority. Layer order determines precedence -- specificity and source order within a layer become irrelevant across layer boundaries.

### Three Ways to Create Layers

```css
/* 1. Declare layer order upfront (statement at-rule) */
@layer reset, base, tokens, layouts, components, utilities;

/* 2. Named block with rules */
@layer components {
  .card { border: 1px solid oklch(92% 0.005 250); }
}

/* 3. Anonymous layer (cannot be appended to later) */
@layer {
  p { margin-block: 1rem; }
}
```

### Importing into Layers

```css
@import url('normalize.css') layer(reset);
@import url('framework.css') layer(components.vendor);
```

`@import` must precede all other rules except `@charset` and `@layer` statements.

### Ordering Rules

- First declared layer = lowest priority
- Last declared layer = highest priority
- Unlayered styles (outside any layer) have the *highest* normal priority
- A simple selector in a higher-priority layer overrides a complex selector in a lower-priority layer, regardless of specificity

```css
@layer base, components;

@layer components {
  .title { color: oklch(25% 0.02 250); }    /* Wins -- later layer */
}

@layer base {
  main .title { color: oklch(45% 0.02 250); } /* Loses -- earlier layer */
}
```

### The `!important` Reversal

When `!important` is applied, layer priority inverts. First-defined layers gain highest `!important` priority; unlayered `!important` declarations rank lower than layered ones.

**Priority order (highest to lowest):**
1. `!important` declarations in earlier layers (e.g. reset)
2. `!important` declarations in later layers (e.g. utilities)
3. `!important` declarations outside layers
4. Normal declarations outside layers
5. Normal declarations in later layers
6. Normal declarations in earlier layers

This means `!important` in a reset layer overrides `!important` in a utilities layer -- the opposite of normal behaviour. Layers make `!important` largely unnecessary; avoid it.

### Nested Layers

```css
@layer components {
  @layer defaults, structures, themes;
}

/* Append rules via dot notation */
@layer components.themes {
  .card { background: oklch(97% 0.003 250); }
}
```

### `revert-layer`

Rolls back to the previous layer's value for a property:

```css
@layer theme {
  a { color: oklch(60% 0.15 250); }
  .no-theme { color: revert-layer; }
}
```

Other global keywords for reference:
- `initial` -- browser default
- `inherit` -- parent element value
- `unset` -- remove all author styling
- `revert` -- remove author origin only
- `revert-layer` -- roll back to previous layer

### Recommended Layer Structure

```css
@layer reset, tokens, base, layouts, components, utilities;
```

| Layer | Purpose |
|-------|---------|
| `reset` | Normalize browser defaults |
| `tokens` | Custom properties (primitive + semantic) |
| `base` | Element-level typography, links, headings |
| `layouts` | Composition primitives (Stack, Sidebar, Grid) |
| `components` | Component-specific styles |
| `utilities` | Single-purpose overrides (highest normal priority) |

**Source:** CSS-Tricks -- "A Complete Guide to CSS Cascade Layers"; MDN -- `@layer`

## CSS Nesting

Native CSS nesting groups related rules inside a parent selector. Supported in Chrome 113+, Firefox 117+, Safari 16.6+.

### Syntax

```css
.card {
  padding: 1rem;
  background: oklch(100% 0 0);

  .title {
    font-weight: bold;
    color: oklch(25% 0.02 250);
  }

  &:hover {
    box-shadow: 0 2px 8px oklch(0% 0 0 / 0.1);
  }

  &.featured {
    border-color: oklch(60% 0.15 250);
  }
}
```

### The `&` Selector

- Represents the parent selector context
- Required for compound selectors: `&:hover`, `&.active`, `&::before`
- Required for joining: `&.featured` produces `.card.featured`
- Adjacent combinators work: `& + &` targets sibling relationships
- Optional for descendant selectors: `.title` inside `.card {}` is shorthand for `& .title`

### Specificity Behaviour (`:is()` Wrapper)

Nested selectors behave as if the parent is wrapped in `:is()` for specificity calculation. The nested rule takes the specificity of the *highest-specificity selector* in the parent's selector list.

```css
/* This nesting: */
article, .widget {
  p { color: oklch(45% 0.02 250); }
}

/* Behaves like: */
:is(article, .widget) p { color: oklch(45% 0.02 250); }
/* Specificity = (0, 1, 1) for ALL matches
   -- takes .widget's class specificity even when matching article p */
```

This can cause unexpected specificity inflation compared to Sass nesting, where each selector in a comma list expands independently.

### Nesting At-Rules

Media, container, supports, and layer queries nest directly:

```css
.card {
  display: block;

  @media (min-width: 40em) {
    display: grid;
    grid-template-columns: 1fr 2fr;
  }

  @container sidebar (min-width: 300px) {
    grid-template-columns: 1fr 1fr;
  }
}
```

### Depth Limits

Limit nesting to 2-3 levels maximum. Deeper nesting creates:
- Overly specific selectors that are hard to override
- Tight coupling between CSS and DOM structure
- Reduced readability

```css
/* Good: 2 levels */
.card {
  .title { font-weight: bold; }
  .title small { color: oklch(45% 0.02 250); }
}

/* Bad: 4+ levels mirrors DOM structure */
.page {
  .main {
    .section {
      .card {
        .title { font-weight: bold; }
      }
    }
  }
}
```

**Source:** MDN -- "CSS nesting"; web.dev -- "CSS Nesting"; Kilian Valkhof -- "The gotchas of CSS nesting"

## Scoped Styles (`@scope`)

`@scope` defines style boundaries so rules apply only within a subtree. Supported in Chrome 118+, Edge 118+, Safari 17.4+, Firefox 146+.

### Basic Syntax

```css
@scope (.card) {
  :scope {
    border: 1px solid oklch(92% 0.005 250);
    border-radius: 0.5rem;
  }
  .title { font-weight: bold; }
  .content { padding: 1rem; }
}
```

### Donut Scope

A donut scope has both an upper and lower boundary. Styles apply inside the upper bound but stop at the lower bound, creating a "hole" for slotted content.

```css
@scope (.card) to (.card-slot) {
  /* Styles apply inside .card but NOT inside .card-slot */
  p { color: oklch(25% 0.02 250); }
  img { border-radius: 0.5rem; }
}
```

The upper bound (`.card`) is inclusive; the lower bound (`.card-slot`) is exclusive.

### Scope Proximity

Scope proximity is a cascade criterion that comes after specificity but before source order. When two selectors have equal specificity, the one with the closer scope root wins:

```css
@scope (.light-theme) {
  p { color: oklch(25% 0.02 250); }
}
@scope (.dark-theme) {
  p { color: oklch(95% 0.01 250); }
}
/* If .dark-theme is nested inside .light-theme,
   elements inside .dark-theme get white text
   because that scope root is closer */
```

### `@scope` vs Nesting Comparison

| Feature | `@scope` | Nesting |
|---------|----------|---------|
| **Purpose** | Define component boundaries | Organize related selectors |
| **Lower boundary** | Yes (donut scope) | No |
| **Proximity in cascade** | Yes (closer scope wins) | No |
| **Specificity** | Does not add root specificity to scoped selectors | Parent specificity wraps via `:is()` |
| **Best for** | Component isolation, slots, theming | Pseudo-classes, states, media queries |

**Use `@scope` when:**
- Styles should not leak in or out of a component
- You need slots for nested content (donut scope)
- Themes are nested and proximity should resolve conflicts

**Use nesting when:**
- Grouping pseudo-classes, states, and media queries within a selector
- Expressing modifier relationships
- Improving readability of related rules

**Source:** MDN -- `@scope`; Chrome Developers -- "Limit the reach of your selectors with @scope"; Frontend Masters -- "How to @scope CSS now that it's Baseline"

## Custom Properties Architecture

### Three-Tier System: Primitive, Semantic, Component

```css
/* Tier 1: Primitives -- raw values, global, never used directly in components */
:root {
  --blue-1: oklch(98% 0.008 250);
  --blue-5: oklch(55% 0.15 250);
  --blue-9: oklch(10% 0.014 250);
  --gray-1: oklch(97% 0.003 250);
  --gray-5: oklch(58% 0.02 250);
  --gray-9: oklch(20% 0.01 250);
  --space-xs: 0.5rem;
  --space-s: 1rem;
  --space-m: 1.5rem;
  --space-l: 2rem;
  --radius-s: 0.25rem;
  --radius-m: 0.5rem;
}

/* Tier 2: Semantic -- contextual meaning, themeable */
:root {
  --color-text: var(--gray-9);
  --color-text-muted: var(--gray-5);
  --color-interactive: var(--blue-5);
  --color-surface: var(--gray-1);
  --color-background: oklch(100% 0 0);
  --color-border: oklch(92% 0.005 250);
}

/* Tier 3: Component -- scoped, prefixed with underscore */
.card {
  --_padding: var(--space-m);
  --_radius: var(--radius-m);
  --_border: var(--color-border);

  padding: var(--_padding);
  border-radius: var(--_radius);
  border: 1px solid var(--_border);
}
```

**Key principles:**
- Never use primitive tokens directly in component styles -- always go through semantic tokens
- Semantic tokens reference primitives; component tokens reference semantics
- This one-directional chain enables theming: change semantic tokens and all components update
- Component tokens use a leading underscore (`--_color`) to signal "private" scope
- Keep primitives to a curated set -- not every possible value

### Theming via `light-dark()`

```css
:root {
  color-scheme: light dark;

  --color-text: light-dark(oklch(25% 0.02 250), oklch(95% 0.01 250));
  --color-surface: light-dark(oklch(97% 0.003 250), oklch(15% 0.01 250));
  --color-interactive: light-dark(oklch(60% 0.15 250), oklch(70% 0.12 250));
  --color-border: light-dark(oklch(92% 0.005 250), oklch(30% 0.01 250));
}
```

`light-dark()` requires `color-scheme: light dark` on the element or an ancestor. The first value applies in light mode, the second in dark mode.

### Anti-Patterns

- **Hundreds of unused primitives** -- curate only the values the design system actually uses
- **All tokens on `:root`** -- scope component tokens to component selectors
- **Skipping the semantic layer** -- going straight from primitive to component makes theming impossible
- **Custom properties for static values** -- if a value never changes and is never shared, just use the value directly

**Source:** Keith J. Grant -- "A Structured Approach to Custom Properties"; Penpot -- "Developer's Guide to Design Tokens"

## CSS Methodologies

### BEM (Block Element Modifier)

```css
.card { }
.card__title { }
.card__title--highlighted { }
```

- Forces flat specificity (almost all selectors are single-class)
- Predictable, explicit naming scales well in teams
- Verbose naming can feel heavy
- Still relevant for design systems needing strict conventions

### Utility-First (Tailwind)

```html
<div class="p-4 rounded-md border border-gray-200 bg-white">
  <h2 class="font-bold text-lg">Title</h2>
</div>
```

- All utilities at (0,1,0) specificity -- very flat
- Fast prototyping, consistent design tokens
- Trades CSS file readability for HTML-centric styling
- Requires purging to remove unused CSS

### CUBE CSS (Composition Utility Block Exception)

Created by Andy Bell. Embraces the cascade rather than fighting it.

**Four layers:**
- **Composition:** Layout primitives (Stack, Sidebar, Cluster)
- **Utility:** Single-purpose classes (`.text-center`, `.flow`)
- **Block:** Component-specific styles (minimal by the time you reach this layer)
- **Exception:** State deviations via data attributes

```css
/* Block */
.card {
  padding: var(--space-m);
  background: oklch(100% 0 0);
}

/* Exception via data attribute */
.card[data-state="reversed"] {
  display: flex;
  flex-direction: column-reverse;
}
```

Exceptions use `data-*` attributes instead of BEM modifiers, providing a hook for both CSS and JavaScript.

### Every Layout Primitives

12 composable layout primitives by Heydon Pickering and Andy Bell: Stack, Box, Center, Cluster, Sidebar, Switcher, Cover, Grid, Frame, Reel, Imposter, Icon.

Each primitive has a single responsibility and is intrinsically responsive -- no media queries, no magic numbers. Primitives compose as parents, children, or siblings.

```css
/* The Stack: vertical spacing between siblings */
.stack > * + * {
  margin-block-start: var(--space-s, 1rem);
}

/* The Sidebar: content alongside a sidebar */
.with-sidebar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space-l, 2rem);
}
.with-sidebar > :first-child {
  flex-basis: 20rem;
  flex-grow: 1;
}
.with-sidebar > :last-child {
  flex-basis: 0;
  flex-grow: 999;
  min-inline-size: 50%;
}
```

### Recommended Combination

Use cascade layers as the orchestration layer -- they work with any methodology:

```css
@layer reset, tokens, base, layouts, components, utilities;
```

- **Layouts layer:** Every Layout primitives for composition
- **Components layer:** CUBE CSS or BEM for component naming
- **Utilities layer:** Sparingly, for one-off overrides at highest priority
- **Tokens layer:** Three-tier custom properties architecture

Cascade layers + low-specificity methodology = the strongest combination.

**Source:** CUBE CSS -- cube.fyi; Every Layout -- every-layout.dev; Smashing Magazine -- "CSS Cascade Layers vs BEM vs Utility Classes"

## Anchor Positioning

CSS anchor positioning connects an absolutely positioned element to one or more anchor elements. Supported in Chrome 125+, Edge 125+. Safari and Firefox do not yet fully support it -- use as progressive enhancement.

### `anchor-name` and `position-anchor`

```css
/* Define an anchor */
.trigger {
  anchor-name: --tooltip-anchor;
}

/* Position relative to anchor */
.tooltip {
  position: absolute;
  position-anchor: --tooltip-anchor;
}
```

### `position-area`

A shorthand that places the positioned element in a region of the anchor's grid:

```css
.tooltip {
  position: absolute;
  position-anchor: --tooltip-anchor;
  position-area: block-start center;
  margin-block-end: 0.5rem;
}
```

### `position-try-fallbacks`

When the preferred position overflows the viewport, the browser tries fallback positions:

```css
.tooltip {
  position: absolute;
  position-anchor: --tooltip-anchor;
  position-area: block-start center;
  position-try-fallbacks: flip-block, flip-inline, flip-block flip-inline;
}
```

**Flip keywords:**
- `flip-block` -- mirrors across the block axis (top/bottom)
- `flip-inline` -- mirrors across the inline axis (left/right)
- Combined: `flip-block flip-inline`

### `@position-try`

Define named custom fallback positions:

```css
@position-try --below-end {
  position-area: block-end span-inline-end;
  margin-block-start: 0.5rem;
}

.dropdown {
  position: absolute;
  position-anchor: --menu-trigger;
  position-area: block-end span-inline-start;
  position-try-fallbacks: --below-end, flip-block;
}
```

**Source:** CSS-Tricks -- "CSS Anchor Positioning Guide"; Chrome Developers -- "Anchor Positioning API"; MDN -- "CSS Anchor Positioning"

## CSS File Organisation

### Layer-Based File Structure

```
styles/
  main.css                /* Layer order + @import statements */
  reset.css               /* @layer reset */
  tokens/
    primitives.css        /* @layer tokens */
    semantic.css          /* @layer tokens */
  base/
    typography.css        /* @layer base */
    elements.css          /* @layer base */
  layouts/
    stack.css             /* @layer layouts */
    sidebar.css           /* @layer layouts */
    grid.css              /* @layer layouts */
  components/
    card.css              /* @layer components */
    button.css            /* @layer components */
    dialog.css            /* @layer components */
  utilities/
    spacing.css           /* @layer utilities */
    visibility.css        /* @layer utilities */
```

### Entry Point Pattern

The single entry point declares layer order and imports everything:

```css
/* main.css -- single source of truth for cascade order */
@layer reset, tokens, base, layouts, components, utilities;

@import url('reset.css') layer(reset);
@import url('tokens/primitives.css') layer(tokens);
@import url('tokens/semantic.css') layer(tokens);
@import url('base/typography.css') layer(base);
@import url('base/elements.css') layer(base);
@import url('layouts/stack.css') layer(layouts);
@import url('layouts/sidebar.css') layer(layouts);
@import url('components/card.css') layer(components);
@import url('components/button.css') layer(components);
@import url('utilities/spacing.css') layer(utilities);
```

**Key principles:**
- Declare layer order at the very top, once
- Each file goes into exactly one layer
- One component per file, named after the component
- Third-party CSS goes into its own layer or a sub-layer: `@import url('vendor.css') layer(components.vendor);`
- Build tools should bundle `@import` statements for production to avoid sequential loading

**Source:** Matthias Ott -- "How I Structure My CSS"; iO Digital -- "Modular CSS Architecture with @layer"

## When to Use Which Approach

### Small Project (marketing page, blog)

- Cascade layers: `@layer reset, base, components, utilities`
- Simple naming -- `.card`, `.card-title` (no BEM needed)
- Minimal custom properties (semantic layer only)
- Nesting for pseudo-classes and media queries
- Every Layout primitives for composition

### Design System / Component Library

- Full layer architecture with nested sub-layers
- CUBE CSS or BEM naming for explicit component structure
- Three-tier custom properties (primitive, semantic, component)
- `@scope` for component encapsulation where supported
- Every Layout primitives as layout building blocks
- Strict nesting depth limits (max 2 levels)

### Large Application with Third-Party CSS

- Cascade layers essential -- layer vendor CSS below your own
- `@import url('framework.css') layer(vendor)` with vendor declared before components
- BEM or CUBE naming to avoid collisions with third-party selectors
- `@scope` for component isolation
- Utility layer at highest priority for overrides
- Aggressive unused CSS removal (PurgeCSS or similar)

## Common Mistakes

### Over-Nesting

Mirroring DOM structure in CSS (`.page .main .section .card .title`) creates brittle, overly specific selectors. Every nesting level inflates specificity via the `:is()` wrapper.

**Rule of thumb:** If you need to nest more than 2-3 levels, restructure.

### Specificity Wars

Overriding styles with ever-more-specific selectors instead of refactoring. Cascading `!important` declarations that become impossible to override. Using IDs in selectors (`#header .nav`) when classes suffice.

**Solution:** Use cascade layers to manage priority; keep selectors flat.

### Unused CSS

Shipping CSS that applies to no elements on the page increases file size and slows parsing. Common in utility-first frameworks without purging. Average web page ships 50-80% unused CSS.

**Tools:** Chrome DevTools Coverage panel, PurgeCSS, Lightning CSS.

### Too Many Custom Properties

Defining primitive tokens for every possible value ("just in case"). Putting all tokens on `:root` when many are only used in one component. Skipping the semantic layer, making theming impossible.

**Rule:** If a value never changes and is never shared, just use the value directly.

### Misunderstanding Nesting Specificity

Native CSS nesting wraps parents in `:is()`, which differs from Sass output. A parent list like `article, .widget` gives all nested selectors the specificity of `.widget` (0,1,0) even when matching via `article` (0,0,1).

```css
/* Developers expect (0, 0, 2) for article p but get (0, 1, 1): */
article, .widget {
  p { color: oklch(45% 0.02 250); }
}
```

### Ignoring `!important` Reversal in Layers

`!important` in an early layer (e.g. reset) overrides `!important` in a later layer (e.g. utilities) -- the opposite of normal cascade behaviour. This catches developers who place `!important` in utility layers expecting highest priority.

## Performance Considerations

### Selector Efficiency

Modern browsers match selectors in microseconds. The difference between `.card .title` and `.card-title` is negligible. Optimise for developer experience and maintainability, not selector speed.

**Exception:** Extremely large DOMs (10,000+ elements) with deeply nested descendant selectors may show measurable impact.

### File Size

Every byte of CSS is render-blocking -- the browser cannot paint until CSSOM is built.
- Remove unused CSS (biggest win for most projects)
- Use shorthand properties where appropriate (`margin` instead of four `margin-*` declarations)
- Minify and compress (gzip/brotli)
- Avoid duplicating declarations across files

### Unused CSS

Average web page ships 50-80% unused CSS, especially with frameworks. Use the Chrome DevTools Coverage panel to identify unused rules. PurgeCSS or Lightning CSS can strip unused selectors at build time.

### Render-Blocking

All `<link rel="stylesheet">` in `<head>` is render-blocking by default.
- Inline critical CSS (above-the-fold styles) to improve LCP
- Use `media` attribute on `<link>` to defer non-matching stylesheets: `<link rel="stylesheet" href="print.css" media="print">`
- Avoid `@import` in production without build tools (causes sequential loading)

### Custom Properties Performance

Custom property inheritance is cheap -- browsers handle it efficiently.
- Avoid setting custom properties on every element; prefer `:root` or component roots
- `@property` registration with `inherits: false` prevents unnecessary recalculation down the tree
- Cascade layers add minimal parsing overhead -- the benefit of eliminating `!important` chains outweighs any cost

**Source:** MDN -- "CSS Performance Optimization"; DebugBear -- "Reduce Unused CSS"; Jens Oliver Meiert -- "CSS Optimization Basics"

## Sources

- CSS-Tricks: "A Complete Guide to CSS Cascade Layers" -- https://css-tricks.com/css-cascade-layers/
- MDN: `@layer` -- https://developer.mozilla.org/en-US/docs/Web/CSS/@layer
- MDN: "CSS nesting" -- https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_nesting
- MDN: `@scope` -- https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@scope
- MDN: "CSS Performance Optimization" -- https://developer.mozilla.org/en-US/docs/Learn_web_development/Extensions/Performance/CSS
- web.dev: "CSS Nesting" -- https://web.dev/learn/css/nesting
- Chrome Developers: "Limit the reach of your selectors with @scope" -- https://developer.chrome.com/docs/css-ui/at-scope
- Chrome Developers: "CSS Anchor Positioning API" -- https://developer.chrome.com/blog/anchor-positioning-api
- CSS-Tricks: "CSS Anchor Positioning Guide" -- https://css-tricks.com/css-anchor-positioning-guide/
- CUBE CSS -- https://cube.fyi/
- Every Layout -- https://every-layout.dev/
- Smashing Magazine: "CSS Cascade Layers vs BEM vs Utility Classes" -- https://www.smashingmagazine.com/2025/06/css-cascade-layers-bem-utility-classes-specificity-control/
- Keith J. Grant: "A Structured Approach to Custom Properties" -- https://keithjgrant.com/posts/2024/06/a-structured-approach-to-custom-properties/
- Matthias Ott: "How I Structure My CSS" -- https://matthiasott.com/notes/how-i-structure-my-css
- Frontend Masters: "How to @scope CSS now that it's Baseline" -- https://frontendmasters.com/blog/how-to-scope-css-now-that-its-baseline/
- Kilian Valkhof: "The Gotchas of CSS Nesting" -- https://kilianvalkhof.com/2023/css-html/the-gotchas-of-css-nesting/
- Jens Oliver Meiert: "CSS Optimization Basics" -- https://leanpub.com/css-optimization-basics
- DebugBear: "Reduce Unused CSS" -- https://www.debugbear.com/blog/reduce-unused-css

## Chapter Summary

1. Declare cascade layer order once at the top of the stylesheet (`@layer reset, tokens, base, layouts, components, utilities`) -- layer order determines priority, not specificity
2. Unlayered styles have highest normal priority; `!important` reverses layer order -- avoid `!important` entirely
3. Use native CSS nesting for pseudo-classes, states, and media queries within a component; limit depth to 2-3 levels
4. Nested selectors inherit the highest specificity from the parent's selector list via the `:is()` wrapper -- be aware this differs from Sass
5. Use `@scope` for component boundary isolation and donut scope for slotted content; scope proximity resolves theming conflicts
6. Structure custom properties in three tiers: primitive (raw values), semantic (contextual meaning), component (scoped with `--_` prefix)
7. Use `light-dark()` on semantic tokens for dark mode theming; requires `color-scheme: light dark` on an ancestor
8. Combine cascade layers with a low-specificity methodology (CUBE CSS or BEM) and Every Layout primitives for composition
9. Use anchor positioning (`position-anchor`, `position-area`, `position-try-fallbacks`) as progressive enhancement for tooltips and dropdowns
10. Organise files by layer with a single entry point (`main.css`) that declares layer order and imports all partials
11. Remove unused CSS (50-80% of shipped CSS is unused on average) -- this is the single biggest performance win
12. Keep selectors flat, avoid specificity wars, and let cascade layers manage priority instead of `!important` chains
