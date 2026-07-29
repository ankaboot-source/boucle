# Typography

Learn a system of logical guidelines to make text beautiful and easy to read.

## Typeface Classifications

**Serif** - Decorative tails/feet at ends of letters. Traditional, classic, formal mood. Some legible at small sizes, others better for large.

**Sans Serif** - No decorative tails. Modern, simple. Highly legible at all sizes. Safe, neutral option for most interfaces.

**Script** - Based on handwriting. Low legibility - not suitable for small sizes. Can convey formal or casual mood at large sizes.

**Display** - Wide range of decorative styles. Designed for large sizes only. Strong character, good for conveying different moods.

**Monospaced** - Every character takes same horizontal space. Good for code and numbers (easier to compare).

## Use a Single Sans Serif Typeface

Safest for most interface designs.

### Reasons

**1. Legibility**
- Sans serif most legible
- Main purpose of interface text: clearly communicate information
- If not legible = harder to read, understand, use

**2. Neutrality**
- Don't convey strong mood/personality
- Fits most brand personalities
- Content is focal point, not typeface
- Less chance of unsuitable choice

**3. Simplicity**
- Less character and detail
- Complicated typefaces = distracting, increased cognitive load
- Less is more with typography

### Choosing Functional Text Typefaces

For UI/functional text (labels, captions, navigation, data), prioritise:
- Open, distinct letterforms — capital I, lowercase l, and number 1 must be easily distinguishable
- Large x-height for legibility at small sizes (but not so large that n and h become hard to tell apart)
- Generous default letterspacing — don't compensate with `letter-spacing`; choose a correctly designed font
- Sturdy weights — avoid light weights for UI text; thin strokes blur or dissolve at small sizes
- Look for typefaces designed for signage or interfaces (e.g. Fira Sans, Source Sans, Roboto, Inter)

## Evoke Emotion Using a Second Typeface for Headings

As you get more confident, try second typeface for HEADINGS ONLY.

**Typeface Moods:**
- **Sans serif** - neutral, minimal, modern
- **Serif** - traditional, established, classic
- **Rounded sans serif** - fun, soft, playful
- **Casual script** - personal, handmade
- **Formal script** - formal, feminine, elegant
- **Light sans serif** - chic, modern, luxurious

### Combining Typefaces

Limit to 2-3 typefaces maximum. Every typeface must serve a clear, distinct purpose (body, display, functional).

**How to find good pairings:**
1. **Start with an anchor** — choose your body text typeface first, then find companions that complement it
2. **Match underlying structure** — pair typefaces with similar skeletons (e.g. both rational, both dynamic) but different expression
3. **Use contrast for distinction** — pair serif with sans-serif, or light with heavy, to create clear hierarchy
4. **Check similar metrics** — look for comparable x-heights, cap heights, and overall colour (density)
5. **Try superfamilies first** — families with serif + sans-serif siblings (e.g. Questa Sans + Questa Serif) are guaranteed to harmonise
6. **Consider same designer** — type designers leave personal stylistic thumbprints across their work

**Avoid:** Pairing typefaces that are too similar (e.g. two geometric sans-serifs) — they create uncomfortable "almost the same" tension without clear distinction.

### Workhorses vs Personalities

**Workhorses** (Helvetica, Futura, Proxima Nova) are versatile but need skill to make distinctive. Look to display styles within their superfamily for variety.

**Personalities** (typefaces with strong inherent character) do most of the work for you but suit fewer contexts. Favour personalities for display text — they make it easier to create distinctive designs.

## Tips for Choosing a Sans Serif Typeface

- Choose popular, tried and tested typefaces
- Look for variety of weights (light, regular, medium, semibold, bold)
- Look for taller lowercase letters (x-height) and greater letter spacing = more legible at small sizes
- Get inspiration from companies known for good design
- Ensure multi-language support if needed
- Look for OpenType features
- When in doubt, use default system typeface

## Normalize Font Sizes with font-size-adjust

Different fonts at the same `font-size` can appear vastly different in visual size due to varying x-heights (the height of lowercase letters). `font-size-adjust` normalizes this.

**Use cases:**
- **Fallback fonts:** Prevent layout shift when web fonts load
- **Mixing fonts:** Make a serif heading font and sans-serif body font work together with one type scale

```css
/* The value is the x-height ratio (x-height / font-size) */
body {
  font-family: "Custom Font", Arial, sans-serif;
  font-size-adjust: 0.5;  /* Normalize based on x-height */
}
```

**How to find the value:**
1. Measure your primary font's x-height ratio
2. Apply it - fallback fonts will scale to match visually

**Browser support:** ~90% (Chrome 127+, Firefox 118+, Safari 17+)

## Limit Font Weights and Ensure Clear Distinction

Don't use all available weights - adds noise and clutter. More importantly: avoid weights that are too similar to distinguish.

**Problematic combinations (too close together):**
- Light vs Thin
- Book vs Regular
- Semibold vs Bold

**Guidelines:**
- Typically 2, max 3 weights with clear visual distinction
- Common useful set: Regular (400), Medium (500), Bold (700)
- Very thin or thick weights - headings/large text only (difficult at small sizes)
- Each weight should serve a clear purpose in your hierarchy

## Use a Type Scale to Set Font Sizes

Logical way to create balanced font sizes that work together.

### How to Create

1. Start with base font size (body text)
2. Multiply by scale factor for larger sizes

### Popular Type Scales (smallest to largest)
- 1.067 – Minor Second
- 1.125 – Major Second
- 1.200 – Minor Third
- 1.250 – Major Third
- 1.333 – Perfect Fourth
- 1.414 – Augmented Fourth
- 1.500 – Perfect Fifth
- 1.618 – Golden Ratio

### Example (1.200 Minor Third, base 16px)
```
Heading 1: 40px / 48px line-height / bold
Heading 2: 32px / 40px line-height / bold
Heading 3: 24px / 32px line-height / bold
Heading 4: 20px / 28px line-height / bold
Body:      16px / 24px line-height / regular
Small:     14px / 20px line-height / regular
```

**Tips:**
- Round to nearest whole number
- Try to make line-heights divisible by 4 (aligns to 4pt grid)
- Adjust as needed once confident

### Small vs Large Type Scales

**Small scales (e.g., Major Second):**
- Less difference between sizes
- Better for complex apps, tools, dashboards

**Large scales (e.g., Perfect Fifth):**
- Larger differences between sizes
- Better for simpler interfaces, marketing sites

### Responsive Type Scales

Instead of just scaling individual font sizes, scale the **type scale ratio itself** based on viewport width:

| Viewport | Scale Ratio | H1 | H2 | H3 | Body |
|----------|-------------|----|----|-----|------|
| 320px | 1.2 (Minor Third) | 35px | 29px | 24px | 17px |
| 1024px | (interpolated) | 50px | 39px | 31px | 19px |
| 1500px | 1.33 (Perfect Fourth) | 63px | 47px | 36px | 20px |

**Why this works:**
- Headings can be dramatically larger on desktop (63px H1) without being too big on mobile (35px)
- The hierarchy stays proportional at all sizes
- Smooth fluid interpolation - no breakpoint jumps

### Fluid Typography with clamp()

Use `clamp()` for font sizes that scale smoothly:

```css
/* clamp(minimum, preferred, maximum) */
h1 {
  font-size: clamp(35px, 5vw + 1rem, 63px);
}

h2 {
  font-size: clamp(29px, 4vw + 0.5rem, 47px);
}

.prose {
  font-size: clamp(17px, 1.5vw + 0.5rem, 20px);
}
```

**Benefits:**
- No hard jumps at breakpoints
- Smooth scaling between screen sizes
- Headings get proportionally bigger with more space

**Note:** For UI elements like buttons and labels, fixed sizes (14px) often work better for consistency.

## Distinguish UI Text from Body Text

**UI text** (buttons, labels, navigation, table cells) and **body text** (articles, descriptions, long-form content) have different requirements.

### UI Text: 14px is Fine

For compact UI components, 14px works well and is common practice (Tailwind's base size):

- Buttons, labels, navigation items
- Table cells, form labels, badges
- Sidebar content, metadata

14px keeps UI components compact - important when combined with padding.

### Body Text: Scale Responsively

For long-form reading content, don't leave text hard at 16px - scale it:

- **Mobile (360-440px):** 16-18px — scales across phone viewports
- **Desktop (640px+):** 16-20px — scales with viewport; smaller screens (11-13") stay closer to 16px

```css
.prose {
  font-size: clamp(1rem, 0.4rem + 2.5vw, 1.125rem);        /* 16→18px across 360–440px */
}

@media (min-width: 640px) {
  .prose {
    font-size: clamp(1.125rem, 0.95rem + 0.25vw, 1.25rem);  /* 18→20px across 1120–1920px */
  }
}
```

### Input Fields: 16px Minimum on Mobile

iOS Safari auto-zooms inputs below 16px. See Forms chapter for details.

The key insight: avoid *both* tiny text that strains eyes *and* oversized text that wastes mobile screen space.

## Use at Least 1.5 Line Height for Long Body Text

**Line height** = vertical distance between two lines of text.

**For accessibility and readability:**
- Minimum 1.5 (150%) for body text
- Keep between 1.5 and 2

**Benefits:**
- Prevents rereading same line
- More comfortable to read

**Tips:**
- Longer lines = taller line height
- Darker/heavier typefaces = taller line height
- Typefaces that look larger = taller line height

### Always Use Unitless line-height Values

Use unitless values (e.g. `1.5`) instead of units (e.g. `24px` or `1.5em`):

```css
/* Good - child elements compute their own line-height */
body { line-height: 1.5; }

/* Bad - computed value (e.g. 24px) is inherited, not the ratio */
body { line-height: 1.5em; }
```

With unitless values, a child element with `font-size: 32px` will compute `line-height: 48px` (32 × 1.5). With `1.5em`, it inherits the parent's computed `24px`, causing lines to overlap.

## Set Paragraph Spacing to 1.5x Line Height

The gap between paragraphs should be noticeably larger than the gap between lines within a paragraph. A reliable rule: set paragraph spacing (margin) to 1.5 times the line spacing.

```css
p {
  line-height: 1.5;          /* 24px at 16px font-size */
  margin-block-start: 0;
  margin-block-end: 1.5em;   /* ~36px = 1.5 × 24px */
}
```

This creates a clear visual break between paragraphs while keeping the text block cohesive. Keep paragraphs to roughly 5 lines max for comfortable reading.

## Decrease Line Height as Font Size Increases

Large text doesn't need 1.5 line height.

**Reason:** Line height is relative to font size - same percentage creates larger actual gap on bigger text.

**Example:**
- Heading at 24px with 1.6 line height = large gap
- Change to 1.3 line height for consistent gap

## Ensure Ideal Line Length

**Optimal:** 40-80 characters per line (including spaces)

**Too long:**
- Hard to gauge where line starts/ends
- Eyes get lost tracking back

**Too short:**
- Eyes stressed from frequent travel back

**Guidelines:**
- Don't use full page width for text
- Align text block to left or centre of page
- Especially important for long body text

### Use ch Units for Line Length

The `ch` unit equals the width of the "0" character in the current font. This makes the 40-80 character guideline directly implementable:

```css
.prose {
  max-width: 65ch;  /* ~65 characters per line */
}
```

This automatically adapts to different font sizes and typefaces.

## Left Align Text

English read left to right, downwards in F-pattern.

**Left-aligned = easiest to read:**
- Each line starts at same left edge
- Consistent anchor for eyes

### Don't Centre Align Long Body Text
- Starting point changes each line
- Eyes work harder to find start
- OK for headings and short text

### Don't Justify Without Hyphenation

Plain justified text creates uneven word spacing and "rivers" of white space. If you must justify:

```css
.justified-prose {
  text-align: justify;
  hyphens: auto;                   /* 97% support — set lang attribute on <html> */
  hyphenate-limit-chars: 6 3 2;    /* Min 6 chars, 3 before break, 2 after */
}
```

**Fine-grained hyphenation controls** (`hyphenate-limit-lines`, `hyphenate-limit-zone`, `hyphenate-limit-last`) have limited browser support (~80%, no Safari). Use them as progressive enhancement:

```css
.justified-prose {
  /* Progressive enhancement — ignored by browsers that don't support them */
  hyphenate-limit-lines: 2;
  hyphenate-limit-zone: 8%;
  hyphenate-limit-last: always;
}
```

**When justification can work:** Long-form content with generous measure (60+ characters), combined with hyphenation. Still not recommended for short lines or narrow columns.

**When to avoid entirely:** Short text, narrow columns, dyslexia-sensitive contexts. Left-aligned text is always the safer default.

### Avoid Multiple Text Alignments
Harder to follow, looks messy.

## Kerning and Letter Spacing

### Enable Kerning

Kerning adjusts spacing between specific character pairs (e.g. AV, To, Wa). Always enable it:

```css
body {
  font-kerning: normal;  /* Enable OpenType kerning */
}
```

### Letter Spacing (Tracking) Guidelines

**Decrease for large, bold, or wide text:**
```css
.display-heading {
  letter-spacing: -0.02em;  /* Tighten large/bold text ~2-3% */
}
```

**Increase for ALL CAPS and long digit strings:**
```css
.uppercase-label {
  text-transform: uppercase;
  letter-spacing: 0.05em;  /* Open up ~5% for caps */
}
```

**Turn off ligatures when letterspacing:**
```css
.spaced-text {
  letter-spacing: 0.05em;
  font-variant-ligatures: no-common-ligatures;  /* Ligatures look wrong when spaced */
}
```

**Never letterspace lowercase** body text without good cause — it damages word shapes and reduces readability.

## Use OpenType Features for Polished Typography

Modern fonts contain advanced features that improve readability and professional appearance. Use CSS `font-variant` and `font-feature-settings` to activate them.

### Small Caps

Use for abbreviations and words set in uppercase inside body text so they blend in better. Always use real small caps - never fake them by scaling down capitals.

```css
/* Real small caps */
.abbreviation {
  font-variant-caps: all-small-caps;
  font-feature-settings: "c2sc", "smcp";
}
```

Fake small caps (scaled-down capitals) have thinner strokes and look out of place next to regular text.

### Figure Styles

Figure styles split into two groups:

**Old-style vs Lining figures:**
- **Old-style figures** have varying heights (some descend below baseline) - better for body text as they blend in
- **Lining figures** are all the same height - better for headings and UI elements

```css
.body-text { font-variant-numeric: oldstyle-nums; }
.ui-numbers { font-variant-numeric: lining-nums; }
```

**Proportional vs Tabular figures:**
- **Proportional figures** have varying widths (natural spacing) - good for running text
- **Tabular figures** all take the same horizontal space - essential for tables, prices, and anywhere numbers need to align vertically

```css
.price-table { font-variant-numeric: tabular-nums; }
.prose       { font-variant-numeric: proportional-nums; }
```

### Ligatures

**Common ligatures** (fi, fl, ff, ffl, ffi) improve legibility in body text. Enabled by default in most browsers - don't disable them.

**Discretionary ligatures** are more ornamental. Use sparingly and only for decorative headings:
```css
.decorative-heading {
  font-variant-ligatures: discretionary-ligatures;
  font-feature-settings: "dlig";
}
```

### Proper Punctuation and Typographic Marks

Use the correct typographic marks:
- **Hyphen** (-) connects words: "five-dollar"
- **En dash** (\u2013) replaces "to": "6\u20135 p.m."
- **Em dash** (\u2014) indicates a break in thought: "Why is typography important?\u200A\u2014\u200AIt can also be used as an indicator of a break."
- **Curly quotation marks** (\u201c \u201d \u2018 \u2019) for prose - straight marks (' ") are for code only

**Additional typographic marks:**
- **Proper minus** (`&minus;` / −) for negative numbers — not a hyphen
- **Proper ellipsis** (`&hellip;` / …) — one character, not three dots
- **Multiplication** (`&times;` / ×) — not the letter x
- **Non-breaking space** (`&nbsp;`) — between values and units (100 km), initials (J. K. Rowling), and between last two words of headings (prevents widows)
- **Thin space** (`&thinsp;`) — between nested quotation marks and around em dashes

## Prevent Faux Bold and Italic

Browsers synthesise bold/italic when the required font file isn't loaded. Faux bold smears outlines; faux italic mechanically slants the roman. Both look wrong.

```css
/* Prevent browser synthesis - only use real font files */
@font-face {
  font-family: 'MyFont';
  src: url('myfont-regular.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
}

/* If you don't have an italic, explicitly prevent synthesis */
.no-synthesis {
  font-synthesis: none;
}
```

**Always ensure you have font files for every weight and style you use.** If you specify `font-weight: bold` but only loaded the regular weight, the browser will fake it.

## Table Typography

Tables are text to be read — apply typographic care.

**Number formatting:**
- Use **tabular lining numerals** in data tables (equal-width digits that align vertically)
- **Right-align numbers** so decimal points and digit places line up
- **Left-align text** columns
- Align column headings with their data (right-align headers above number columns)

**Reduce visual clutter:**
- Minimise borders, fills, and rules — use white space to separate rows and columns
- Alternating row colours are rarely needed if spacing is adequate
- Horizontal rules between rows are often sufficient; vertical rules almost never needed

```css
.data-table {
  font-variant-numeric: tabular-nums lining-nums;
  border-collapse: collapse;
}

.data-table td.number {
  text-align: right;
  font-variant-numeric: tabular-nums lining-nums;
}
```

## Display Text and Headlines

### Sizing Display Text

For display text that scales with the viewport, use `vmin` units for consistent sizing across portrait and landscape orientations:

```css
.hero-heading {
  font-size: clamp(2rem, 8vmin, 5rem);
}
```

### Optical Sizing

Different sizes of text benefit from different font characteristics. Enable automatic optical sizing when available:

```css
body {
  font-optical-sizing: auto;  /* Browser adjusts for rendered size */
}
```

At small sizes: increased x-height, wider spacing, thicker strokes for legibility. At large sizes: finer details, tighter spacing, higher contrast for elegance.

### Hanging Punctuation for Display Text

For large quoted text, pull punctuation into the margin so the text edge aligns visually. The CSS `hanging-punctuation` property exists but only Safari supports it (~14%). Use a negative `text-indent` instead:

```css
blockquote.display {
  text-indent: -0.4em;  /* Hang opening quote mark — works everywhere */
}
```

### Drop Caps

Use `initial-letter` for drop caps (~91% support, no Firefox). Provide a fallback for unsupported browsers:

```css
.article > p:first-of-type::first-letter {
  /* Fallback for browsers without initial-letter */
  float: left;
  font-size: 3.2em;
  line-height: 0.8;
  margin-right: 0.1em;
  font-weight: bold;
}

@supports (initial-letter: 3) {
  .article > p:first-of-type::first-letter {
    float: none;
    font-size: inherit;
    line-height: inherit;
    initial-letter: 3;  /* Span 3 lines */
  }
}
```

### Prevent Widows in Headings

A single word on the last line of a heading looks orphaned. Use CSS `text-wrap: balance` (~87% support) for headings and `text-wrap: pretty` (~78% support) for paragraphs:

```css
h1, h2, h3, h4, h5, h6 {
  text-wrap: balance;  /* Equalises line lengths in headings */
}

p {
  text-wrap: pretty;   /* Avoids orphan words on last line */
}
```

For browsers without support, these properties degrade gracefully to normal wrapping. As an additional safeguard, insert `&nbsp;` between the last two words of critical headings.

## Vertical Rhythm

Use the body text line-height as the fundamental spacing unit. All vertical spacing — paragraph margins, heading spacing, padding — should be multiples of this base unit.

```css
:root {
  --baseline: 1.5rem;  /* 24px if root is 16px */
}

h2 { margin-block: calc(var(--baseline) * 2) var(--baseline); }
h3 { margin-block: calc(var(--baseline) * 1.5) calc(var(--baseline) * 0.5); }
p  { margin-block: 0 var(--baseline); }
```

This creates a predictable, harmonious rhythm throughout the page. Embedded media (images, videos) may break the rhythm — that's acceptable; resume the rhythm after.

## Ensure Text on Photos is Legible

Common mistake: placing text directly on photos.

**Contrast requirements:**
- Small text (≤18px): 4.5:1 minimum
- Large text (>18px bold OR >24px regular): 3:1 minimum

### Solutions

**Linear gradient overlay:**
- Dark grey, 90% opacity at bottom, 0% halfway up
- Add text shadow

**Semi-transparent overlay:**
- Dark grey, 50% opacity over entire photo
- Add text shadow

**Blurred semi-transparent overlay:**
- Add blur effect for easier reading

**Solid text background:**
- Popular for video captions
- White text on dark grey background

## Avoid Light Grey and Pure Black Text

**Light grey text:**
- Accessibility issue - many can't read or find difficult
- Always aim for 4.5:1 contrast minimum

**Pure black text:**
- Too high contrast causes eye strain and fatigue
- Black: 0% brightness, White: 100%
- Large difference makes eyes work harder
- Use accessible dark grey instead

## Chapter Summary

1. Limit font weights: typically 2, max 3 (e.g. Regular 400, Medium 500, Bold 700) in a single sans serif typeface
2. Use type scale to create predefined font sizes that work together
3. Use 1.5+ line height (unitless values) for long body text; decrease line height as font size increases
4. Ensure 40-80 characters per line for readability
5. Left align text for optimal readability (F-pattern); only justify with hyphenation
6. Enable kerning; tighten large text, open up ALL CAPS; turn off ligatures when letterspacing
7. Use OpenType features: real small caps, tabular figures for data, common ligatures, proper typographic marks
8. Prevent faux bold/italic — load all needed font weights and styles; use `font-synthesis: none`
9. Apply vertical rhythm — use body line-height as base spacing unit
10. Combine typefaces with purpose: match structure, contrast expression, limit to 2-3 families
