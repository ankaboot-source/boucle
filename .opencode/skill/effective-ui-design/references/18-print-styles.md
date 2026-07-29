# Print Styles

Ensure web pages produce clean, readable output when printed on paper or saved as PDF.

## @media print Basics

Print styles let you override screen styles for paged media. They apply when the user triggers Print or Save as PDF.

### Embedding Strategies

**Inline in the main stylesheet (preferred):**

Avoids an extra HTTP request and keeps print rules co-located with the screen rules they override.

```css
/* Inside your main stylesheet */
@media print {
  /* print-only rules */
}
```

**Separate file via `<link>`:**

Useful when the print stylesheet is large or maintained by a different team.

```html
<link rel="stylesheet" href="print.css" media="print">
```

The browser downloads `print.css` at low priority and only applies it when printing, so it does not block rendering.

Source: [MDN: Printing](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Media_queries/Printing), [Smashing Magazine: Print Stylesheets in 2018](https://www.smashingmagazine.com/2018/05/print-stylesheets-in-2018/)

### Hiding Non-Essential Elements

Interactive and navigational elements serve no purpose on paper. Hide them with `display: none`.

```css
@media print {
  nav,
  footer,
  aside,
  .sidebar,
  .ads,
  .cookie-banner,
  .share-buttons,
  button,
  .no-print,
  video,
  audio,
  iframe,
  form,
  .modal,
  .tooltip {
    display: none !important;
  }
}
```

### Blacklist vs Whitelist Approach

**Blacklist:** List every element to hide. Simple but fragile -- new elements added to the page need explicit hiding.

**Whitelist:** Hide everything by default, then show only the main content area. More robust for complex pages.

```css
/* Whitelist approach */
@media print {
  body > *:not(main) {
    display: none !important;
  }
}
```

The blacklist approach is more common because it is easier to reason about. The whitelist approach is safer for large sites where the page structure changes frequently.

Source: [CSS-Tricks: Print Stylesheet Approaches -- Blacklist vs Whitelist](https://css-tricks.com/print-stylesheet-approaches-blacklist-vs-whitelist/)

## @page Rule

The `@page` at-rule controls page dimensions, margins, and orientation for paged media.

### Margins

```css
@page {
  margin: 2cm;
}

/* Different margins per side */
@page {
  margin-top: 2.5cm;
  margin-bottom: 2.5cm;
  margin-left: 2cm;
  margin-right: 2cm;
}
```

A `2cm` margin is a safe default that leaves room for printer hardware margins while giving content enough space.

### Page Size and Orientation

The `size` descriptor accepts named sizes and/or an orientation keyword.

```css
@page {
  size: A4;              /* A4 portrait (default) */
}

@page {
  size: A4 landscape;    /* A4 landscape */
}

@page {
  size: letter;          /* US Letter: 8.5in x 11in */
}

@page {
  size: 210mm 297mm;     /* Explicit dimensions */
}
```

Named size keywords: `A3`, `A4`, `A5`, `B4`, `B5`, `letter`, `legal`, `ledger`.

### Pseudo-Class Selectors

```css
@page :first {
  margin-top: 4cm;       /* Extra top margin on first page for title */
}

@page :left {
  margin-left: 3cm;      /* Wider inner margin for binding */
  margin-right: 2cm;
}

@page :right {
  margin-left: 2cm;
  margin-right: 3cm;
}

@page :blank {
  /* Style intentionally blank pages */
}
```

### Named Pages

Named pages allow different configurations per content type.

```css
@page cover {
  margin: 0;
  size: A4 landscape;
}

@page chapter {
  margin: 2.5cm;
  size: A4;
}

.cover-page {
  page: cover;
}

.chapter-content {
  page: chapter;
}
```

### Margin Boxes (Chromium)

Chromium supports margin at-rules (`@top-center`, `@bottom-center`, `@bottom-right`, etc.) for inserting headers, footers, and page numbers into the page margins.

```css
@page {
  @top-center {
    content: "Document Title";
  }
  @bottom-right {
    content: counter(page) " of " counter(pages);
  }
}
```

**Browser support:** `margin`, `size`, and `page-orientation` work in all major browsers. Margin at-rules and named pages are Chromium-only as of early 2026.

Source: [MDN: @page](https://developer.mozilla.org/en-US/docs/Web/CSS/@page), [MDN: @page/size](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@page/size), [Chrome Developers: Print Margins](https://developer.chrome.com/blog/print-margins)

## Page Breaks

### Modern Properties vs Legacy Properties

The legacy properties `page-break-before`, `page-break-after`, and `page-break-inside` have been replaced by `break-before`, `break-after`, and `break-inside`. The modern properties also handle column and region breaks. For maximum compatibility, declare both.

```css
@media print {
  /* Force a page break before every h1 */
  h1 {
    page-break-before: always;   /* Legacy */
    break-before: page;          /* Modern */
  }

  /* Avoid breaking inside figures, tables, code blocks */
  figure,
  table,
  pre,
  blockquote,
  img {
    page-break-inside: avoid;    /* Legacy */
    break-inside: avoid;         /* Modern */
  }

  /* Avoid a page break immediately after headings */
  h1, h2, h3, h4, h5, h6 {
    page-break-after: avoid;     /* Legacy */
    break-after: avoid;          /* Modern */
  }
}
```

### Orphans and Widows

Orphans are lines left at the bottom of a page before a break. Widows are lines stranded at the top of the next page. Both default to 2 in most browsers. Set them higher for better readability.

```css
@media print {
  p {
    orphans: 3;    /* Minimum 3 lines before a page break */
    widows: 3;     /* Minimum 3 lines after a page break */
  }
}
```

### Practical Combinations

```css
@media print {
  /* Keep headings with their following content */
  h1, h2, h3, h4 {
    break-after: avoid;
    page-break-after: avoid;
  }

  /* Start major sections on new pages */
  .chapter,
  .section-break {
    break-before: page;
    page-break-before: always;
  }

  /* Never split these across pages */
  table, figure, pre, blockquote, ul, ol {
    break-inside: avoid;
    page-break-inside: avoid;
  }
}
```

**Note on Flexbox/Grid:** Fragmentation (page breaks) is poorly supported inside flex and grid containers. Keep print layouts in simple block flow for reliable results.

Source: [MDN: page-break-before](https://developer.mozilla.org/en-US/docs/Web/CSS/page-break-before), [MDN: break-inside](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/break-inside), [CSS-Tricks: page-break](https://css-tricks.com/almanac/properties/p/page-break/), [Quirksmode: widows and orphans](https://quirksmode.org/css/css2/widows.html)

## Typography for Print

### Serif Fonts

On paper, serif typefaces (Georgia, Times New Roman, Garamond) are traditionally more readable for body text. The serifs guide the eye along the baseline on a printed page where resolution is high (300+ DPI), unlike screens where sans-serif tends to be clearer at low resolution.

### Point-Based Sizing

Print media uses points (pt), not pixels. 1pt = 1/72 inch. Standard body text is 12pt.

```css
@media print {
  body {
    font-family: Georgia, "Times New Roman", serif;
    font-size: 12pt;
    line-height: 1.5;
    color: #000;
  }

  h1 { font-size: 24pt; line-height: 1.2; }
  h2 { font-size: 20pt; line-height: 1.3; }
  h3 { font-size: 16pt; line-height: 1.3; }
  h4 { font-size: 14pt; line-height: 1.4; }
}
```

### Line Height

Use unitless values for `line-height`. Minimum 1.5 for body text (consistent with WCAG SC 1.4.12). Decrease for headings (1.2-1.3). Increase for very long lines.

Source: [SitePoint: Printer-friendly Pages with CSS](https://www.sitepoint.com/css-printer-friendly-pages/), [Jotform: The Perfect Print Stylesheet](https://www.jotform.com/blog/css-perfect-print-stylesheet-98272/)

## Showing URLs After Links

On paper, hyperlinks are useless without visible URLs. Use `::after` to append the href value.

### Basic Technique

```css
@media print {
  a[href]::after {
    content: " (" attr(href) ")";
    font-size: 90%;
    word-break: break-all;
  }
}
```

### Filtering: Only External Links

Internal anchors, `javascript:` links, `mailto:` links, and `tel:` links should not print their href.

```css
@media print {
  /* Only show URLs for absolute HTTP links */
  a[href^="http"]::after,
  a[href^="//"]::after {
    content: " (" attr(href) ")";
    font-size: 90%;
    word-break: break-all;
  }

  /* Suppress for internal, mailto, tel, and JavaScript links */
  a[href^="#"]::after,
  a[href^="mailto:"]::after,
  a[href^="tel:"]::after,
  a[href^="javascript:"]::after {
    content: none;
  }
}
```

### Abbreviation Expansion

The same technique works for `<abbr>` elements so readers see the full term on paper.

```css
@media print {
  abbr[title]::after {
    content: " (" attr(title) ")";
  }
}
```

### Handling Long URLs

Long URLs can break layouts. Use `overflow-wrap` and `word-break` to allow wrapping.

```css
@media print {
  a[href^="http"]::after {
    content: " (" attr(href) ")";
    overflow-wrap: break-word;
    word-break: break-all;
  }
}
```

Source: [CSS-Tricks: Print URL After Links](https://css-tricks.com/snippets/css/print-url-after-links/), [Hamatti: Display Full URL After Link](https://hamatti.org/posts/display-full-url-after-link-when-page-is-printed/), [CSS-Tricks: Handling Long Words and URLs](https://css-tricks.com/snippets/css/prevent-long-urls-from-breaking-out-of-container/)

## Colour Adjustments

### Removing Backgrounds

Browsers strip background colours and images by default when printing to save ink. Design with this in mind.

```css
@media print {
  * {
    background: transparent !important;
    color: #000 !important;
    box-shadow: none !important;
    text-shadow: none !important;
  }
}
```

The aggressive `*` selector above comes from the HTML5 Boilerplate. A more targeted approach is preferable when some backgrounds carry meaning (table header shading, status badges, syntax highlighting).

### print-color-adjust: exact

When colours are meaningful, use `print-color-adjust: exact` to request that the browser preserves them.

```css
@media print {
  .status-badge,
  .chart,
  .syntax-highlight {
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;  /* Safari */
  }
}
```

**Values:**
- `economy` (default) -- browser may remove backgrounds and adjust colours to optimise for paper
- `exact` -- content has been specifically designed with colours that matter; preserve them

The user can always override this via the "Background graphics" checkbox in the print dialog. No CSS can override a user preference.

### forced-color-adjust

Related but distinct: `forced-color-adjust` controls whether elements are affected by forced colours mode (Windows High Contrast). Set `forced-color-adjust: none` on elements where colour is essential to meaning (charts, heatmaps), but use sparingly.

```css
.heatmap-cell {
  forced-color-adjust: none;
}
```

### Link Styling for Print

Remove coloured underlines and make links black text so they blend with body copy while remaining identifiable.

```css
@media print {
  a, a:visited {
    color: #000;
    text-decoration: underline;
  }
}
```

Source: [MDN: print-color-adjust](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/print-color-adjust), [CSS-Tricks: print-color-adjust](https://css-tricks.com/almanac/properties/p/print-color-adjust/)

## Image Handling

### Prevent Overflow

Images must not exceed the printable area.

```css
@media print {
  img {
    max-width: 100% !important;
    height: auto;
    break-inside: avoid;
    page-break-inside: avoid;
  }
}
```

### Background Images Are Stripped

Browsers remove `background-image` by default when printing. Do not rely on CSS background images for meaningful content. If a background image is essential, use `print-color-adjust: exact`, but understand users may still override this. Use `<img>` elements for content images.

### Responsive Images in Print

When printing, browsers select from `srcset` based on device pixel ratio, not viewport width. This means the browser may select a small image variant. For critical print content, ensure the `src` fallback points to a sufficiently high-resolution source.

### Decorative Image Hiding

Hide purely decorative images to save ink.

```css
@media print {
  .decorative-image,
  [role="presentation"] {
    display: none;
  }
}
```

### Constrain Image Size

Prevent oversized images from wasting ink and paper.

```css
@media print {
  img {
    max-width: 100%;
    max-height: 3.5in;
  }
}
```

Source: [Smashing Magazine: Print Stylesheets in 2018](https://www.smashingmagazine.com/2018/05/print-stylesheets-in-2018/), [SitePoint: Printer-friendly Pages with CSS](https://www.sitepoint.com/css-printer-friendly-pages/)

## Common Elements to Hide

| Element / Selector | Reason |
|---|---|
| `nav` | Navigation is useless on paper |
| `footer` (site footer) | Social links, secondary nav irrelevant |
| `aside`, `.sidebar` | Supplementary content distracts from main content |
| `button`, `input[type="submit"]` | Interactive -- no function on paper |
| `form` | Cannot submit from paper |
| `video`, `audio`, `iframe` | Cannot play media on paper |
| `.cookie-banner`, `.modal` | Overlay UI irrelevant |
| `.share-buttons`, `.social-links` | Interactive sharing impossible |
| `.ads`, `.advertisement` | No value on paper, wastes ink |
| `.back-to-top` | No scrolling on paper |
| `.search-bar`, `[role="search"]` | No search on paper |
| `.pagination` | Page navigation irrelevant |
| `.tooltip`, `.popover` | Hover-dependent UI |
| `.skip-link` | Keyboard navigation aid, not needed on paper |
| `.breadcrumb` (optional) | May keep for context, or hide to save space |

### Print-Only Content

Some content is useful on paper but hidden on screen.

```css
.print-only {
  display: none;
}

@media print {
  .print-only {
    display: block;
  }
}
```

**Use cases:** QR codes linking back to the page, "Printed from [URL]" attribution, expanded table of contents, legal disclaimers.

Source: [CSS-Tricks: Blacklist vs Whitelist](https://css-tricks.com/print-stylesheet-approaches-blacklist-vs-whitelist/), [Manuel Matuzovic: I Totally Forgot About Print Style Sheets](https://www.matuzo.at/blog/i-totally-forgot-about-print-style-sheets/)

## Layout Adjustments

### Linearise to Single Column

Multi-column grid and flex layouts should collapse to a single column for reliable printing. Fragmentation inside flex and grid containers is unreliable across browsers.

```css
@media print {
  body {
    width: 100%;
    margin: 0;
    padding: 0;
  }

  main {
    width: 100%;
    max-width: none;
    margin: 0;
    padding: 0;
    float: none;
  }

  .grid-layout {
    display: block;
  }
}
```

### Full-Width Content

Remove `max-width` constraints so text fills the printable area.

```css
@media print {
  .container,
  .wrapper,
  .content {
    max-width: 100%;
    width: 100%;
    padding: 0;
    margin: 0;
  }
}
```

### Table Printing

Wide tables are problematic on paper. Ensure header rows repeat on each page and rows do not split.

```css
@media print {
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 10pt;
  }

  thead {
    display: table-header-group;  /* Repeat header on each page */
  }

  tfoot {
    display: table-footer-group;
  }

  tr {
    break-inside: avoid;
    page-break-inside: avoid;
  }
}
```

Source: [Smashing Magazine: Print Stylesheets in 2018](https://www.smashingmagazine.com/2018/05/print-stylesheets-in-2018/), [SitePoint: Printer-friendly Pages with CSS](https://www.sitepoint.com/css-printer-friendly-pages/)

## When Print Styles Matter Most

Print styles are especially important for content that people routinely print or save as PDF:

- **Articles and blog posts** -- long-form content printed for offline reading or annotation
- **Recipes** -- commonly printed for kitchen use
- **Invoices and receipts** -- business documents printed for records
- **Documentation and manuals** -- technical docs, API references, user guides
- **Legal documents** -- terms, contracts, policies
- **Academic content** -- research papers, course materials
- **Real estate listings** -- property details printed for viewings
- **Contact pages** -- addresses, phone numbers, directions
- **Event tickets and confirmations** -- booking confirmations, itineraries
- **Government forms** -- applications, declarations
- **Maps and directions** -- still printed despite mobile devices

Even if analytics suggest few users print, the ones who do expect a usable result. A broken print layout reflects poorly on the site.

Source: [Manuel Matuzovic: I Totally Forgot About Print Style Sheets](https://www.matuzo.at/blog/i-totally-forgot-about-print-style-sheets/), [618media: Designing for Print with CSS Tips](https://618media.com/en/blog/designing-for-print-with-css-tips/)

## Complete Starter Print Stylesheet

Copy-paste this into your main stylesheet as a starting point. Adjust selectors to match your markup.

```css
@media print {
  /* ---- Page setup ---- */
  @page {
    margin: 2cm;
    size: A4;
  }

  @page :first {
    margin-top: 3cm;
  }

  /* ---- Reset colours ---- */
  body {
    background: #fff;
    color: #000;
    font-family: Georgia, "Times New Roman", serif;
    font-size: 12pt;
    line-height: 1.5;
  }

  /* ---- Hide non-print elements ---- */
  nav,
  footer,
  aside,
  .sidebar,
  .ads,
  .cookie-banner,
  .share-buttons,
  .pagination,
  .back-to-top,
  .skip-link,
  button:not(.print-visible),
  video,
  audio,
  iframe,
  form,
  .modal,
  .tooltip,
  .no-print {
    display: none !important;
  }

  /* ---- Show print-only content ---- */
  .print-only {
    display: block !important;
  }

  /* ---- Links: show URLs ---- */
  a[href^="http"]::after,
  a[href^="//"]::after {
    content: " (" attr(href) ")";
    font-size: 90%;
    word-break: break-all;
  }

  a[href^="#"]::after,
  a[href^="mailto:"]::after,
  a[href^="tel:"]::after,
  a[href^="javascript:"]::after {
    content: none;
  }

  /* ---- Abbreviations: show expansion ---- */
  abbr[title]::after {
    content: " (" attr(title) ")";
  }

  /* ---- Link styling ---- */
  a, a:visited {
    color: #000;
    text-decoration: underline;
  }

  /* ---- Remove decorative effects ---- */
  * {
    box-shadow: none !important;
    text-shadow: none !important;
  }

  /* ---- Images ---- */
  img {
    max-width: 100% !important;
    height: auto;
    break-inside: avoid;
    page-break-inside: avoid;
  }

  /* ---- Page breaks ---- */
  h1, h2, h3, h4, h5, h6 {
    break-after: avoid;
    page-break-after: avoid;
  }

  figure, table, pre, blockquote, ul, ol {
    break-inside: avoid;
    page-break-inside: avoid;
  }

  p {
    orphans: 3;
    widows: 3;
  }

  /* ---- Tables ---- */
  table {
    width: 100%;
    border-collapse: collapse;
  }

  thead {
    display: table-header-group;
  }

  tr {
    break-inside: avoid;
    page-break-inside: avoid;
  }

  /* ---- Layout: linearise ---- */
  body, main, .container, .wrapper, .content {
    width: 100%;
    max-width: none;
    margin: 0;
    padding: 0;
    float: none;
  }

  /* ---- Preserve meaningful colours ---- */
  .status-badge,
  .chart,
  .syntax-highlight {
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;
  }
}
```

## Common Print Style Mistakes

### Mistake 1: Forgetting print styles entirely
The most common problem. Developers test on screen and never open Print Preview. Add print style testing to your QA checklist.

### Mistake 2: Not testing across browsers
Print rendering varies significantly between Chrome, Firefox, and Safari. Test in at least Chrome and Firefox. Safari handles page breaks differently.

### Mistake 3: Using Flexbox or Grid for print layouts
Fragmentation (page breaks) is unreliable inside flex and grid containers. Switch to `display: block` for print.

### Mistake 4: Long URLs breaking layouts
Appending `attr(href)` without `overflow-wrap: break-word` or `word-break: break-all` lets long URLs overflow the page and push content off the right edge.

### Mistake 5: Relying on background images for content
Background images are stripped by default. Use `<img>` for meaningful images, reserve `background-image` for decoration.

### Mistake 6: External font dependencies failing
Web fonts may not load during print. Always provide system font fallbacks in your `font-family` stack.

### Mistake 7: Ignoring orphans and widows
The default of 2 lines is too few. A single line stranded at the top of a page looks unprofessional. Set `orphans: 3` and `widows: 3`.

### Mistake 8: Not hiding interactive elements
Buttons, forms, modals, and video embeds printed on paper waste space and confuse users.

### Mistake 9: Printing navigation and ads
Navigation, sidebars, and advertisements waste paper, ink, and reader attention. Always hide them.

### Mistake 10: Not linearising multi-column layouts
Columns that work on screen can produce bizarre results on paper -- content split across pages in an unreadable order. Collapse to a single column.

Source: [PixelFreeStudio: Print Styles Gone Wrong](https://blog.pixelfreestudio.com/print-styles-gone-wrong-avoiding-pitfalls-in-media-print-css/), [Smashing Magazine: Print Stylesheets in 2018](https://www.smashingmagazine.com/2018/05/print-stylesheets-in-2018/)

## Chapter Summary

1. Add `@media print` rules inline in your main stylesheet to override screen styles for paged media
2. Use `@page` to set margins (2cm default), page size (A4 or letter), and orientation
3. Declare both legacy `page-break-*` and modern `break-*` properties for maximum browser compatibility
4. Set `orphans: 3` and `widows: 3` on paragraphs to avoid stranded lines across page breaks
5. Switch to a serif font at 12pt with 1.5 line-height for printed body text
6. Show URLs after external links using `a[href^="http"]::after { content: " (" attr(href) ")"; }` and filter out internal, mailto, and tel links
7. Remove backgrounds, box-shadows, and text-shadows; use `print-color-adjust: exact` only where colour carries meaning
8. Constrain images with `max-width: 100%` and `break-inside: avoid`; hide decorative images to save ink
9. Hide navigation, footers, sidebars, ads, buttons, forms, modals, and media embeds
10. Linearise layouts to single-column block flow -- flex and grid fragmentation is unreliable across browsers
11. Use `display: table-header-group` on `<thead>` so table headers repeat on each printed page
12. Test print output in Chrome and Firefox Print Preview as part of your regular QA process
