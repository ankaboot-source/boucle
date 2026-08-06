# Layout and Spacing

Create a consistent spacing system and learn about alignment and layout.

## Group Related Elements

Breaking up information into smaller groups helps structure and organise an interface.

### 4 Grouping Methods

**1. Place related elements in the same container**
- Strongest visual cue for grouping
- Create containers using borders, shadows, background colours
- Use for main structure (headers, sidebars, content areas)
- Cards and dialog boxes group smaller related content
- Avoid containers for EVERY group - causes clutter

**2. Space related elements close together (Proximity)**
- Related elements closer together
- Unrelated elements further apart
- Can help declutter vs containers

**3. Make related elements look similar (Similarity)**
- Similar visual characteristics: size, shape, colour
- Highlight certain elements by making them slightly different
- If elements look similar, they should FUNCTION similarly
- Don't make non-interactive elements look like buttons

**4. Align related elements in a continuous line (Continuity)**
- Eyes naturally follow elements aligned in lines
- Lists group related elements
- Disrupt continuity to indicate end of group or highlight element

### Combining Methods
Use multiple methods together for clearer groupings. If elements are grouped multiple ways, you can often remove containers to simplify.

### Don't Default to Cards

Cards group heterogeneous content (image + text + action) into a self-contained, browsable unit. They are not a general-purpose container.

**Use cards when:**
- Displaying browsable collections of mixed content (product listings, article teasers)
- Each item is an entry point to a detail view
- Items contain varied content types that need visual containment

**Don't use cards when:**
- A simple list would work — homogeneous text items are faster to scan in a plain list
- Wrapping a single content section — use a heading and whitespace instead
- Grouping form fields — use `<fieldset>` and spacing, not a card container
- Displaying tabular data — use a `<table>` (supports sorting, filtering, comparison)
- Content is meant to be read sequentially — use body text with headings

**Never nest cards inside cards.** Each card level adds border/shadow/padding chrome that compounds visual noise without adding information. If content inside a card needs sub-grouping, use a heading, divider, or subtle background tint.

**Alternatives to card containers** (from least to most visual weight):

| Separation method | Visual weight |
|-------------------|---------------|
| Spacing (whitespace between groups) | Lightest |
| Background colour (subtle fill difference) | Light |
| Box shadow (depth cue) | Medium |
| Border / card container | Heaviest |

Before adding a card border, ask: does this container help the user understand the grouping, or is it just visual noise?

## Create a Clear Visual Hierarchy

Present information in order of importance.

### Methods to Control Prominence

**Size** - Make important elements larger

**Colour** - Use brighter, richer, warmer, higher contrast colours for important elements

**Contrast** - Style important elements differently to stand out

**Spacing** - Surround important elements with more space

**Position** - Place important elements toward top or first in row

**Depth** - Elevate important elements (appear closer)

### Practical Steps to Improve Visual Hierarchy

1. Group related information into separate sections
2. Order information in each section by importance
3. Order sections by importance (most important = top)
4. Change element styles based on importance:
   - Important: large, bold, "Text strong" colour
   - Secondary: smaller, regular weight, "Text weak" colour
   - Use icons for common patterns (star ratings)
   - Important CTAs: primary button with brand colour
   - Less important details: remove unnecessary labels

## Test Visual Hierarchy - The Squint Test

Quick test: Squint at your design (or blur/step back).

**Should be able to:**
- Tell what most important elements are
- Recognise what interface is for

## Use Depth to Create Visual Hierarchy

**Elevation:**
- Higher elevation = closer, more prominent
- Lower elevation = further away, less prominent
- Elevate important elements higher
- Elevation can make elements feel interactive

## Understand the Box Model

Interfaces = rectangles within rectangles.

**Each rectangle has:**
- **Margin** - space between box and neighbouring boxes
- **Border** - stroke around edge
- **Padding** - space between border and contents

**Key observation:** Spacing starts small in innermost rectangles and increases moving outwards.

## Design @1x Using Points

**Points vs Pixels:**
- @1x: 1pt = 1px
- @2x: 1pt = 4px (2x2)
- @3x: 1pt = 9px (3x3)

Always work in points (@1x).

## Create a Set of Predefined Spacing Options

**8pt Grid (T-shirt sizes):**
```
XS:  8pt   - Closely related elements
S:   16pt  - Related elements
M:   24pt  - Component padding
L:   32pt  - Grid gutters, section gaps
XL:  48pt  - Large section gaps
XXL: 80pt  - Page section padding
```

**Why 8pt?**
- Many screen sizes divisible by 8
- More flexibility than 10pt
- For detailed interfaces, use 4pt increments

**Benefits:**
- Simplified designs (less variation)
- Improved consistency
- Design faster (fewer options)

## Space Elements Based on How Closely Related They Are

**Key principle:** More closely related = closer together

### Application Method
1. Break interface into rectangles within rectangles
2. Start with XS (8pt) for innermost rectangles
3. Gradually increase spacing moving outwards

**Example spacing progression:**
- XS (8pt): Card text (closely related)
- M (24pt): Card padding, section content
- L (32pt): Between navigation links, between cards (grid gutters)
- XXL (80pt): Page section vertical padding

### Create Spacing Rules
Example rules for consistency:
- M (24pt) internal padding for components
- L (32pt) gaps between columns
- XXL (80pt) vertical padding for sections

## Be Generous with White Space

White space = empty space between/around elements (can be any colour/pattern).

**Benefits:**
- Easier to see groupings and hierarchy
- Easier to understand information
- Looks simpler, cleaner, more sophisticated

**Tip:** Instead of XS spacing option, consider using next one up.

**Test:** Use Squint Test - if you can't distinguish elements, increase spacing.

## Align the Main Layout to a 12 Column Grid

**Components:**
- **Columns (12)** - vertical columns for aligning main elements
- **Gutters** - empty spaces between columns (separate/align content)
- **Margins** - empty space on left/right edges

### Columns
- Align main containers to one or more columns
- Smaller elements inside don't need to align to grid
- Generally flexible width (percentages)
- 12 columns for large screens, fewer for mobile

**Example:** 3 cards spanning 4 columns each on desktop, stack on 4 columns on mobile.

### Gutters
- Remain empty
- Narrower than columns
- Fixed width, wider on larger screens
- Example: L (32pt) on desktop, S (16pt) on mobile

### Margins
- Prevent content hitting edges
- Fixed or flexible width
- Wider on larger screens
- Example: XXL (80pt) on desktop, S (16pt) on mobile

**Why 12?** Most common, sufficient flexibility, aligns with frontend frameworks.

## Align Text to Improve Readability

**Left-aligned text is easiest to read:**
- Consistent left edge = anchor for eyes
- Maintain straight left edge with other elements (icons)

### Align Horizontal Text to Baseline
- Baseline = invisible line text sits on
- Different sized text in same line: align to baseline (not vertical centre)
- Creates easier reading, neater design

## Try to Avoid Using Multiple Alignments

Fewer alignments = simpler, neater.

**Issues with multiple alignments:**
- Eyes work harder moving around
- Looks messy
- Increases cognitive load

**Tip:** If you must use centre alignment, full-width buttons help both left/right handed users reach easily.

## Keep Related Actions Close (Fitts's Law)

**Fitts's Law:** Closer and larger target = faster to select.

**Application:**
- Keep actions close to related elements
- Ensure sufficient target area (48pt x 48pt minimum)
- Move close buttons to start position (near menu icon)
- Increase size of menu items for faster/easier tapping
- Add visible borders to indicate target area

## Ensure an Interface is Unbreakable

Don't just design for short text and small numbers.

**Guidelines:**
- Accommodate long data and edge cases
- Avoid hiding essential overflowing data
- Keep components flexible for content reflow
- Or decrease font sizes for long data

**Account for translations:** Text can grow significantly in other languages. German and Portuguese translations can increase text length by up to 75% compared to English. Always test layouts with longer strings.

**Quick text boundary tests:**
- **Max height:** Use "Åy" - combines the tallest ascender (Å) and deepest descender (y) of most Latin typefaces
- **Max width:** Fill with "WWW..." - W is the widest character in most fonts; if it fits, any other text will too

**If hiding is necessary:**
- Don't hide essential information
- Consider cropping in middle (not end) to help differentiate items

## Use the Rule of Thirds for Photos

Divide photo into 3x3 grid = 4 focal points at intersections.

**Application:**
- Align key elements to grid
- Place main subject on focal point
- Don't centre subjects - creates rigid, still appearance
- Asymmetry introduces natural motion and flow
- Align horizon with horizontal grid

**Especially effective for:**
- Action shots (increases sense of motion)
- Landscapes (align horizon to grid)

## Consider Optical Adjustments

Mathematical centering doesn't always look visually centered. Our eyes perceive shapes differently based on their weight distribution.

**Common situations requiring optical adjustment:**

- **Play icons in circles:** The triangle's point has less visual weight - shift it slightly right to look centered
- **Text alignment:** Text often needs `-0.05em` negative margin on the left to align optically with elements above
- **Icons next to text:** May need 1-2px vertical shift to align with text baseline
- **Button padding:** Bottom padding often needs 1-2px extra to feel equal to top padding

This is an advanced technique that requires a trained eye. When something looks "off" despite being mathematically correct, optical adjustment is usually the answer.

### Nested Border Radii

When an element with rounded corners contains another element with rounded corners (e.g. a card with a button inside), the outer radius should equal the inner radius plus the border/padding between them:

```css
/* outer radius = inner radius + gap between them */
.card {
  border-radius: 16px;  /* 8px + 8px padding */
  padding: 8px;
}
.card-inner {
  border-radius: 8px;
}
```

Matching inner and outer radii produces corners that thicken awkwardly. Adding the gap creates a consistent, parallel curve.

## Use Logical Properties

Use `margin-inline-start/end` and `block-size` instead of `margin-left/right` and `height`. Logical properties honour writing direction and work correctly for RTL languages.

```css
/* Physical (fragile) */
margin-left: 1rem;
margin-right: 1rem;
width: 100%;
height: 50vh;

/* Logical (robust) */
margin-inline-start: 1rem;
margin-inline-end: 1rem;
inline-size: 100%;
block-size: 50vh;
```

**Mapping (for horizontal-tb, ltr):**
- `margin-left` → `margin-inline-start`
- `margin-right` → `margin-inline-end`
- `margin-top` → `margin-block-start`
- `margin-bottom` → `margin-block-end`
- `width` → `inline-size`
- `height` → `block-size`
- `padding-left` → `padding-inline-start`

**Shorthand:** `margin-inline`, `margin-block`, `padding-inline`, `padding-block`

## Apply box-sizing: border-box Globally

Makes calculating box dimensions predictable - padding and border are included in the element's total size.

```css
*, *::before, *::after {
  box-sizing: border-box;
}
```

Without this, a `300px` wide element with `20px` padding becomes `340px`. With `border-box`, the content area shrinks to accommodate padding within the `300px`.

## Use Contextual Spacing (The Stack Pattern)

Margin is a property of the *relationship* between two elements, not of an element itself. Style the context, not the individual element.

```css
/* Don't: margin on individual elements */
p { margin-bottom: 1.5rem; }  /* Creates orphan margin on last element */

/* Do: margin between adjacent siblings via parent */
.stack > * + * {
  margin-block-start: 1.5rem;
}
```

The `* + *` selector (the "owl") only applies margin where an element is preceded by a sibling - no orphan margins.

**Nested stacks for varied spacing:**
```css
.stack-lg > * + * { margin-block-start: 3rem; }
.stack-sm > * + * { margin-block-start: 0.5rem; }
```

**Split a stack** to push elements apart (e.g. card footer to bottom):
```css
.stack {
  display: flex;
  flex-direction: column;
}
.stack > :nth-child(2) {
  margin-block-end: auto;  /* Pushes everything after this to the bottom */
}
```

## Implement a CSS Modular Scale with Custom Properties

**Modular scale vs 8pt grid:** The 8pt spacing scale (XS–XXL) is the primary system for component and layout spacing. The modular scale is an alternative for typography-driven layouts where all spacing derives from the type scale ratio. Pick one per project — don't mix both or spacing decisions become ambiguous.

Express your spacing scale as CSS custom properties derived from a single ratio. This creates visual harmony - all spacing values are mathematically related.

```css
:root {
  --ratio: 1.5;
  --s-2: calc(var(--s-1) / var(--ratio));
  --s-1: calc(var(--s0) / var(--ratio));
  --s0: 1rem;
  --s1: calc(var(--s0) * var(--ratio));
  --s2: calc(var(--s1) * var(--ratio));
  --s3: calc(var(--s2) * var(--ratio));
  --s4: calc(var(--s3) * var(--ratio));
  --s5: calc(var(--s4) * var(--ratio));
}
```

Use these everywhere: `padding: var(--s1)`, `gap: var(--s0)`, `margin-block-start: var(--s3)`. Change `--ratio` and the entire design scales harmoniously. The ratio of 1.5 mirrors a common `line-height` value, creating natural vertical rhythm.

## Set a Global Measure Axiom

Cap line length globally using an exception-based approach:

```css
* {
  max-inline-size: 60ch;
}
html, body, div, header, nav, main, footer, section, aside {
  max-inline-size: none;
}
```

Container elements are excepted; text-bearing elements automatically get reasonable line lengths. Use a custom property for easy adjustment: `--measure: 60ch`.

## Prefer Intrinsic Responsiveness Over Breakpoints

Layouts that respond to their own content are more robust than layouts controlled by viewport breakpoints. Use CSS that *suggests* rather than *dictates* layout.

### The Sidebar Pattern
A sidebar that automatically stacks when space is tight:
```css
.with-sidebar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s1);
}
.with-sidebar > :first-child {
  flex-basis: 15rem;     /* sidebar width */
  flex-grow: 1;
}
.with-sidebar > :last-child {
  flex-basis: 0;
  flex-grow: 999;        /* takes remaining space */
  min-inline-size: 50%;  /* forces wrap when too narrow */
}
```

### The Switcher Pattern
Switches between horizontal and vertical layout based on available space:
```css
.switcher {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s1);
}
.switcher > * {
  flex-grow: 1;
  flex-basis: calc((30rem - 100%) * 999);
  /* 30rem = threshold: above it → horizontal, below → vertical */
}
```

### The Cluster Pattern
Wrapping horizontal groups (tags, buttons, navigation):
```css
.cluster {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s1);
  align-items: center;
}
```

### The Center Pattern
Horizontally centered content with a max-width for readability:
```css
.center {
  box-sizing: content-box;
  max-inline-size: var(--measure);
  margin-inline: auto;
  padding-inline: var(--s1);
}
```

### The Cover Pattern
A vertically centered element within a minimum height container (hero sections):
```css
.cover {
  display: flex;
  flex-direction: column;
  min-block-size: 100vh;
  padding: var(--s1);
}
.cover > * { margin-block: var(--s1); }
.cover > .centered { margin-block: auto; }  /* Vertically centers this child */
```

### The Grid Pattern
Auto-filling grid that adapts column count to available space:
```css
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(250px, 100%), 1fr));
  gap: var(--s1);
}
```
The `min(250px, 100%)` prevents overflow on narrow screens.

### The Frame Pattern
Crop any content to an aspect ratio:
```css
.frame {
  aspect-ratio: 16 / 9;
  overflow: hidden;
}
.frame > img,
.frame > video {
  inline-size: 100%;
  block-size: 100%;
  object-fit: cover;
}
```

## Responsive Images

Images are often the heaviest assets on a page. Use modern HTML attributes to serve the right image at the right size without layout shifts.

### Prevent Layout Shift with aspect-ratio

When an image loads, the browser doesn't know its dimensions until the file arrives — causing content below to jump. Reserve space upfront:

```html
<img src="hero.webp" alt="..." width="1200" height="675"
     loading="lazy" decoding="async">
```

The `width` and `height` attributes let modern browsers calculate the aspect ratio before loading. For CSS-controlled sizing, use `aspect-ratio` explicitly:

```css
.hero-image {
  aspect-ratio: 16 / 9;
  inline-size: 100%;
  object-fit: cover;
}
```

### Serve Responsive Sizes with srcset

Don't send a 2400px image to a 375px phone. Use `srcset` and `sizes` to let the browser choose:

```html
<img
  src="photo-800.webp"
  srcset="photo-400.webp 400w,
          photo-800.webp 800w,
          photo-1200.webp 1200w,
          photo-1600.webp 1600w"
  sizes="(min-width: 960px) 50vw, 100vw"
  alt="Descriptive alt text"
  loading="lazy"
  decoding="async"
>
```

- `srcset` lists available files with their pixel widths (`w` descriptor)
- `sizes` tells the browser how wide the image will display at each breakpoint
- The browser picks the smallest file that satisfies the display size and screen density

### Use `<picture>` for Art Direction

When you need different crops or aspect ratios at different breakpoints (not just different sizes), use `<picture>`:

```html
<picture>
  <source media="(min-width: 960px)" srcset="hero-wide.webp" type="image/webp">
  <source media="(min-width: 960px)" srcset="hero-wide.jpg">
  <source srcset="hero-square.webp" type="image/webp">
  <img src="hero-square.jpg" alt="..." loading="lazy" decoding="async">
</picture>
```

### Image Format Priority

1. **AVIF** — smallest files, best quality, ~93% browser support
2. **WebP** — good compression, ~97% support
3. **JPEG/PNG** — universal fallback

Use `<picture>` with `type` to serve modern formats with fallbacks. For most projects, WebP alone is sufficient.

### Lazy Loading

Add `loading="lazy"` to images below the fold. The browser defers loading until the image approaches the viewport.

**Do NOT lazy-load:**
- Hero images and above-the-fold content (these should load immediately)
- Images critical to Largest Contentful Paint (LCP)

**Do lazy-load:**
- Gallery images, card thumbnails, anything below the fold
- `decoding="async"` can be added to all images — it prevents the image decode from blocking the main thread

### Always Provide Meaningful Alt Text

Every `<img>` must have an `alt` attribute. The text should describe the content or function of the image, not its appearance.

```html
<!-- Decorative: empty alt (screen readers skip it) -->
<img src="divider.svg" alt="">

<!-- Informative: describe the content -->
<img src="chart.png" alt="Sales revenue increased 40% from Q1 to Q3 2024">

<!-- Functional: describe the action -->
<a href="/home"><img src="logo.svg" alt="Acme Corp home page"></a>
```

## Use Container Queries for Component-Level Responsiveness

Media queries respond to the *viewport*. Container queries (Baseline 2023) respond to the *parent container's* size — making components truly self-contained and reusable.

```css
/* 1. Declare a containment context */
.card-container {
  container-type: inline-size;
}

/* 2. Style based on the container's width, not the viewport */
.card {
  display: grid;
  gap: var(--s0);
}

@container (min-width: 400px) {
  .card {
    grid-template-columns: 150px 1fr;
  }
}
```

**When to use container queries vs media queries:**
- **Container queries** — component layout decisions (card layout, sidebar widget, embedded component). The component adapts to whatever space it's given, regardless of viewport size
- **Media queries** — page-level layout decisions (number of columns, navigation style, overall page structure)

**Practical principle:** If a component might appear in different contexts (full-width page, narrow sidebar, modal), it should use container queries. The same card component then works everywhere without overrides.

Container queries support all the same syntax as media queries (`min-width`, `max-width`, ranges) and can be named for clarity:

```css
.sidebar { container: sidebar / inline-size; }

@container sidebar (min-width: 300px) {
  .widget { /* wider layout */ }
}
```

## Use Subgrid for Consistent Nested Alignment

Subgrid (Baseline 2023) lets child elements participate in their parent's grid tracks — solving the long-standing problem of aligning content across sibling cards.

**The problem without subgrid:** When cards have varying content lengths, their internal elements (title, body, footer) don't align across the row. Each card's grid is independent.

```css
/* Parent grid */
.card-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(280px, 100%), 1fr));
  gap: var(--s1);
}

/* Each card inherits the parent's row tracks */
.card {
  display: grid;
  grid-row: span 3;                  /* card spans 3 implicit row tracks */
  grid-template-rows: subgrid;       /* inherit parent's row sizing */
}
```

Now all cards' titles, bodies, and footers align horizontally across the row — even when content lengths differ. No fixed heights, no JavaScript measurement.

**Use subgrid when:**
- Cards or list items need their internal elements to align across a row
- Form labels and inputs need to align across a grid
- Any nested content needs to participate in the parent's track sizing

## Detect Input Method with Interaction Media Queries

Screen size does not reveal input method. A 13-inch Surface has a touchscreen; a 10-inch iPad can have a keyboard and trackpad. Use `pointer` and `hover` media queries (Baseline 2018) to adapt interaction patterns to the actual input device.

| Query | Matches | Typical Devices |
|-------|---------|-----------------|
| `pointer: fine` | Accurate primary pointer | Mouse, trackpad, stylus |
| `pointer: coarse` | Imprecise primary pointer | Finger on touchscreen |
| `hover: hover` | Primary input can hover | Mouse, trackpad |
| `hover: none` | Primary input cannot hover | Touchscreen |

### Gate Hover Effects Behind Capability

On touchscreens, tapping an element triggers `:hover` styles that "stick" after the tap. Gate hover effects behind the combined query:

```css
@media (hover: hover) and (pointer: fine) {
  .card:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 12px oklch(0% 0 0 / 0.12);
  }
}
```

The combined query `(hover: hover) and (pointer: fine)` is the most reliable pattern — using `hover: hover` alone can match Android devices that emulate hover via long-press.

### Always Provide a Focus Alternative

Every `:hover` interaction must have a `:focus` or `:focus-within` equivalent. Keyboard users never see hover states.

```css
/* Reveal supplementary info on hover OR focus */
.card .extra-info { visibility: hidden; }

@media (hover: hover) and (pointer: fine) {
  .card:is(:hover, :focus-within) .extra-info {
    visibility: visible;
  }
}

/* On touch devices, show the info by default */
@media (hover: none) {
  .card .extra-info { visibility: visible; }
}
```

### Enlarge Touch Targets for Coarse Pointers

Design touch-friendly as the default. Only *enlarge* for `pointer: coarse` — never shrink for `pointer: fine`. Fitts's Law applies regardless of input device.

```css
@media (pointer: coarse) {
  button, a {
    min-height: 48px;
  }

  input[type="checkbox"],
  input[type="radio"] {
    width: 1.625rem;
    height: 1.625rem;
  }
}
```

### `any-pointer` and `any-hover`

The primary `pointer`/`hover` queries test only the primary input device. The `any-pointer` and `any-hover` variants test **all available** input devices — useful for detecting mixed setups like a laptop with touchscreen:

```css
/* Device has fine pointer AND coarse pointer (e.g. laptop with touchscreen) */
@media (pointer: fine) and (any-pointer: coarse) {
  button {
    min-height: 48px; /* User might switch to touch */
  }
}
```

**Caveats:** These queries are hints, not guarantees. The W3C spec intentionally leaves "primary pointer" determination to the browser. Known inconsistencies:
- iOS Safari always reports `pointer: coarse`, even with an external mouse or trackpad connected
- Some Android devices report `pointer: fine` due to virtual mouse drivers
- Convertible laptops may switch primary pointer when a keyboard is detached or attached

**Never hide critical content or functionality behind hover interactions.** Treat these queries as progressive enhancement — the baseline experience must work without hover.

## Handle Device Safe Areas

Modern devices have hardware features that obscure screen edges — notches, Dynamic Islands, rounded corners, camera cutouts, home indicators, gesture navigation bars. Use `env(safe-area-inset-*)` (Baseline 2020) to keep interactive content visible.

### Enable Edge-to-Edge Layout

By default, the browser insets the viewport to avoid obstructions, and all `env()` values are `0px`. To take control yourself, opt in with `viewport-fit=cover`:

```html
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
```

This lets backgrounds and decorative content bleed to the screen edge while you position interactive content within the safe area using CSS.

### The `max()` Pattern

The most robust approach — ensures at least your design's minimum padding, but accommodates larger safe area insets when present:

```css
.content {
  padding-left: max(1rem, env(safe-area-inset-left));
  padding-right: max(1rem, env(safe-area-inset-right));
}
```

In portrait on a non-notched device, `safe-area-inset-left` is `0px`, so `max()` resolves to `1rem`. In landscape on a notched iPhone, the inset may be 47px, so `max()` uses that instead.

### Fixed Bottom Navigation

Bottom-fixed elements are the most common safe area issue — the home indicator or gesture bar sits directly on top of them.

```css
/* Background extends behind home indicator; content is padded above it */
.bottom-nav {
  position: fixed;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 0.75rem max(0.5rem, env(safe-area-inset-right))
           calc(0.75rem + env(safe-area-inset-bottom, 0px))
           max(0.5rem, env(safe-area-inset-left));
}
```

### Fixed Top Header

```css
.top-header {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  padding: calc(0.75rem + env(safe-area-inset-top, 0px))
           max(1rem, env(safe-area-inset-right))
           0.75rem
           max(1rem, env(safe-area-inset-left));
}
```

### Guidelines

- **Apply to specific elements** (fixed headers, bottom bars, main content) — not globally on `body`. Global padding wastes screen space and prevents full-bleed backgrounds.
- **Handle landscape orientation.** When a notched phone rotates, the notch moves to a side — `safe-area-inset-left` or `safe-area-inset-right` becomes significant. The `max()` pattern handles this automatically.
- **Provide fallback values:** `env(safe-area-inset-bottom, 0px)` — the second argument is the fallback for browsers or devices with no insets.
- **Avoid double-insetting.** Apply safe area padding at one level only — not on both a wrapper and its child.
- **On Chrome Android**, prefer `bottom` positioning over `padding-bottom` for dynamic insets — the value changes during scroll as the gesture bar retracts, and padding changes trigger layout recalculation.

## Use Relative Units for Accessible, Scalable Layouts

Avoid `px` for font sizes - it overrides the user's browser font size preference.

**When to use which unit:**
- **rem** - Block-level sizing (font-size, margin, padding). Relative to root font size. Use for headings: `font-size: 2.5rem`
- **em** - Inline/contextual sizing. Scales with parent. Use for icon sizing: `width: 0.75em; height: 0.75em`
- **ch** - Line length (measure). `max-inline-size: 65ch`
- **%** and **fr** - Flexible layouts. Grid tracks, flex-basis
- **vw/vh** - Viewport-relative. Use sparingly with `calc()`: `font-size: calc(1rem + 0.5vw)`
- **px** - Only for borders, shadows, and fine details that shouldn't scale

**Scale the entire interface proportionally:**
```css
@media (min-width: 960px) {
  :root { font-size: 125%; }
}
```
All `rem`-based values scale automatically.

## Chapter Summary

1. Group related elements using containers, proximity, similarity, or continuity — don't default to cards when spacing or background tints suffice
2. Create clear visual hierarchy using size, colour, contrast, spacing, position, depth
3. Interfaces = rectangles within rectangles with margin, padding, border (box model)
4. Create predefined spacing options in 8pt increments; space based on relationship
5. Align to 12-column grid; avoid multiple different alignments
6. Use logical properties (`margin-inline-start`) instead of physical properties (`margin-left`)
7. Use contextual spacing (Stack pattern with `* + *`) - style relationships, not individual elements
8. Prefer intrinsic responsive patterns (flex-wrap, minmax) over @media breakpoints
9. Use responsive images (`srcset`, `sizes`, `loading="lazy"`) and prevent layout shift with `aspect-ratio`
10. Use container queries for component-level responsiveness; media queries for page-level layout
11. Use subgrid to align nested content across sibling elements
12. Use `pointer`/`hover` media queries to adapt interaction to input method — never hide content behind hover
13. Use `env(safe-area-inset-*)` with `viewport-fit=cover` for notches, home indicators, and gesture bars
14. Use relative units (rem, em, ch) for accessible, scalable layouts
