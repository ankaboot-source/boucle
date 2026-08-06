# Internationalisation and RTL

Build interfaces that work across languages, scripts, and reading directions.

## Set Text Direction with the HTML `dir` Attribute

The `dir` attribute is a global HTML attribute that sets the base text direction for element content. Always use HTML `dir` rather than the CSS `direction` property for structural text direction -- CSS can be disabled, and content must still read correctly.

### Three values

| Value | Behaviour |
|-------|-----------|
| `ltr` | Left-to-right. English, French, German, etc. |
| `rtl` | Right-to-left. Arabic, Hebrew, Persian, Urdu, etc. |
| `auto` | Browser runs the first-strong algorithm: parses characters until it finds one with strong directionality, then applies that direction to the whole element. |

Use `auto` for user-generated content or database-sourced strings where direction is unknown.

### Inheritance

`dir` is inherited by all child elements. Setting `dir="rtl"` on `<html>` changes the entire page. Override on specific blocks when needed.

```html
<!-- Set document-wide direction -->
<html lang="ar" dir="rtl">

<!-- Override direction for a specific block -->
<blockquote dir="ltr" lang="en">
  English quote inside an Arabic page.
</blockquote>

<!-- User-generated content — let the browser decide -->
<p dir="auto"><bdi>{{ user_input }}</bdi></p>
```

Flexbox and Grid layouts respond to `dir` automatically -- setting `dir="rtl"` reverses flex row order and grid placement with no extra CSS.

*Source: MDN dir attribute, W3C Internationalisation, rtlstyling.com (Ahmad Shadeed)*

## Use the CSS `:dir()` Pseudo-Class

`:dir()` matches the computed directionality of an element, including inherited direction. The `[dir="rtl"]` attribute selector only matches elements with an explicit `dir` attribute set.

```css
/* Matches resolved direction — even when inherited */
:dir(rtl) .sidebar { border-inline-start: 3px solid var(--accent); }
:dir(ltr) .sidebar { border-inline-start: 3px solid var(--accent); }
```

An element with `dir="auto"` will match `:dir(ltr)` or `:dir(rtl)` based on content analysis.

**Browser support:** Chrome 120+, Firefox 49+, Safari 16.4+. Use `[dir="rtl"]` as a fallback when supporting older browsers.

*Source: MDN :dir() pseudo-class, caniuse.com/css-dir-pseudo*

## Extend Logical Properties Beyond the Basics

Core logical property mappings for margin, padding, width, and height are covered in **04-layout-spacing.md** (section "Use Logical Properties"). The following mappings extend that foundation for full RTL support:

### Positioning

```css
/* Physical → Logical */
left    → inset-inline-start
right   → inset-inline-end
top     → inset-block-start
bottom  → inset-block-end
```

### Border radius

```css
border-top-left-radius     → border-start-start-radius
border-top-right-radius    → border-start-end-radius
border-bottom-left-radius  → border-end-start-radius
border-bottom-right-radius → border-end-end-radius
```

### Text alignment, floats, and overflow

```css
text-align: left   → text-align: start
text-align: right  → text-align: end

float: left   → float: inline-start
float: right  → float: inline-end

overflow-x → overflow-inline
overflow-y → overflow-block
```

### Borders

```css
border-left   → border-inline-start
border-right  → border-inline-end
border-top    → border-block-start
border-bottom → border-block-end
```

Modern browsers default `text-align` to `start` rather than `left`, but setting `text-align: start` explicitly in stylesheets makes the intent clear.

Flexbox and Grid are already logical. `flex-direction: row` flows left-to-right in LTR and right-to-left in RTL. CSS `gap` also flips accordingly. No additional work is needed for basic flex/grid layouts.

*Source: SitePoint CSS Logical Properties Guide, Ishadeed Digging Into CSS Logical Properties, web.dev Internationalisation*

## Mirror Layout for RTL

### What flips

- **Overall page layout** -- navigation moves to the right, content reading order reverses
- **Directional icons** -- arrows, back/forward buttons, breadcrumb chevrons, progress indicators, undo/redo
- **Time-related direction** -- in RTL, "forward" in timelines points left, "backward" points right
- **Scrollbars** -- move to the left side
- **Form layouts** -- labels, inputs, and buttons flip positioning
- **Lists** -- bullet/number position moves to the right side
- **Tab icons** -- move from left-of-label to right-of-label

### What does NOT flip

- **Media playback controls** -- play/pause/stop/skip always stay LTR (they represent tape direction, not reading direction)
- **Logos and trademarks** -- never mirror, but do move position (e.g. upper-left to upper-right)
- **Checkmarks** -- universal symbol, do not flip
- **Clocks** -- always rotate clockwise
- **Right-handed object icons** -- search magnifier, pen, coffee mug, scissors stay oriented for right-hand use
- **Phone numbers and URLs** -- always displayed LTR even in RTL context
- **Music notation** -- always LTR
- **Graphs and charts with numeric axes** -- x-axis typically stays LTR

### CSS for icon mirroring

```css
/* Mirror directional icons in RTL */
[dir="rtl"] .icon-directional,
:dir(rtl) .icon-directional {
  transform: scaleX(-1);
}
```

Audit every icon in the project and classify as directional (must flip) or non-directional (must not flip). Apply a utility class like `.icon-directional` only to the icons that should mirror.

*Source: Material Design 3 Bidirectionality, Material Design 1 Bidirectionality, rtlstyling.com, Firefox RTL Guidelines*

## Design for Text Expansion

Translated text is often longer than the English source. Short strings expand the most.

### IBM expansion guidelines by source string length

| English string length | Expected expansion |
|----------------------|--------------------|
| 1-10 characters | 100-200% |
| 11-20 characters | 80-100% |
| 21-30 characters | 60-80% |
| 31-50 characters | 40-60% |
| 51-70 characters | 31-40% |
| Over 70 characters | ~30% |

### Expansion by target language (from English)

| Language | Typical expansion |
|----------|-------------------|
| German | 25-35% |
| Finnish | 25-35% |
| Spanish | 20-25% |
| Arabic | 20-25% |
| French | 15-20% |
| Italian | 15-20% |
| Russian | 15-25% |
| Chinese/Japanese/Korean | Contracts in character count but needs larger font size for legibility |

### CSS patterns for flexible containers

```css
/* Flexible button that accommodates expansion */
.button {
  display: inline-flex;
  padding-inline: 1rem;
  min-inline-size: 6rem;     /* minimum, not fixed */
  white-space: nowrap;
}

/* Flexible navigation that wraps */
.nav-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}
```

**Rules:**
- Plan for 200% expansion in buttons and short labels
- Never use fixed-width containers for translated text -- use `min-inline-size` instead of `inline-size`
- Use `flex-wrap: wrap` on toolbar and button groups
- Avoid truncation as the default strategy -- design for flexible containers first
- CJK text may contract in character count but requires 1-2px larger font sizes, so vertical expansion still occurs
- Test with pseudo-localisation to reveal layout breakage before real translations arrive

*Source: W3C Text size in translation, IBM Text translation design for user interfaces*

## Handle Bidirectional Text

Browsers run the Unicode Bidirectional Algorithm (UBA) automatically. Each character has a directional type: strong (letters), weak (numbers), or neutral (punctuation, spaces). Problems occur when neutral characters appear between characters of different directions.

### The `<bdi>` element

```html
<!-- User-generated content with unknown direction -->
<p>User <bdi>إيمان</bdi> posted 3 comments.</p>
```

`<bdi>` (Bidirectional Isolate) isolates its content from the surrounding bidirectional text. The browser applies `unicode-bidi: isolate` to it by default. Use `<bdi>` when:
- Displaying user-generated content where direction is unknown
- Showing usernames, search terms, or database values within a sentence
- Mixing numbers with RTL text

`<bdi>` does not inherit the parent `dir` -- it isolates its content directionally.

### The `<bdo>` element

```html
<!-- Force direction override — rare, mostly educational -->
<bdo dir="rtl">This text is forced right-to-left</bdo>
```

`<bdo>` (Bidirectional Override) overrides the algorithm entirely. Rarely needed in production.

### CSS `unicode-bidi` values

| Value | Effect |
|-------|--------|
| `normal` | Default. No extra embedding. |
| `embed` | Opens an embedding level (like `<span dir="rtl">`) |
| `isolate` | Isolates content from surrounding bidi context (like `<bdi>`) |
| `bidi-override` | Forces all characters to the specified direction (like `<bdo>`) |
| `isolate-override` | Combines isolation with override |
| `plaintext` | Determines direction from content, ignoring parent direction |

The W3C recommends: use HTML markup to manage bidirectional text rather than CSS or Unicode control characters where markup is available.

### Unicode directional marks

When markup is not possible (plain text attributes like `title`, `placeholder`), use invisible Unicode characters:

| Character | Code point | Use |
|-----------|-----------|-----|
| Left-to-right mark (LRM) | U+200E / `&lrm;` | Force LTR context around neutral characters |
| Right-to-left mark (RLM) | U+200F / `&rlm;` | Force RTL context around neutral characters |

In an RTL context, a phone number like "+1 (555) 123-4567" may display with misplaced parentheses. Inserting LRM characters around the number fixes positioning.

*Source: W3C Inline markup and bidirectional text, MDN bdi element, MDN unicode-bidi*

## Format Numbers and Dates with `Intl`

Never hardcode date or number formats. The `Intl` namespace is built into all modern browsers (zero bundle cost) and handles locale-specific formatting.

### `Intl.NumberFormat`

```js
// Currency
new Intl.NumberFormat('de-DE', {
  style: 'currency', currency: 'EUR'
}).format(1234.5);
// → "1.234,50 €"

new Intl.NumberFormat('ja-JP', {
  style: 'currency', currency: 'JPY'
}).format(1234);
// → "￥1,234"

// Percentage with Eastern Arabic numerals
new Intl.NumberFormat('ar-EG', {
  style: 'percent'
}).format(0.25);
// → "٢٥٪"

// Compact notation
new Intl.NumberFormat('en', {
  notation: 'compact', compactDisplay: 'short'
}).format(1500);
// → "1.5K"
```

### `Intl.DateTimeFormat`

```js
const date = new Date('2026-02-10');

new Intl.DateTimeFormat('de-DE', { dateStyle: 'long' }).format(date);
// → "10. Februar 2026"

new Intl.DateTimeFormat('ar-SA', { dateStyle: 'full' }).format(date);
// → Uses Hijri calendar by default

new Intl.DateTimeFormat('ja-JP', {
  year: 'numeric', month: 'long', day: 'numeric'
}).format(date);
// → "2026年2月10日"
```

### `Intl.RelativeTimeFormat`

```js
const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
rtf.format(-1, 'day');    // → "yesterday"
rtf.format(3, 'hour');    // → "in 3 hours"

const rtfAr = new Intl.RelativeTimeFormat('ar', { numeric: 'auto' });
rtfAr.format(-1, 'day');  // → "أمس"
```

### `Intl.ListFormat`

```js
new Intl.ListFormat('en', {
  style: 'long', type: 'conjunction'
}).format(['Alice', 'Bob', 'Charlie']);
// → "Alice, Bob, and Charlie"

new Intl.ListFormat('de', {
  style: 'long', type: 'conjunction'
}).format(['Alice', 'Bob', 'Charlie']);
// → "Alice, Bob und Charlie"
```

### `Intl.PluralRules`

```js
// English has 2 plural forms: one, other
const pr = new Intl.PluralRules('en-US');
pr.select(0);  // → "other"  → "0 items"
pr.select(1);  // → "one"    → "1 item"
pr.select(2);  // → "other"  → "2 items"

// Arabic has 6 plural forms: zero, one, two, few, many, other
const prAr = new Intl.PluralRules('ar');
prAr.select(0);   // → "zero"
prAr.select(1);   // → "one"
prAr.select(2);   // → "two"
prAr.select(3);   // → "few"
prAr.select(11);  // → "many"
prAr.select(100); // → "other"
```

*Source: MDN Intl, MDN Intl.DateTimeFormat, MDN Intl.RelativeTimeFormat*

## Choose Fonts for Each Script

Different scripts require different typefaces. Define per-script font stacks from the start of a project.

### System font stacks by script

```css
/* Latin (base) */
font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;

/* Arabic */
font-family: 'Noto Sans Arabic', 'Segoe UI', Tahoma, sans-serif;

/* CJK — Chinese Simplified */
font-family: 'Noto Sans SC', 'PingFang SC', 'Microsoft YaHei', sans-serif;

/* CJK — Japanese */
font-family: 'Noto Sans JP', 'Hiragino Sans', 'Yu Gothic', 'Meiryo', sans-serif;

/* CJK — Korean */
font-family: 'Noto Sans KR', 'Apple SD Gothic Neo', 'Malgun Gothic', sans-serif;

/* Devanagari (Hindi) */
font-family: 'Noto Sans Devanagari', 'Mangal', sans-serif;

/* Thai */
font-family: 'Noto Sans Thai', 'Leelawadee UI', Tahoma, sans-serif;
```

### Per-script font assignment with `:lang()`

```css
:lang(ar) {
  font-family: 'Noto Sans Arabic', Tahoma, sans-serif;
  line-height: 1.8;  /* Arabic diacritics need more vertical space */
}

:lang(ja) {
  font-family: 'Noto Sans JP', 'Hiragino Sans', sans-serif;
  font-size: 1.05em;  /* CJK often needs slightly larger size */
}

:lang(zh-Hans) {
  font-family: 'Noto Sans SC', 'PingFang SC', sans-serif;
}
```

### Load only needed subsets with `unicode-range`

```css
@font-face {
  font-family: 'Noto Sans Arabic';
  src: url('NotoSansArabic.woff2') format('woff2');
  unicode-range: U+0600-06FF, U+0750-077F, U+FB50-FDFF, U+FE70-FEFF;
  font-display: swap;
}
```

The browser only downloads the font file when characters in the specified range appear on the page.

### Arabic typography

- **Line height:** Arabic diacritics (kasra, fatha, damma) are clipped with tight `line-height`. Use `line-height: 1.7` or higher for Arabic text.
- **Underlines:** `text-decoration: underline` cuts through Arabic letter descenders. Use `text-underline-offset` or custom underlines with `box-shadow`.
- **Separate typeface:** Brands often use different typefaces for Latin and Arabic scripts. Define both in project font settings from the start.

Google's Noto font family covers 1,000+ languages and 150+ writing systems. Ship WOFF2 files with `font-display: swap` and use `size-adjust` to harmonise metrics between Latin and script-specific families.

*Source: Noto Fonts documentation, rtlstyling.com, Makitsol web-safe fonts guide*

## Account for Cultural Differences

### Colour symbolism varies by culture

| Colour | Western | East Asia | Middle East |
|--------|---------|-----------|-------------|
| Red | Danger, error, stop | Luck, prosperity (China) | Danger, caution |
| White | Purity, weddings | Death, mourning (China, Korea) | Purity |
| Green | Success, nature | -- | Islam, paradise |
| Yellow | Caution, happiness | Imperial (China) | Happiness |
| Black | Mourning, formality | -- | Death, evil |
| Blue | Trust, calm | Immortality (China) | Safety, heaven |

Never rely on colour alone to convey meaning -- this is already a WCAG requirement. Always pair colour with text labels, icons, or patterns.

### Icons and symbols that vary

- **Thumbs-up** -- positive in Western cultures, offensive in parts of West Africa and the Middle East
- **Checkmark** -- "correct" in Western countries, can mean "wrong" in parts of Japan and Scandinavia
- **Mailbox icon** -- physical mailboxes look different in every country; use an envelope icon instead
- **OK hand gesture** -- offensive in Brazil, Turkey, and other regions
- **Animals** -- owls represent wisdom in the West but bad luck in some Asian cultures; dogs are considered unclean in some Islamic contexts

Prefer abstract or universally recognised icons. Avoid culturally specific metaphors.

### Date format differences

| Region | Format | Example (10 Feb 2026) |
|--------|--------|----------------------|
| US | MM/DD/YYYY | 02/10/2026 |
| Europe, most of world | DD/MM/YYYY | 10/02/2026 |
| Japan, China, Korea | YYYY/MM/DD | 2026/02/10 |
| ISO 8601 | YYYY-MM-DD | 2026-02-10 |

When displaying dates in a locale-ambiguous context, spell out the month: "10 Feb 2026".

### Other format variations

- **Phone numbers:** Formatting varies widely. Use a library like `libphonenumber` rather than regex patterns.
- **Addresses:** Field order varies -- in Japan, zip code comes first, then prefecture, city, district. Do not hardcode US-style address forms.
- **Names:** Not all cultures use first name / last name. Some use single names, patronymics, or family-name-first order.
- **Currency position:** Some locales place the symbol before the number ($10), others after (10 EUR). Use `Intl.NumberFormat`.

*Source: POEditor colour symbolism, cieden icon perception across cultures, MIT Internationalisation*

## Common Mistakes

| Mistake | Why it fails | Correct approach |
|---------|-------------|------------------|
| Using `margin-left`/`padding-right` | Physical properties do not adapt to direction | Use `margin-inline-start`/`padding-inline-end` |
| Using CSS `direction` instead of HTML `dir` | CSS can be disabled; structural direction belongs in markup | Set `dir="rtl"` on `<html>` or appropriate element |
| Flipping media playback icons | Play/pause represent tape direction, not reading direction | Keep media controls in original orientation |
| Flipping logos | Brand identity should not be mirrored | Move position (left to right) without mirroring the image |
| Fixed-width containers for text | Translations expand, breaking layouts | Use `min-inline-size`, `flex-wrap`, flexible containers |
| Hardcoded number formatting | Different locales use different separators (1,234.56 vs 1.234,56) | Use `Intl.NumberFormat` |
| Hardcoded date format strings | 10/02 means October 2 (US) or 10 February (Europe) | Use `Intl.DateTimeFormat` |
| Ignoring Arabic diacritics in line-height | Diacritics get clipped, making text unreadable | Use `line-height: 1.7` or higher for Arabic |
| Using `text-align: left` | Does not adapt to RTL | Use `text-align: start` |
| Using `float: left`/`float: right` | Physical properties do not flip | Use `float: inline-start`/`float: inline-end` |
| Not wrapping dynamic content in `<bdi>` | User-generated text can break surrounding bidi context | Wrap unknown-direction content in `<bdi>` |
| Using `text-decoration: underline` with Arabic | Underline cuts through descenders | Use `text-underline-offset` or custom underline |

*Source: rtlstyling.com, DEV Community, Mozilla Hacks*

## Test RTL Support

### Quick browser testing

1. **DevTools attribute edit:** Open Elements panel, find `<html>`, add `dir="rtl"`. The entire layout should flip. Any element that does not flip reveals a physical CSS property.
2. **Chrome Sensors panel:** DevTools > More tools > Sensors. Override the locale to an RTL language (e.g. `ar`) to test how `Intl` APIs and browser defaults behave.
3. **Firefox:** Has long-standing RTL support in DevTools and native `:dir()` support.

### Pseudo-localisation

Pseudo-localisation transforms English text into accented, expanded versions to reveal layout issues before real translations arrive.

```
"Submit"  →  "[Šüƀɱîţ______]"
"Save"    →  "[Šåṽé______]"
```

Benefits:
- **Accented characters** reveal hard-coded strings (they will not be accented)
- **Text expansion** simulates 30-50% growth to expose layout breakage
- **Brackets** around strings reveal concatenation issues
- **RTL simulation** flips text direction

```js
import { pseudoLocalize } from 'pseudo-localization';
pseudoLocalize('Hello world'); // → "Ħḗŀŀǿ ẇǿřŀḓ"
```

### RTL testing checklist

- Page layout mirrors correctly when `dir="rtl"` is set on `<html>`
- Flexbox and grid containers reverse as expected
- All padding/margin/border uses logical properties
- Directional icons (arrows, chevrons) are mirrored
- Non-directional icons (play, logo, checkmark) are NOT mirrored
- Text alignment follows reading direction (`text-align: start`)
- Scrollbar appears on the correct side
- Breadcrumb arrows point in the correct direction
- Form field order and label positions flip correctly
- Numbers and dates display using `Intl` formatters
- User-generated content wrapped in `<bdi>` renders correctly
- No text truncation from translation expansion
- Arabic text has sufficient line-height (no clipped diacritics)
- Phone numbers and URLs remain LTR within RTL context
- `lang` and `dir` attributes are set correctly on `<html>`

*Source: BrowserStack Internationalisation Testing, pseudo-localization (GitHub)*

## Chapter Summary

1. Set text direction with HTML `dir` (not CSS `direction`) -- use `ltr`, `rtl`, or `auto` for user-generated content
2. Use CSS logical properties for all spacing, positioning, borders, border-radius, floats, and text alignment (see also 04-layout-spacing.md)
3. Mirror page layout and directional icons for RTL but never flip media controls, logos, checkmarks, or clocks
4. Design flexible containers that accommodate 100-200% text expansion for short strings and 30% for longer content
5. Wrap user-generated content of unknown direction in `<bdi>` elements to isolate bidirectional text
6. Format all numbers, dates, and lists with the `Intl` API -- never hardcode locale-specific formats
7. Define per-script font stacks using `:lang()` selectors and load only needed subsets with `unicode-range`
8. Set Arabic line-height to 1.7 or higher to prevent clipped diacritics
9. Never rely on colour alone to convey meaning -- colour symbolism varies across cultures
10. Prefer abstract, universally recognised icons over culturally specific metaphors
11. Test RTL by adding `dir="rtl"` to `<html>` in DevTools and use pseudo-localisation to catch layout issues before translation
12. Audit every icon as directional (flip with `scaleX(-1)`) or non-directional (never flip)
