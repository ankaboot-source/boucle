# Tables and Data Display

Design accessible, well-structured data tables that work across screen sizes and assistive technologies.

## Semantic HTML Table Structure

Use native HTML table elements for tabular data. Semantic markup gives screen readers a navigable grid where users move cell-by-cell with header context announced automatically.

### Required Elements

```html
<table>
  <caption>Quarterly revenue by region, 2024</caption>

  <thead>
    <tr>
      <th scope="col">Region</th>
      <th scope="col">Q1</th>
      <th scope="col">Q2</th>
      <th scope="col">Q3</th>
      <th scope="col">Q4</th>
    </tr>
  </thead>

  <tbody>
    <tr>
      <th scope="row">North America</th>
      <td>$1.2M</td>
      <td>$1.4M</td>
      <td>$1.1M</td>
      <td>$1.6M</td>
    </tr>
  </tbody>

  <tfoot>
    <tr>
      <th scope="row">Total</th>
      <td>$3.8M</td>
      <td>$4.2M</td>
      <td>$3.9M</td>
      <td>$5.1M</td>
    </tr>
  </tfoot>
</table>
```

**Element roles:**
- `<caption>` -- acts as the table's heading; screen readers announce it when entering the table, helping users decide if the data is relevant (W3C WAI Tables Tutorial)
- `<thead>` -- groups header rows; enables sticky positioning and print-repeat behaviour
- `<tbody>` -- groups body data; multiple `<tbody>` elements can section a long table
- `<tfoot>` -- groups summary/total rows; browsers render it at the bottom regardless of source order
- `<th>` -- header cells; must always have a `scope` attribute
- `<td>` -- data cells

Source: MDN `<table>` element reference; W3C WAI Tables Tutorial (w3.org/WAI/tutorials/tables/)

### The `scope` Attribute

Always set `scope` on every `<th>`. While screen readers can often guess header direction, explicit scope removes ambiguity.

```html
<!-- Column header -->
<th scope="col">Price</th>

<!-- Row header -->
<th scope="row">Widget A</th>

<!-- Header spanning a group of columns -->
<th scope="colgroup" colspan="2">Membership Dates</th>

<!-- Header spanning a group of rows -->
<th scope="rowgroup" rowspan="3">Electronics</th>
```

Source: MDN table accessibility; W3C WAI Tables Tutorial; WebAIM data tables guide

### Complex Tables with `headers` and `id`

When a table has multi-level headers (nested column groups, irregular spans), `scope` alone is insufficient. Use explicit `id`/`headers` associations:

```html
<thead>
  <tr>
    <th id="name" scope="col" rowspan="2">Name</th>
    <th id="dates" scope="colgroup" colspan="2">Membership Dates</th>
  </tr>
  <tr>
    <th id="joined" scope="col">Joined</th>
    <th id="canceled" scope="col">Canceled</th>
  </tr>
</thead>

<tbody>
  <tr>
    <th id="margaret" scope="row">Margaret Nguyen</th>
    <td headers="dates joined margaret">June 3, 2010</td>
    <td headers="dates canceled margaret">n/a</td>
  </tr>
</tbody>
```

**Guidance:** Prefer simpler tables. If you need `id`/`headers`, consider whether the table can be split into multiple simpler tables instead.

Source: MDN `<table>` element; W3C WAI irregular headers tutorial

### `<colgroup>` and `<col>`

Use `<colgroup>` to style entire columns without repeating classes on every cell:

```html
<table>
  <caption>Sales by quarter</caption>
  <colgroup>
    <col><!-- Region column -->
    <col span="4" class="quarterly-data">
  </colgroup>
  <!-- ... -->
</table>
```

Useful for applying background colours to the sorted column or striping columns in comparison tables.

### Content Order

The permitted child order inside `<table>` is:

1. `<caption>` (optional, must be first)
2. `<colgroup>` elements (zero or more)
3. `<thead>` (optional)
4. `<tbody>` elements (one or more), or `<tr>` elements directly
5. `<tfoot>` (optional)

Source: MDN `<table>` element reference

## Accessibility

### Screen Reader Table Navigation

Screen readers provide dedicated table navigation commands. In JAWS and NVDA, users press Ctrl+Alt+Arrow keys to move between cells; the reader announces the corresponding row/column headers automatically. This only works when tables use proper semantic markup.

**What screen readers announce on entering a table:**
- The caption text
- Number of rows and columns
- Current cell position

Source: W3C WAI Tables Tutorial; Adrian Roselli responsive accessible table article

### Caption Is Not Optional

The `<caption>` element is the accessible name for the table. Without it, screen reader users encounter an unlabelled data structure. Even sighted users benefit from a clear heading above the table.

```html
<!-- Good: descriptive caption -->
<caption>Employee headcount by department, January 2025</caption>

<!-- Bad: vague or missing -->
<caption>Table 1</caption>
```

If you must visually hide the caption, use a CSS visually-hidden class rather than `display: none` (which hides it from screen readers too):

```css
caption.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}
```

Source: W3C WAI Caption & Summary tutorial; W3C WCAG technique H39

### Sortable Column Accessibility

Sortable tables need careful ARIA implementation. The W3C ARIA Authoring Practices Guide provides the reference pattern.

**HTML structure -- button inside `<th>`:**

```html
<th scope="col" aria-sort="ascending">
  <button type="button">
    Name
    <span aria-hidden="true">&#x25B2;</span><!-- visual arrow -->
  </button>
</th>

<th scope="col">
  <button type="button">
    Date
    <span aria-hidden="true">&#x25C7;</span><!-- unsorted indicator -->
  </button>
</th>
```

**Key rules:**
- Use `<button>` elements (not links) as sort triggers inside `<th>` cells
- Apply `aria-sort="ascending"` or `aria-sort="descending"` only to the currently sorted column
- Remove `aria-sort` from previously sorted columns entirely (do not use `aria-sort="none"`)
- Apply `aria-hidden="true"` and `focusable="false"` to sort direction icons (SVG or character entities)
- Use shape changes (not just colour) for sort direction to satisfy WCAG 1.4.1 Use of Colour

**Screen reader announcements:**
- JAWS and NVDA announce "sorted ascending" or "sorted descending" when navigating to a header with `aria-sort`
- VoiceOver (macOS) and TalkBack may not announce sort changes without additional markup

**Live region for sort feedback:**

```html
<div aria-live="polite" class="visually-hidden" id="sort-status"></div>
```

After sorting, update the text content: "Sorted by name, ascending". Clear after approximately one second to avoid stale announcements.

Source: W3C WAI ARIA APG sortable table example; Adrian Roselli "Sortable Table Columns" (2021); Deque University sortable table library

### Scrollable Table Containers

When a table overflows its container (common on mobile), the scroll container must be keyboard accessible.

```html
<div class="table-container"
     role="region"
     aria-labelledby="caption-id"
     tabindex="0">
  <table>
    <caption id="caption-id">Order history</caption>
    <!-- ... -->
  </table>
</div>
```

**Requirements:**
- `role="region"` identifies the scrollable area as a landmark
- `aria-labelledby` links to the caption so the region has a name
- `tabindex="0"` makes the container focusable for keyboard scrolling
- Provide a visible focus indicator on the container

```css
.table-container:focus-visible {
  outline: 3px solid var(--focus-color);
  outline-offset: 2px;
}
```

Source: Adrian Roselli "A Responsive Accessible Table"; Deque axe rule scrollable-region-focusable; Accessibility Insights documentation

### Expandable Rows

Use the disclosure pattern for tables with expandable detail rows:

```html
<tr>
  <td>
    <button type="button"
            aria-expanded="false"
            aria-controls="detail-row-1">
      Show details
    </button>
  </td>
  <td>Category name</td>
</tr>

<tr id="detail-row-1" class="hidden">
  <td colspan="2">Expanded content here</td>
</tr>
```

**Critical CSS:** Use `display: table-row` (not `display: block`) when showing rows, or the browser drops table semantics:

```css
tr.hidden { display: none; }
tr.shown  { display: table-row; }
```

Source: Adrian Roselli "Table with Expando Rows" (2019)

### Do Not Use ARIA Table Roles as a Substitute for Semantic HTML

The first rule of ARIA: do not use ARIA if native HTML can achieve the same result. Building a "table" from `<div>` elements with `role="table"`, `role="row"`, `role="cell"` is a last resort, not a best practice.

Source: W3C ARIA in HTML specification; ADG "table of divs" experiment

## Responsive Patterns

### Pattern 1: Horizontal Scroll Container

The simplest approach. Preserves full table structure; users scroll sideways on narrow screens.

```css
.table-container {
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}
```

**When to use:** Tables where column relationships matter and all columns have roughly equal importance. Works well for data-dense tables (financial data, spreadsheet-like views).

**Enhancements:**
- Add a scroll shadow to hint at hidden content: use `background-attachment: local` gradients on the container
- Pair with sticky first column (see below)

### Pattern 2: Stacked Cards on Mobile

Transform each row into a card-like block on narrow screens. Column headers become inline labels via CSS-generated content.

```html
<td data-label="Revenue">$1.2M</td>
```

```css
@media (max-width: 40em) {
  table, thead, tbody, tfoot, tr, th, td {
    display: block;
  }

  thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
  }

  td::before {
    content: attr(data-label);
    display: block;
    font-weight: 700;
    margin-bottom: 0.25em;
  }

  tr {
    margin-bottom: 1rem;
    border: 1px solid var(--border-color);
    border-radius: 0.5rem;
    padding: 1rem;
  }
}
```

**Critical accessibility note:** Changing `display` properties on table elements removes table semantics from the accessibility tree. When using this pattern, add ARIA roles via JavaScript to restore semantics, or accept that on mobile the content is read as a flat list (which can be acceptable if the stacked layout is genuinely easier to read).

Source: CSS-Tricks "Responsive Data Tables"; Adrian Roselli "A Responsive Accessible Table"

### Pattern 3: Priority Columns

Hide less important columns at narrow widths. Show a control to let users toggle hidden columns back.

```css
@media (max-width: 40em) {
  .priority-low { display: none; }
}
```

**Indicate hidden columns:** Show a message like "3 columns hidden" with a button to reveal them. Never silently remove data.

Source: NN/g data tables article (column management guidance)

### Pattern 4: Container Queries (Modern Approach)

Container queries let the table respond to the width of its parent container rather than the viewport. This makes table components truly reusable across different layout contexts (sidebar vs main content vs full-width).

```css
.table-wrapper {
  container-type: inline-size;
}

@container (max-width: 30em) {
  table, thead, tbody, tr, th, td {
    display: block;
  }
  /* stacked layout styles */
}

@container (min-width: 30em) {
  /* full table layout */
}
```

**Browser support:** Chrome 105+, Firefox 110+, Safari 16+. As of 2025, container queries have broad production readiness.

Source: web.dev container query patterns; MDN CSS container queries guide

### Comparison Tables on Mobile

NN/g research recommends converting comparison tables to a tabbed interface on mobile, showing one item at a time with swipe or tab navigation. Side-by-side comparison becomes impractical below about 3 items on small screens.

Source: NN/g "Comparison Tables" article

## Sticky Headers and Columns

### Sticky Table Headers

Apply `position: sticky` to `<th>` elements in `<thead>`:

```css
thead th {
  position: sticky;
  top: 0;
  z-index: 2;
  background-color: var(--surface-color);
}
```

**Gotchas:**
- In older browser versions, `position: sticky` does not work on `<thead>` or `<tr>` -- apply it to `<th>` cells instead. Modern browsers (2024+) support sticky on `<thead>` directly.
- `border-collapse: collapse` causes borders to scroll away with sticky headers. Use `border-collapse: separate; border-spacing: 0;` and apply borders to individual cells instead.
- The table must not be inside a container with `overflow: hidden` (this creates a new containing block that prevents sticky from reaching the viewport).
- Always set `background-color` on sticky headers so content does not show through underneath.

Source: CSS-Tricks "Position Sticky and Table Headers"; CodyHouse sticky table header guide

### Sticky First Column

Lock the first column while the rest scrolls horizontally:

```css
.table-container {
  overflow-x: auto;
}

th:first-child,
td:first-child {
  position: sticky;
  left: 0;
  z-index: 1;
  background-color: var(--surface-color);
}

/* Corner cell needs highest z-index (sticky in both directions) */
thead th:first-child {
  z-index: 3;
}
```

Source: NN/g data tables article (frozen columns guidance); CSS-Tricks position sticky examples

### Sticky Headers with Scroll Shadow

Add a subtle shadow to indicate the header is floating above scrolled content:

```css
thead th {
  position: sticky;
  top: 0;
  box-shadow: inset 0 -1px 0 var(--border-color);
}
```

Use `box-shadow` rather than `border-bottom` because borders on sticky elements can behave unpredictably with `border-collapse: separate`.

## Sorting and Filtering UI

### Visual Sort Indicators

- Show an arrow/chevron in the sorted column header: upward for ascending, downward for descending
- Unsorted sortable columns show a neutral bi-directional indicator (diamond or stacked arrows)
- Use shape changes, not just colour, to indicate direction (WCAG 1.4.1)
- Highlight the entire sorted column with a subtle background colour

### Filtering

- Make filters visible and discoverable; do not hide them behind an icon
- Clearly indicate active filters with a badge count or chip that can be dismissed
- Place filters above the table, not inside it
- Use plain language for filter syntax

Source: NN/g data tables article (filtering guidance)

### Column Reordering and Hiding

- Allow users to choose which columns are visible
- Support both drag-and-drop and menu-based column management
- Always provide a non-drag-and-drop alternative for accessibility
- Display a count of hidden columns so users know data exists

Source: NN/g data tables article

## Pagination vs Infinite Scroll vs Load More

### Pagination

**Best for:** Data tables, search results, product listings, any task where users need to find specific items, compare results, or return to a known position.

**Benefits:**
- Users know how much data exists (total items, total pages)
- Predictable mental model: page numbers serve as cognitive anchors
- Easy to bookmark or share a specific page
- Table footer remains accessible (not pushed infinitely downward)
- Better for SEO (distinct, crawlable URLs per page)
- Lower memory usage

**Guidelines:**
- Show total item count and current range ("Showing 1-25 of 342")
- Provide first/last page shortcuts in addition to prev/next
- Keep page size reasonable (25-50 rows for data tables)
- Let users choose page size when practical

### Infinite Scroll

**Best for:** Social feeds, image galleries, content discovery -- tasks where browsing without a specific goal.

**Problems with data tables:**
- Users lose position context
- Cannot reach the page footer
- Overwhelming volume of data with no endpoint
- Poor for comparison tasks (older items scroll away)
- Accessibility challenges: screen readers struggle with dynamically appended content
- High memory consumption on long sessions

**Do not use infinite scroll for data tables.**

### Load More Button

**Best for:** A compromise when pagination feels heavy and infinite scroll is inappropriate.

**Benefits over infinite scroll:**
- User-initiated loading (respects user control)
- Footer remains accessible until user requests more
- Loads in discrete, predictable chunks
- Better mobile performance than infinite scroll

**Implementation:** Place a "Load more" or "Show next 25" button below the current results. Include the count of remaining items.

Source: NN/g "Infinite Scrolling: When to Use It, When to Avoid It"; UX Planet pagination vs infinite scroll analysis; Crocoblock pagination comparison

## Typography in Tables

### Tabular (Monospaced) Numerals

Columns of numbers must vertically align. Proportional numerals (default in most fonts) cause columns to look jagged because each digit has a different width. Tabular numerals give every digit the same width.

```css
table {
  font-variant-numeric: tabular-nums;
}
```

For fonts that also have old-style (lowercase) figures, use lining tabular numerals for data tables:

```css
td {
  font-variant-numeric: lining-nums tabular-nums;
}
```

**Important:** The font must include tabular numeral alternates. If it does not, this declaration has no effect. Common fonts with tabular numerals: Inter, Roboto, Source Sans, system-ui fonts.

Source: MDN font-variant-numeric; Sebastian De Deyne "Tabular Numbers"; Web Typography "Numerals and Tables"

### Right-Align Numeric Columns

Numbers should be right-aligned so decimal points and digit places line up vertically. This makes magnitude comparison instantaneous through visual scanning.

```css
td.numeric {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

/* Right-align the header too for consistency */
th.numeric {
  text-align: right;
}
```

**Exceptions:** Identifiers that happen to be numbers (order numbers, ZIP codes, phone numbers) are not quantities -- left-align them as text.

Source: NN/g data tables article (alignment guidance); Butterick's Practical Typography

### Text Alignment by Data Type

| Data type       | Alignment  | Reason                                       |
|-----------------|------------|----------------------------------------------|
| Text            | Left       | Natural reading direction in LTR languages   |
| Numbers         | Right      | Aligns decimal points and digit places       |
| Currency        | Right      | Aligns decimal points; include currency symbol|
| Dates           | Left       | Read as text; use consistent format           |
| Status/badges   | Centre     | Short labels centred in column               |
| Actions/icons   | Centre     | Visual balance for icon buttons              |

### Column Header Alignment

Align headers the same way as their data. A right-aligned numeric column should have a right-aligned header. Mismatched alignment breaks the visual connection between header and data.

## Zebra Striping, Borders, and Spacing

### Zebra Striping

Alternating row backgrounds help users track across wide rows.

```css
tbody tr:nth-child(even) {
  background-color: var(--stripe-color, #f8f9fa);
}
```

**Research findings:** Empirical studies show mixed results. Zebra striping does not significantly improve speed or accuracy, but users perceive striped tables as easier to use. Striping is most beneficial for wide tables where the eye must travel far from left to right.

**Guidelines:**
- Use very subtle contrast (light grey on white, not bold colours)
- Ensure the stripe colour meets contrast requirements against the text
- Do not rely on colour alone to convey information
- Test in Windows High Contrast Mode (background colours may be overridden)

Source: A List Apart "Zebra Striping: Does it Really Help?"; A List Apart "Zebra Striping: More Data for the Case"

### Borders

Borders are an alternative to striping for row delineation.

```css
/* Horizontal rules only -- the cleaner modern pattern */
td, th {
  border-bottom: 1px solid var(--border-color);
}

/* Full grid for dense data (financial tables, spreadsheets) */
td, th {
  border: 1px solid var(--border-color);
}
```

**Horizontal rules only** (bottom borders on cells) is the most common modern pattern. It provides enough visual separation without the visual noise of a full grid.

### Row Hover Highlighting

Highlight the row under the cursor to help users track across wide tables:

```css
tbody tr:hover {
  background-color: var(--hover-color, #e8f0fe);
}
```

Combine with zebra striping: the hover colour should be distinct from both the white and striped row colours.

Source: NN/g data tables article (visual scanning support)

### Cell Padding and Density

Generous padding improves readability. Cramped tables are harder to scan.

```css
th, td {
  padding: 0.75rem 1rem;
}

/* Compact variant for data-dense views */
.table-compact th,
.table-compact td {
  padding: 0.375rem 0.75rem;
  font-size: 0.875rem;
}
```

Provide a density toggle (comfortable / compact) for power users who need to see more rows simultaneously.

## Common Mistakes

### Mistake 1: Building Tables from `<div>` Elements

Using `<div>` with `display: table` or Flexbox/Grid to create table-like layouts strips all native table semantics. Screen readers cannot navigate by row/column or announce headers.

**Fix:** Use native `<table>`, `<thead>`, `<tbody>`, `<tr>`, `<th>`, `<td>`. Reserve Grid/Flexbox for page layout, not tabular data.

Source: ADG "table of divs experiment"; W3C ARIA table role documentation

### Mistake 2: Missing `<caption>`

Without a caption, the table has no accessible name. Screen reader users hear "table, 5 columns, 12 rows" but have no idea what data the table contains.

**Fix:** Always include a `<caption>`. If you want it visually hidden, use the visually-hidden CSS pattern (not `display: none`).

### Mistake 3: Missing `scope` Attribute on `<th>`

Without `scope`, screen readers must guess whether a header applies to a column or a row. This works in simple tables but fails unpredictably in complex ones.

**Fix:** Always add `scope="col"` or `scope="row"` to every `<th>`.

### Mistake 4: Fixed Pixel Widths on Columns

Hard-coded column widths prevent the table from adapting to content length and screen size.

**Fix:** Use flexible sizing. Let the browser calculate widths, or use percentages/`fr` units. Use `table-layout: fixed` only when you intentionally want equal column distribution.

### Mistake 5: Hiding Actions Behind Hover

Row actions that only appear on hover are invisible to keyboard users and touch users. Users do not know the actions exist.

**Fix:** Show 1-2 primary actions always visible. Put additional actions in a menu (accessible via button with `aria-haspopup`).

Source: NN/g data tables article

### Mistake 6: Using Colour Alone for Status

A green/red dot without a text label or icon shape fails WCAG 1.4.1 (Use of Colour) and is invisible to colour-blind users.

**Fix:** Pair colour with a text label, icon shape, or pattern.

### Mistake 7: Infinite Scroll in Data Tables

Users lose their position, cannot compare rows at different positions, and cannot reach the footer.

**Fix:** Use pagination with clear position indicators.

### Mistake 8: Placing Comparison Columns Far Apart

When columns being compared require horizontal scrolling to see side by side, the comparison task becomes effectively impossible.

**Fix:** Let users reorder columns. Freeze the identifier column. Keep comparison targets adjacent.

Source: NN/g data tables article; NN/g comparison tables article

## CSS Techniques

### `table-layout: fixed`

By default, browsers calculate column widths from content (`table-layout: auto`). This causes layout shifts as data loads and can produce unpredictable widths.

```css
table {
  table-layout: fixed;
  width: 100%;
}
```

With `table-layout: fixed`, column widths are determined by the first row (or `<col>` widths). The browser does not need to scan all rows before rendering, resulting in faster layout. Content that overflows is clipped or wraps.

**Use when:**
- You want predictable, equal column widths
- Performance matters (large tables render faster)
- You control column widths via `<col>` elements or first-row cell widths

**Avoid when:**
- Content length varies significantly between columns and you want the browser to optimise widths automatically

### Scroll Container with Gradient Shadows

Indicate that a table can be scrolled horizontally with CSS-only shadow hints:

```css
.table-container {
  overflow-x: auto;
  background:
    linear-gradient(to right, var(--surface-color) 30%, transparent),
    linear-gradient(to left, var(--surface-color) 30%, transparent),
    linear-gradient(to right, rgba(0, 0, 0, 0.15), transparent),
    linear-gradient(to left, rgba(0, 0, 0, 0.15), transparent);
  background-position: left center, right center, left center, right center;
  background-repeat: no-repeat;
  background-size: 2rem 100%, 2rem 100%, 1rem 100%, 1rem 100%;
  background-attachment: local, local, scroll, scroll;
}
```

The `background-attachment: local` layers scroll with the content while the `scroll` layers stay fixed, creating shadows that appear and disappear as content is scrolled.

### `border-collapse` vs `border-spacing`

```css
/* Collapsed borders: cells share borders, no gaps */
table {
  border-collapse: collapse;
}

/* Separate borders: cells have individual borders with optional spacing */
table {
  border-collapse: separate;
  border-spacing: 0;
}
```

Use `border-collapse: separate` with `border-spacing: 0` when combining with `position: sticky`, because collapsed borders do not stick with the header cells.

### Container Queries for Table Breakpoints

```css
.table-wrapper {
  container-type: inline-size;
  container-name: table-container;
}

@container table-container (max-width: 35em) {
  /* Stack cells vertically on narrow containers */
  table, thead, tbody, tr, th, td {
    display: block;
  }
}
```

Prefer `container-type: inline-size` (not `size`) because it avoids containment on the block axis, which can cause layout issues with dynamic table heights.

### Print Styles

```css
@media print {
  /* Repeat thead on each printed page */
  thead {
    display: table-header-group;
  }

  /* Avoid breaking rows across pages */
  tr {
    page-break-inside: avoid;
  }

  /* Remove background colours (saves ink) */
  tbody tr:nth-child(even) {
    background-color: transparent;
  }

  /* Add borders for clarity without colour */
  td, th {
    border: 1px solid #999;
  }
}
```

Source: Adrian Roselli "A Responsive Accessible Table" (print styles section)

### CSS Subgrid for Table-Like Layouts

CSS Subgrid (part of Grid Level 2) allows card-based or list layouts to maintain column alignment without semantic `<table>` markup. This is appropriate when the data is not truly tabular but needs visual column alignment (for example, a list of settings with label/value pairs).

```css
.card-grid {
  display: grid;
  grid-template-columns: 1fr 2fr 1fr;
  gap: 1px;
}

.card-row {
  display: grid;
  grid-template-columns: subgrid;
  grid-column: 1 / -1;
}
```

**Do not use Subgrid as a replacement for `<table>` when the data is genuinely tabular.** Screen readers have no way to navigate a grid of `<div>` elements as a table. Use Subgrid for visual alignment in non-tabular layouts.

Browser support: Chrome 117+, Firefox 71+, Safari 16+. Broadly available as of late 2024.

Source: MDN Subgrid documentation; Josh W. Comeau "Brand New Layouts with CSS Subgrid"; caniuse.com/css-subgrid

## Quick Reference: Complete Table Template

```html
<div class="table-container"
     role="region"
     aria-labelledby="table-caption"
     tabindex="0">
  <table>
    <caption id="table-caption">
      Monthly active users by platform, 2024
    </caption>

    <colgroup>
      <col class="col-platform">
      <col span="4" class="col-quarter">
    </colgroup>

    <thead>
      <tr>
        <th scope="col">Platform</th>
        <th scope="col" class="numeric">Q1</th>
        <th scope="col" class="numeric">Q2</th>
        <th scope="col" class="numeric">Q3</th>
        <th scope="col" class="numeric">Q4</th>
      </tr>
    </thead>

    <tbody>
      <tr>
        <th scope="row">iOS</th>
        <td class="numeric">12,400</td>
        <td class="numeric">13,100</td>
        <td class="numeric">14,800</td>
        <td class="numeric">16,200</td>
      </tr>
      <tr>
        <th scope="row">Android</th>
        <td class="numeric">18,600</td>
        <td class="numeric">19,200</td>
        <td class="numeric">21,000</td>
        <td class="numeric">23,500</td>
      </tr>
    </tbody>

    <tfoot>
      <tr>
        <th scope="row">Total</th>
        <td class="numeric">31,000</td>
        <td class="numeric">32,300</td>
        <td class="numeric">35,800</td>
        <td class="numeric">39,700</td>
      </tr>
    </tfoot>
  </table>
</div>
```

```css
.table-container {
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}

.table-container:focus-visible {
  outline: 3px solid var(--focus-color);
  outline-offset: 2px;
}

table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  font-variant-numeric: tabular-nums;
}

caption {
  text-align: left;
  font-weight: 700;
  padding: 0.75rem 0;
}

th, td {
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--border-color);
  text-align: left;
  vertical-align: top;
}

th {
  font-weight: 600;
}

.numeric {
  text-align: right;
}

thead th {
  position: sticky;
  top: 0;
  z-index: 2;
  background-color: var(--surface-color);
  vertical-align: bottom;
}

tbody tr:nth-child(even) {
  background-color: var(--stripe-color, #f8f9fa);
}

tbody tr:hover {
  background-color: var(--hover-color, #e8f0fe);
}

tfoot th,
tfoot td {
  font-weight: 700;
  border-top: 2px solid var(--border-color);
}
```

## Sources

- NN/g: "Data Tables" -- https://www.nngroup.com/articles/data-tables/
- NN/g: "Comparison Tables" -- https://www.nngroup.com/articles/comparison-tables/
- CSS-Tricks: "Responsive Data Tables" -- https://css-tricks.com/responsive-data-tables/
- CSS-Tricks: "Position Sticky and Table Headers" -- https://css-tricks.com/position-sticky-and-table-headers/
- Adrian Roselli: "A Responsive Accessible Table" -- https://adrianroselli.com/2017/11/a-responsive-accessible-table.html
- Adrian Roselli: "Table with Expando Rows" -- https://adrianroselli.com/2019/09/table-with-expando-rows.html
- Adrian Roselli: "Sortable Table Columns" -- https://adrianroselli.com/2021/04/sortable-table-columns.html
- MDN: `<table>` element -- https://developer.mozilla.org/en-US/docs/Web/HTML/Element/table
- MDN: `aria-sort` attribute -- https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-sort
- MDN: `font-variant-numeric` -- https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/font-variant-numeric
- W3C WAI: Tables Tutorial -- https://www.w3.org/WAI/tutorials/tables/
- W3C WAI: Caption & Summary -- https://www.w3.org/WAI/tutorials/tables/caption-summary/
- W3C WAI APG: Sortable Table Example -- https://www.w3.org/WAI/ARIA/apg/patterns/table/examples/sortable-table/
- Heydon Pickering: Inclusive Components "Data Tables" -- https://inclusive-components.design/data-tables/
- WebAIM: Creating Accessible Tables -- https://webaim.org/techniques/tables/data
- Deque University: Sortable Table -- https://dequeuniversity.com/library/aria/table-sortable
- A List Apart: "Zebra Striping: Does it Really Help?" -- https://alistapart.com/article/zebrastripingdoesithelp/
- NN/g: "Infinite Scrolling Tips" -- https://www.nngroup.com/articles/infinite-scrolling-tips/
- ADG: "Table of Divs Experiment" -- https://www.accessibility-developer-guide.com/examples/tables/table-of-divs-experiment/
