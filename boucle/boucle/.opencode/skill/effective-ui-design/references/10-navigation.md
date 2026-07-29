# Navigation

Patterns and guidelines for building accessible, well-structured navigation that works across devices and input methods.

## Navigation Types and When to Use Each

### Horizontal Navigation Bar

The most common pattern for primary site navigation on desktop. Displays top-level links in a row across the top of the page.

**When to use:**
- 4-7 top-level items
- Items have short, scannable labels (1-2 words)
- Desktop or wide viewports

**When to avoid:**
- More than 7 items (overflows or requires truncation)
- Labels are long or unpredictable in length

**Structure:**
```html
<nav aria-label="Main">
  <ul>
    <li><a href="/" aria-current="page">Home</a></li>
    <li><a href="/products">Products</a></li>
    <li><a href="/about">About</a></li>
    <li><a href="/contact">Contact</a></li>
  </ul>
</nav>
```

**Key rules:**
- Wrap in `<nav>` with `aria-label` to create a landmark
- Use `<ul>` so screen readers announce "list, N items"
- Mark active page with `aria-current="page"`, not just a CSS class
- Place in `<header>` for conventional positioning
- Ensure link contrast meets 4.5:1 minimum

Source: [web.dev - Website Navigation](https://web.dev/articles/website-navigation), [NN/g - Menu Design Checklist](https://www.nngroup.com/articles/menu-design/)

### Vertical Sidebar Navigation

A persistent column of links on the left side, common in applications, dashboards, and documentation sites.

**When to use:**
- Applications with many sections (8+ items)
- Deep hierarchies that benefit from always-visible structure
- Users frequently jump between sections
- Long labels that would not fit horizontally

**When to avoid:**
- Simple marketing sites with few pages
- Mobile-first designs (collapses to hamburger anyway)

**Key rules:**
- Place on the left side (convention for applications)
- Left-align link text for scannability
- Front-load keywords in labels
- Show current location clearly
- Consider collapsible sections for deep hierarchies

Source: [NN/g - Vertical Navigation](https://www.nngroup.com/videos/vertical-navigation/), [NN/g - Menu Design Checklist](https://www.nngroup.com/articles/menu-design/)

### Hamburger / Disclosure Navigation

A toggle button that reveals hidden navigation. On mobile, this is the standard pattern for menus with more than 4 items.

**Performance impact (NN/g research):**
- Discoverability cut almost in half when navigation is hidden
- Desktop: hidden menus used in only 27% of tasks vs 48-50% for visible nav
- Users took 5-7 seconds longer to find hidden navigation on desktop
- Mobile: 2-second delay accessing hidden menus
- Task difficulty perceived as 21% harder with hidden navigation
- Task completion 39% slower on desktop, 15% slower on mobile

**When to use:**
- Mobile viewports with more than 4 navigation items
- As a responsive fallback for horizontal navigation

**When to avoid on desktop:**
- Desktop sites should display navigation visibly
- "Mobile-first is not the same as mobile-only"

**Use the disclosure pattern, not the ARIA menu pattern:**
```html
<nav aria-label="Main">
  <button type="button"
          aria-expanded="false"
          aria-controls="nav-list"
          aria-label="Menu">
    <svg aria-hidden="true" width="24" height="24"><!-- hamburger icon --></svg>
  </button>
  <ul id="nav-list">
    <li><a href="/">Home</a></li>
    <li><a href="/about">About</a></li>
  </ul>
</nav>
```

**Required JavaScript behaviours:**
- Toggle `aria-expanded` between `"true"` and `"false"` on click
- Close on Escape key press
- Use `visibility: hidden` or `display: none` to hide (never just `opacity` or `transform` -- invisible links remain keyboard-focusable)
- Close when focus leaves the navigation container
- Close when clicking outside the menu

**Why disclosure over ARIA menu roles:**
The WAI-ARIA APG explicitly recommends the disclosure pattern for site navigation. The `menu`, `menubar`, and `menuitem` roles shift screen readers into forms/application mode with keyboard commands (arrow keys, a-z shortcuts) that confuse users navigating a website. Reserve ARIA menu roles for application-style interfaces that mimic desktop software menus.

Source: [NN/g - Hamburger Menus](https://www.nngroup.com/articles/hamburger-menus/), [Adrian Roselli - Link Disclosure Widget Navigation](https://adrianroselli.com/2019/06/link-disclosure-widget-navigation.html), [W3C APG - Disclosure Navigation](https://www.w3.org/WAI/ARIA/apg/patterns/disclosure/examples/disclosure-navigation/), [web.dev - Website Navigation](https://web.dev/articles/website-navigation)

### Disclosure Navigation with Sub-menus

For sites with two-level navigation, combine top-level links with disclosure buttons that expand sub-navigation.

**Structure (Adrian Roselli pattern):**
```html
<nav aria-label="Main">
  <ul>
    <li>
      <a href="/about" id="about-link" aria-current="page">About</a>
      <button type="button"
              aria-expanded="false"
              aria-controls="about-submenu"
              aria-labelledby="about-link">
        <svg aria-hidden="true"><!-- caret icon --></svg>
      </button>
      <ul id="about-submenu" hidden>
        <li><a href="/about/team">Team</a></li>
        <li><a href="/about/careers">Careers</a></li>
      </ul>
    </li>
  </ul>
</nav>
```

**Key ARIA attributes:**
- `aria-expanded`: reflects submenu visibility state
- `aria-controls`: references the controlled submenu by ID
- `aria-labelledby`: references the adjacent link so the button inherits its name (screen readers announce "About, toggle button, collapsed" rather than needing separate text)
- `aria-current="page"`: marks the current page link

**Required behaviours:**
- Escape closes visible sub-navigation
- Focus-out closes submenus
- Click-outside closes submenus
- Do NOT use `aria-haspopup` (requires specific role containers that do not fit this pattern)

Source: [Adrian Roselli - Link Disclosure Widget Navigation](https://adrianroselli.com/2019/06/link-disclosure-widget-navigation.html), [W3C APG - Disclosure Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/disclosure/)

### Mega Menu

A large two-dimensional dropdown panel that displays many navigation options grouped into categories. Best for large sites with extensive content hierarchies.

**When to use:**
- Large sites with many categories (e-commerce, news, universities)
- Users need to see available options at a glance
- Categories can be logically grouped

**When to avoid:**
- Fewer than 20 navigation items (use simpler patterns)
- Mobile viewports (convert to sequential/accordion navigation)

**Design guidelines (NN/g):**
- Chunk options into related groups based on user mental models
- All options visible without scrolling within the panel
- Use images to help users compare and visualise choices
- Differentiate group headings from links typographically
- Show each option only once
- Front-load key terms in labels

**Timing for hover-activated menus:**
- 0.5 seconds pointer rest before displaying
- Display within 0.1 seconds once triggered
- 0.5 seconds after pointer exits before hiding

**Prefer click-activation over hover:**
- Hover is not available on touchscreens or keyboard-only
- Click provides consistent interaction across all devices and input methods

**Common mistakes:**
- Using similar labels that do not front-load key information
- Hiding search functionality within menus
- Complex GUI widgets inside the menu panel
- No clear boundary indicators for screen magnifier users

**Accessibility note:** Consider providing an alternative full-page navigation for assistive technology users, as screen magnifier users see only a portion of a mega menu at a time.

Source: [NN/g - Mega Menus Work Well](https://www.nngroup.com/articles/mega-menus-work-well/), [NN/g - Menu Design Checklist](https://www.nngroup.com/articles/menu-design/)

### Tab Navigation

Tabs divide content into panels within the same page context, reducing cognitive load by chunking information.

**Two distinct types -- never mix them:**

1. **In-page tabs** -- switch content panels without page navigation
   - Content is related and similar in nature
   - Loading is instantaneous (content already in DOM or fetched asynchronously)
   - Always one tab selected by default

2. **Navigation tabs** -- link to different pages styled as tabs
   - Content is unrelated
   - Small loading delay is acceptable
   - May have no active tab if page was accessed from elsewhere

**When to use tabs:**
- Content has clear, distinct groupings
- Few groupings (no carousel scrolling needed)
- Concise labels possible (1-2 words)
- Users do not need to compare content across tabs simultaneously

**When to use accordions instead:**
- Mobile viewports with limited horizontal space
- Short content items (FAQs)
- Labels are longer phrases

**Visual design rules:**
- Use at least two visual indicators for the active tab (underline + bold, or fill + colour change)
- Position tab list above the panel
- Single row only -- never stack tabs into multiple rows
- Minimum 2-3px line thickness for underline indicators
- Unselected tabs must have sufficient contrast to remain readable
- Connect selected tab to its panel visually through proximity or shared background

**ARIA structure for in-page tabs:**
```html
<div role="tablist" aria-label="Account settings">
  <button role="tab" id="tab-1" aria-selected="true"
          aria-controls="panel-1">Profile</button>
  <button role="tab" id="tab-2" aria-selected="false"
          aria-controls="panel-2" tabindex="-1">Security</button>
</div>
<div role="tabpanel" id="panel-1" aria-labelledby="tab-1">
  <!-- Profile content -->
</div>
<div role="tabpanel" id="panel-2" aria-labelledby="tab-2" hidden>
  <!-- Security content -->
</div>
```

**Keyboard interaction for in-page tabs:**
- Tab key moves focus into the tablist, then past it to the panel
- Arrow keys move between tabs within the tablist
- Home/End jump to first/last tab
- Enter/Space activate the focused tab

**Do NOT use `role="tablist"` for navigation tabs.** Navigation tabs are just styled links in a `<nav>` element.

**Common mistakes:**
- Mixing in-page and navigation tab types in one control
- Poor selection indicators (barely visible bold or thin underline)
- Low contrast on unselected tabs
- Stacked rows (disrupts spatial memory)
- ALL CAPS labels (reduces legibility)
- Using jargon or marketing terms as labels

Source: [NN/g - Tabs, Used Right](https://www.nngroup.com/articles/tabs-used-right/)

### Bottom Tab Bar (Mobile)

A fixed bar at the bottom of the screen with 3-5 primary navigation destinations. The dominant mobile navigation pattern.

**When to use:**
- Mobile apps or mobile web with 3-5 top-level destinations
- Users frequently switch between sections
- Destinations are of roughly equal importance

**When to avoid:**
- More than 5 items (targets become too small)
- Single-task flows (checkout, onboarding)
- Deep hierarchies (use sidebar or hamburger instead)

**Design rules:**
- 3-5 items maximum
- Each icon leads directly to a destination (never opens a menu or popup)
- Use familiar, recognisable icons paired with text labels
- Place in the thumb-friendly zone (bottom of screen)
- Minimum tap target: 48x48px with adequate spacing between items
- Clearly distinguish active from inactive state using colour and contrast
- Use short noun labels (Home, Search, Profile) not verbs

**Accessibility:**
- Use `<nav aria-label="Main">` wrapping a list of links
- Mark active item with `aria-current="page"`
- Ensure icons have accessible text via visible labels (preferred) or `aria-label`

Source: [NN/g - Mobile Navigation Patterns](https://www.nngroup.com/articles/mobile-navigation-patterns/), [Smashing Magazine - Navigation Design for Mobile UX](https://www.smashingmagazine.com/2022/11/navigation-design-mobile-ux/)

### Breadcrumbs

A secondary navigation aid showing the user's location within the site hierarchy.

**When to use:**
- Sites with hierarchical structure more than 2 levels deep
- E-commerce, documentation, content-heavy sites
- As a supplement to primary navigation, never as a replacement

**Design rules:**
- Show hierarchy, not history (do not duplicate the browser back button)
- Start from the homepage, progress to current page
- Use ">" or "/" as separators
- Current page is the last item and is NOT a clickable link
- Position near the top of the page, above the main content
- Display as a single horizontal line
- Use conventional styling -- users recognise standard breadcrumb patterns

**Structure:**
```html
<nav aria-label="Breadcrumb">
  <ol>
    <li><a href="/">Home</a></li>
    <li><a href="/products">Products</a></li>
    <li><a href="/products/shoes">Shoes</a></li>
    <li><a aria-current="page">Running Shoes</a></li>
  </ol>
</nav>
```

Use `<ol>` (ordered list) because breadcrumbs represent a sequential path. Add `aria-label="Breadcrumb"` to distinguish from other `<nav>` landmarks on the page.

**CSS separators (avoid cluttering the DOM):**
```css
nav[aria-label="Breadcrumb"] li + li::before {
  content: "/";
  padding-inline: 0.5ch;
  color: var(--color-text-weak);
}
```

**Common mistakes:**
- Implementing path-based (history) breadcrumbs instead of hierarchy-based
- Making the current page a clickable link
- Using decorative or complex separators
- Omitting `aria-label` when multiple `<nav>` landmarks exist

**Key insight:** Breadcrumbs "never cause problems in user testing: people might overlook this small design element, but they never misinterpret" them. The cost-benefit ratio is strongly favourable.

Source: [NN/g - Breadcrumb Navigation Useful](https://www.nngroup.com/articles/breadcrumb-navigation-useful/)

### Pagination

Navigation for multi-page content (search results, article lists).

**Structure:**
```html
<nav aria-label="Pagination">
  <ul>
    <li><a href="?page=1" aria-label="Page 1">1</a></li>
    <li><a href="?page=2" aria-current="page" aria-label="Page 2">2</a></li>
    <li><a href="?page=3" aria-label="Page 3">3</a></li>
    <li><a href="?page=4" aria-label="Next page" rel="next">Next</a></li>
  </ul>
</nav>
```

**Key rules:**
- Use a separate `<nav>` with `aria-label="Pagination"` to distinguish from main navigation
- Mark current page with `aria-current="page"`
- Provide `aria-label` on each link (screen readers need "Page 3", not just "3")
- Include Previous/Next links with `rel="prev"` / `rel="next"`
- Disable (do not hide) previous/next when at bounds

### Sticky Headers

Headers that remain visible during scrolling, keeping navigation accessible without scrolling back to the top.

**When to use:**
- Long pages where users need frequent access to navigation
- Sites where users jump between categories
- E-commerce with persistent cart/search

**When to avoid:**
- Short pages where the header is always visible
- Mobile viewports where screen space is limited (consider partially sticky)
- Pages where users primarily read sequentially

**Design rules (NN/g):**
- Minimise space: maximise content-to-chrome ratio
- Keep headers compact -- minimum tap targets of 1cm x 1cm, text approximately 16pt minimum
- No more than 5 items in a sticky navigation bar
- Use opaque backgrounds (never translucent -- causes low contrast)
- Clearly separate header from content with borders or shadows

**Animation guidelines:**
- Prefer no animation -- simply keep the header in place
- If animation is needed: 300-400ms duration, smooth and immediate
- Avoid "stalker menus" that follow with a delay
- Wrap motion in `prefers-reduced-motion`:

```css
@media (prefers-reduced-motion: no-preference) {
  .site-header {
    transition: transform 0.3s ease;
  }
}
```

**Partially sticky headers:**
- Reappear when user scrolls up, hide when scrolling down
- Effective on mobile where screen space is precious
- Trigger after minimal scroll distance to avoid false positives

**Implementation:**
```css
.site-header {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--color-background);
}
```

**Critical WCAG 2.2 requirement -- Focus Not Obscured (2.4.11):**

Sticky headers can obscure focused elements when keyboard users Tab backwards up the page. This fails WCAG 2.2 Level AA.

**CSS fix using `scroll-padding-top`:**
```css
html {
  scroll-padding-top: 5rem; /* match header height */
}
```

This creates a buffer so the browser scrolls focused elements into view below the sticky header. It also fixes anchor link positioning.

**For dynamic header heights, use a CSS custom property:**
```css
html {
  scroll-padding-top: var(--header-height, 5rem);
}
```

```js
const header = document.querySelector('.site-header');
const observer = new ResizeObserver(([entry]) => {
  document.documentElement.style.setProperty(
    '--header-height',
    `${entry.borderBoxSize[0].blockSize}px`
  );
});
observer.observe(header);
```

**Additional technique -- `scroll-margin-top` on focusable elements:**
```css
main *:focus {
  scroll-margin-top: 5rem;
}
```

Note: `scroll-padding-top` on `<html>` is generally more maintainable as it centralises the logic around the obscuring element rather than requiring every focusable element to know about the header.

Source: [NN/g - Sticky Headers](https://www.nngroup.com/articles/sticky-headers/), [Smashing Magazine - Sticky Menus UX Guidelines](https://www.smashingmagazine.com/2023/05/sticky-menus-ux-guidelines/), [Vispero - Prevent Focused Elements from Being Obscured](https://www.tpgi.com/prevent-focused-elements-from-being-obscured-by-sticky-headers/), [W3C - WCAG 2.2 Focus Not Obscured](https://www.w3.org/WAI/WCAG22/Understanding/focus-not-obscured-minimum)

### In-Page Filtered Search

A search input that filters visible items on the current page. Useful for long lists, directories, or documentation indexes.

**Basic pattern:**
```js
function filterItems() {
  const query = document.getElementById('search').value.toLowerCase();
  const items = document.querySelectorAll('.filterable-item');

  let count = 0;
  for (const item of items) {
    const match = item.textContent.toLowerCase().includes(query);
    item.hidden = !match;
    if (match) count++;
  }

  document.getElementById('filter-status').textContent =
    `${count} result${count !== 1 ? 's' : ''} found`;
}
```

**Debounce the input to avoid excessive DOM updates:**
```js
let timer;
searchInput.addEventListener('input', () => {
  clearTimeout(timer);
  timer = setTimeout(filterItems, 300);
});
```

**Announce results to screen readers:**
```html
<div id="filter-status" role="status" aria-live="polite"></div>
```

**Use `hidden` attribute** instead of CSS classes for hiding -- it is semantic and removes items from the accessibility tree.

**Limitation:** This pattern works only with DOM-resident content. It cannot query a database or API.

Source: [CSS-Tricks - In-Page Filtered Search](https://css-tricks.com/in-page-filtered-search-with-vanilla-javascript/)

## Accessibility Requirements

### Semantic HTML and ARIA Landmarks

Every navigation region must use the `<nav>` element. When multiple `<nav>` elements exist on a page, each must have a unique accessible name.

**Landmark labelling:**
```html
<!-- When a visible heading exists, use aria-labelledby -->
<nav aria-labelledby="main-nav-heading">
  <h2 id="main-nav-heading">Main menu</h2>
  <ul>...</ul>
</nav>

<!-- When no visible heading exists, use aria-label -->
<nav aria-label="Main">...</nav>
<nav aria-label="Breadcrumb">...</nav>
<nav aria-label="Pagination">...</nav>
```

**Complete landmark structure for a page:**
```html
<body>
  <header>                              <!-- banner landmark -->
    <nav aria-label="Main">...</nav>    <!-- navigation landmark -->
  </header>
  <main>                                <!-- main landmark -->
    <nav aria-label="Breadcrumb">...</nav>
    <!-- page content -->
    <nav aria-label="Pagination">...</nav>
  </main>
  <aside>...</aside>                    <!-- complementary landmark -->
  <footer>...</footer>                  <!-- contentinfo landmark -->
</body>
```

**Rules:**
- One `banner` (`<header>` as direct child of `<body>`) per page
- One `main` per page
- One `contentinfo` (`<footer>` as direct child of `<body>`) per page
- Multiple `navigation`, `complementary`, and `search` landmarks allowed
- Never include the role name in the label (avoid "Main Navigation" -- screen readers already announce "navigation")
- All perceivable content should live within a landmark region
- Use semantic HTML elements (`<nav>`, `<main>`, `<header>`, `<footer>`, `<aside>`, `<search>`) before adding ARIA roles

Source: [W3C WAI - Landmark Regions](https://www.w3.org/WAI/ARIA/apg/practices/landmark-regions/), [MDN - ARIA navigation role](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Roles/navigation_role)

### Do Not Use ARIA Menu Roles for Site Navigation

This is a critical and commonly violated rule. The `menu`, `menubar`, and `menuitem` roles are designed for application-style menus (like a desktop file menu), not website navigation.

**Problems with menu roles on site navigation:**
- Screen readers switch to forms/application mode
- Users expect arrow-key navigation, Home/End, and first-letter shortcuts
- Standard Tab-key navigation stops working as expected
- Average web users do not know these keyboard conventions

**Correct approach:**
- Use `<nav>` containing `<ul>` with `<li>` and `<a>` elements
- Use disclosure buttons (`aria-expanded`) for expandable sections
- Let links behave as normal links (Tab key, Enter to activate)

Source: [web.dev - Website Navigation](https://web.dev/articles/website-navigation), [Adrian Roselli - Link Disclosure Widget Navigation](https://adrianroselli.com/2019/06/link-disclosure-widget-navigation.html)

### Keyboard Navigation

**Standard navigation links:**
- Tab / Shift+Tab moves between links
- Enter activates a link

**Disclosure menus:**
- Tab / Shift+Tab navigates between the toggle button, links, and other interactive elements
- Enter / Space toggles the disclosure button
- Escape closes an open submenu

**In-page tabs (role="tablist"):**
- Tab moves focus into and out of the tablist (single Tab stop)
- Arrow keys move between tabs
- Home / End jump to first / last tab
- Enter / Space activate the selected tab

**General requirements:**
- All interactive elements must be reachable via keyboard
- Focus order must follow a logical reading sequence
- Visible focus indicators on every interactive element (use `:focus-visible`)
- Skip link as the first focusable element on the page

See `01-fundamentals.md` for focus indicator styling (`:focus-visible`), skip link implementation, target size requirements (48x48pt minimum), and `prefers-reduced-motion` patterns.

## Mobile vs Desktop Patterns

### Responsive Strategy

The same navigation must work across viewports. Use progressive enhancement:

1. **Semantic HTML works without CSS or JavaScript** -- a `<nav>` with a list of links is usable on its own
2. **CSS provides layout** -- horizontal on desktop, vertical/hidden on mobile
3. **JavaScript adds behaviour** -- hamburger toggle, disclosure expand/collapse

**Progressive enhancement for the hamburger button:**

Insert the toggle button via JavaScript (or `<template>`) so the navigation remains fully visible when JavaScript fails:

```html
<nav aria-label="Main">
  <template id="burger-template">
    <button type="button" aria-expanded="false"
            aria-label="Menu" aria-controls="nav-list">
      <svg aria-hidden="true">...</svg>
    </button>
  </template>
  <ul id="nav-list">
    <li><a href="/">Home</a></li>
    <li><a href="/about">About</a></li>
  </ul>
</nav>
```

### Desktop (wider than ~768px)

- Show full horizontal navigation bar
- Use disclosure buttons for sub-menus if needed
- Mega menus appropriate for large sites
- Sticky header if page is long and navigation is needed frequently

### Mobile (narrower than ~768px)

- 4 or fewer items: display as visible links (horizontal or bottom tab bar)
- 5+ items: hamburger/disclosure menu is acceptable
- Bottom tab bar for 3-5 primary destinations (thumb-friendly zone)
- Supplement hidden menus with in-page links to key content
- Accordions work well for multi-level mobile navigation

### Responsive CSS Approach

**Use container queries for component-level nav, media queries for page-level layout:**

```css
/* Page-level: switch from mobile to desktop layout */
@media (min-width: 48rem) {
  .site-header {
    --nav-list-display: flex;
    --nav-button-display: none;
  }
}

.nav-toggle {
  display: var(--nav-button-display, block);
}

.nav-list {
  display: var(--nav-list-display, none);
}

.nav-list[data-visible="true"] {
  display: block;
}
```

For container queries on navigation components, see `04-layout-spacing.md` (section "Use Container Queries for Component-Level Responsiveness").

Source: [Smashing Magazine - Navigation Design for Mobile UX](https://www.smashingmagazine.com/2022/11/navigation-design-mobile-ux/), [NN/g - Mobile Navigation Patterns](https://www.nngroup.com/articles/mobile-navigation-patterns/)

## Modern CSS Techniques

### Scroll-Snap for Horizontal Tabs

When tabs overflow on small screens, use CSS scroll-snap for a swipeable tab strip:

```css
.tab-list {
  display: flex;
  overflow-x: auto;
  scroll-snap-type: x mandatory;
  scrollbar-width: none; /* hide scrollbar for cleaner look */
  -webkit-overflow-scrolling: touch;
}

.tab-list::-webkit-scrollbar {
  display: none;
}

.tab-list [role="tab"] {
  scroll-snap-align: start;
  flex-shrink: 0;
  white-space: nowrap;
}
```

**Emerging CSS features (Chrome 128+):**
- `::scroll-button()` pseudo-element generates accessible previous/next buttons with automatic ARIA roles
- `::scroll-marker` and `::scroll-marker-group` associate navigation markers with scroll items, handling tablist keyboard behaviour automatically
- `scroll-state(snapped)` container queries enable styling based on snap position

Use these as progressive enhancements with fallbacks for browsers that do not yet support them.

Source: [Chrome for Developers - New in Web UI I/O 2025](https://developer.chrome.com/blog/new-in-web-ui-io-2025-recap)

### Sticky Positioning

```css
.site-header {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--color-background);
}

/* Prevent focus obscurement (WCAG 2.4.11) */
html {
  scroll-padding-top: var(--header-height, 4rem);
}
```

Use `env(safe-area-inset-top)` for notched devices:
```css
.site-header {
  padding-top: env(safe-area-inset-top);
}
```

### Logical Properties

Use logical properties (`padding-inline-start`, `margin-inline`) so navigation adapts to RTL languages. See `04-layout-spacing.md` for the full property mapping and `17-i18n-rtl.md` for extended RTL patterns.

### Hiding Navigation Accessibly

**Do use:**
- `hidden` attribute (semantic, removes from accessibility tree)
- `display: none` (removes from layout and accessibility tree)
- `visibility: hidden` (removes from accessibility tree, preserves layout space)

**Do NOT use alone:**
- `opacity: 0` (visually hidden but still keyboard-focusable)
- `transform: translateX(-100%)` (visually off-screen but still keyboard-focusable)

If combining `opacity` or `transform` for animation, toggle `visibility` as well:

```css
.nav-dropdown {
  visibility: hidden;
  opacity: 0;
}

.nav-dropdown[data-visible="true"] {
  visibility: visible;
  opacity: 1;
}

@media (prefers-reduced-motion: no-preference) {
  .nav-dropdown {
    transition: opacity 0.2s ease, visibility 0.2s ease;
  }
}
```

## Common Mistakes and Anti-Patterns

### Mistake 1: Hiding navigation on desktop

Discoverability drops almost in half. Always display primary navigation visibly on desktop viewports. Hidden navigation was used in only 27% of tasks on desktop vs 48-50% for visible navigation.

### Mistake 2: Using ARIA menu roles for site navigation

Shifts screen readers into application mode. Users lose standard navigation shortcuts. Use `<nav>` with links and disclosure buttons instead.

### Mistake 3: Not indicating the current page

"Probably the single most common mistake" in navigation design. Use `aria-current="page"` and visible styling (bold, underline, or colour change) to show where the user is.

### Mistake 4: Hover-only dropdowns

Hover is unavailable on touch devices and keyboard-only users. Use click-activated menus for consistent cross-device interaction.

### Mistake 5: Opacity-only hiding

Setting `opacity: 0` hides elements visually but leaves them keyboard-focusable. Users Tab into invisible links. Always toggle `visibility` or `display` alongside `opacity`.

### Mistake 6: No visible focus indicators

Removing outlines without providing alternatives makes navigation unusable for keyboard users. Always provide a visible focus indicator.

### Mistake 7: Sticky headers that obscure focused elements

Fails WCAG 2.2 criterion 2.4.11 (Focus Not Obscured). Fix with `scroll-padding-top` on `<html>` matching the header height.

### Mistake 8: Cascading multi-level fly-out menus

Require precise mouse movement across nested layers. Frustrating and error-prone. Use mega menus or landing pages instead.

### Mistake 9: Vague navigation labels

Labels like "Solutions", "Resources", or "Explore" provide poor information scent. Use specific, familiar terms that describe the destination content.

### Mistake 10: Innovating on navigation patterns

Users prefer familiar, accessible menu patterns over novel designs. Prioritise usability over originality. As NN/g states: "Avoid innovative or gimmicky patterns for navigation."

### Mistake 11: Missing skip link

Keyboard users must Tab through every navigation link on every page load. A skip link is the first focusable element and jumps to `<main>`.

### Mistake 12: Navigation without list structure

Screen readers benefit from `<ul>` inside `<nav>` because they announce "list, N items", giving users a sense of the navigation scope before they enter it.

Source: [NN/g - Menu Design Checklist](https://www.nngroup.com/articles/menu-design/), [NN/g - Hamburger Menus](https://www.nngroup.com/articles/hamburger-menus/), [web.dev - Website Navigation](https://web.dev/articles/website-navigation)

## NN/g Menu Design Checklist (17 Guidelines Summary)

1. Show navigation on larger screens -- never hide in hamburger on desktop
2. Put menus in expected locations (header for primary, left for local, top for utility)
3. Link text must contrast with background (4.5:1 minimum)
4. Do not cover the screen with the menu on larger screens
5. Indicate the user's current location in the menu
6. Provide local navigation for closely related content
7. Use clear, specific, familiar wording for labels
8. Make labels easy to scan (left-align, front-load keywords)
9. For large sites, show several navigation tiers in sub-menus
10. Use visual cues (images, icons, colour) for long menus
11. Make links big enough to tap or click easily (48px+ targets)
12. Signify sub-menus with a caret or arrow icon
13. Use click-activated rather than hover-activated sub-menus
14. Avoid multilevel cascading menus -- use mega menus or landing pages
15. Consider sticky or partially sticky menus for long pages
16. Optimise for easy physical access to frequently used items (Fitts's Law)
17. Avoid innovative or gimmicky navigation patterns

Source: [NN/g - Menu Design Checklist](https://www.nngroup.com/articles/menu-design/)

## Chapter Summary

1. Use `<nav>` with `<ul>` for all navigation; label with `aria-label` when multiple `<nav>` exist
2. Mark active page with `aria-current="page"` -- visible styling and semantic
3. Show navigation visibly on desktop; hide only on mobile when items exceed 4
4. Use the disclosure pattern (`aria-expanded`) for expandable menus, not ARIA menu roles
5. Provide keyboard access: Tab between links, Escape to close
6. Fix sticky header focus obscurement with `scroll-padding-top`
7. Use click-activation for menus, not hover-only
8. Front-load keywords in labels; use specific, familiar terms
