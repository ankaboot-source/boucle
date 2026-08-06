# Scroll Patterns

Techniques for controlling scroll behaviour, scroll-driven animations, and scroll-related UX patterns that respect user preferences and assistive technology.

## CSS Scroll Snap

Scroll snap gives native, smooth snapping behaviour without JavaScript. The browser handles the physics and respects platform conventions.

### scroll-snap-type (Container)

Set on the scroll container to opt into snapping. Requires two values: axis and strictness.

```css
.carousel {
  overflow-x: auto;
  scroll-snap-type: x mandatory;
}

.section-scroll {
  overflow-y: auto;
  scroll-snap-type: y proximity;
}
```

**Axis values:** `x`, `y`, `block`, `inline`, `both`

**Strictness values:**

| Value | Behaviour | Use when |
|-------|-----------|----------|
| `mandatory` | Viewport **must** rest on a snap point after scrolling | Every child fills the viewport (full-screen sections, carousels with one item visible) |
| `proximity` | Viewport **may** snap when close to a snap point | Content between snap points still needs to be readable (long articles, mixed-height cards) |

**Danger with `mandatory`:** If a child is taller than the scroll container, users cannot scroll to its middle -- the browser forces them to the next snap point. Only use `mandatory` when every child fits within the viewport.

### scroll-snap-align (Children)

Set on each child element to define which edge or centre snaps to the container.

```css
.carousel-item {
  scroll-snap-align: start;   /* Snap left/top edge */
}

.hero-slide {
  scroll-snap-align: center;  /* Snap centre of element to centre of container */
}
```

**Values:** `start`, `center`, `end`, `none`

Two values can be provided for block and inline axes: `scroll-snap-align: start end;`

### scroll-snap-stop

Prevents fast swiping from skipping past important snap points. Without it, a fast flick on a touch device can skip several items.

```css
.carousel-item {
  scroll-snap-stop: always;  /* Must stop here, even on fast swipe */
}
```

**Values:** `normal` (default -- may skip), `always` (must stop)

Use `always` for carousels where each item is a discrete step (onboarding flows, image galleries with captions). Leave as `normal` for long lists where skipping ahead is expected.

Baseline support: available across major browsers since July 2022.

### scroll-padding (Container)

Offsets the snap alignment to account for sticky headers, toolbars, or other fixed elements. Without it, snapped content hides behind the sticky element.

```css
.scroll-container {
  scroll-snap-type: y mandatory;
  scroll-padding-top: 4rem;  /* Height of sticky header */
}
```

Accepts any length value. Supports longhand properties: `scroll-padding-top`, `scroll-padding-right`, `scroll-padding-bottom`, `scroll-padding-left`, `scroll-padding-block`, `scroll-padding-inline`.

### Full Carousel Example

```css
.carousel {
  display: flex;
  gap: 1rem;
  overflow-x: auto;
  scroll-snap-type: x mandatory;
  scroll-padding-inline: 1rem;
  overscroll-behavior-x: contain;

  /* Hide scrollbar but keep functionality */
  scrollbar-width: none;
}

.carousel::after {
  /* Spacer to allow last item to scroll fully into view */
  content: "";
  flex: 0 0 1px;
}

.carousel-item {
  flex: 0 0 min(80vw, 24rem);
  scroll-snap-align: start;
  scroll-snap-stop: always;
}
```

**Accessibility note:** Carousels must be keyboard-navigable. Ensure focusable items inside each slide receive focus in order, and consider adding `role="group"` with `aria-label` on each slide and `aria-roledescription="carousel"` on the container.

Source: [CSS-Tricks -- Practical CSS Scroll Snapping](https://css-tricks.com/practical-css-scroll-snapping/), [MDN -- scroll-snap-type](https://developer.mozilla.org/en-US/docs/Web/CSS/scroll-snap-type)

## Scroll-Driven Animations

Scroll-driven animations tie animation progress to scroll position rather than time. They run on the compositor thread, so they are performant by default -- no JavaScript scroll listeners needed.

### Two Timeline Types

**Scroll progress timeline** -- tracks how far a container has been scrolled (0% at top, 100% at bottom):

```css
.progress-bar {
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  height: 3px;
  background: oklch(60% 0.15 250);
  transform-origin: left;
  animation: grow-width linear both;
  animation-timeline: scroll();
}

@keyframes grow-width {
  from { transform: scaleX(0); }
  to   { transform: scaleX(1); }
}
```

**View progress timeline** -- tracks an element's visibility within its scroll container (0% when entering, 100% when leaving):

```css
.reveal-card {
  animation: fade-in linear both;
  animation-timeline: view();
  animation-range: entry 0% entry 100%;
}

@keyframes fade-in {
  from { opacity: 0; transform: translateY(2rem); }
  to   { opacity: 1; transform: translateY(0); }
}
```

### scroll() Function

Creates an anonymous scroll progress timeline.

```css
animation-timeline: scroll();                    /* Nearest scrollable ancestor, block axis */
animation-timeline: scroll(root);                /* Document scroll */
animation-timeline: scroll(root block);          /* Document scroll, block axis */
animation-timeline: scroll(nearest inline);      /* Nearest ancestor, inline axis */
animation-timeline: scroll(self);                /* Element's own scroll */
```

**Parameters:**
- Scroller: `nearest` (default), `root`, `self`
- Axis: `block` (default), `inline`, `x`, `y`

### view() Function

Creates an anonymous view progress timeline based on element visibility.

```css
animation-timeline: view();                      /* Default: block axis */
animation-timeline: view(inline);                /* Inline axis */
animation-timeline: view(x 200px auto);          /* X axis with inset */
```

### Animation Ranges

Control which portion of the timeline drives the animation:

```css
.element {
  animation-timeline: view();
  animation-range: entry 0% cover 50%;
}
```

**Range keywords for view timelines:**

| Keyword | Meaning |
|---------|---------|
| `entry` | Element entering the scroll port (0% = first pixel visible, 100% = fully inside) |
| `exit` | Element leaving the scroll port |
| `cover` | From first pixel entering to last pixel leaving |
| `contain` | From fully visible to first pixel starting to leave |

### Critical Ordering Rule

`animation-timeline` is reset by the `animation` shorthand. Always declare it **after** the shorthand:

```css
.element {
  animation: fade-in 1s linear both;
  animation-timeline: scroll();  /* Must come after animation shorthand */
}
```

### Fallback for Unsupported Browsers

Use `@supports` to provide a baseline experience when scroll-driven animations are not available:

```css
/* Base state: visible, no animation */
.reveal-card {
  opacity: 1;
  transform: translateY(0);
}

/* Enhance with scroll animation where supported */
@supports (animation-timeline: view()) {
  .reveal-card {
    animation: fade-in linear both;
    animation-timeline: view();
    animation-range: entry 0% entry 100%;
  }
}
```

### Respecting Reduced Motion

Wrap scroll-driven animations in a motion preference check:

```css
@supports (animation-timeline: view()) {
  @media (prefers-reduced-motion: no-preference) {
    .reveal-card {
      animation: fade-in linear both;
      animation-timeline: view();
      animation-range: entry 0% entry 100%;
    }
  }
}
```

Source: [MDN -- animation-timeline](https://developer.mozilla.org/en-US/docs/Web/CSS/animation-timeline), [web.dev -- Scroll-driven Animations](https://web.dev/articles/scroll-driven-animations)

## Smooth Scrolling and Reduced Motion

### scroll-behavior: smooth

Enables animated scrolling for programmatic scrolls (anchor links, `scrollTo()`, `scrollIntoView()`). Only activate when the user has not requested reduced motion:

```css
@media (prefers-reduced-motion: no-preference) {
  html {
    scroll-behavior: smooth;
  }
}
```

**Why conditional:** `scroll-behavior: smooth` causes animated transitions during anchor navigation. Users with vestibular disorders, motion sensitivity, or cognitive disabilities may find this disorienting or nauseating. The `prefers-reduced-motion` media query respects the operating system setting.

**Never set `scroll-behavior: smooth` unconditionally.** Without the media query wrapper, every user gets animation regardless of their accessibility preferences.

For JavaScript-triggered scrolling:

```js
const prefersReducedMotion = window.matchMedia(
  '(prefers-reduced-motion: reduce)'
).matches;

element.scrollIntoView({
  behavior: prefersReducedMotion ? 'instant' : 'smooth',
  block: 'start',
});
```

## Infinite Scroll vs Pagination vs Load More

### Comparison Table

| Factor | Infinite Scroll | Load More Button | Pagination |
|--------|----------------|-----------------|------------|
| **Discoverability** | Users explore without commitment | Balanced -- explicit action, continuous context | Users must choose to navigate |
| **Footer access** | Footer unreachable | Footer reachable after loading | Footer always reachable |
| **Orientation / position** | Users lose track of position | Moderate orientation | URL per page, easy to share/return |
| **Perceived performance** | Fast (preloads next batch) | Fast (loads on demand) | Page reload or full fetch |
| **Accessibility** | Poor -- focus management, screen reader confusion | Moderate -- needs loading announcements | Good -- standard navigation, clear structure |
| **SEO** | Poor -- content hidden behind JS | Poor -- content hidden behind JS | Good -- each page is crawlable |
| **Back button** | Breaks -- position lost on return | Breaks unless state preserved | Works -- URL bookmarkable |
| **Use case** | Social feeds, image browsing | Search results, product listings | Data-heavy tables, documentation, search results |

### UX Research Findings

**When infinite scroll works:**
- Content is homogeneous and exploratory (social media feeds, image galleries)
- Users are browsing, not searching for something specific
- Each item is quickly scannable

**When infinite scroll fails:**
- Users need to compare items or return to a specific position
- Content has a natural endpoint (search results, product categories)
- Users need to reach the footer (contact info, legal links, site map)
- Users want to share or bookmark a position

**Best practice:** Default to pagination for most interfaces. Use "Load More" as a compromise when pagination feels heavy but infinite scroll would break orientation. Reserve infinite scroll for feed-style content only.

### Load More Implementation Notes

```html
<ul id="results" aria-live="polite">
  <!-- Items rendered here -->
</ul>

<button
  type="button"
  id="load-more"
  aria-label="Load more results"
>
  Show more results
</button>
```

- Announce loaded content to screen readers with `aria-live="polite"` on the container
- Move focus to the first new item after loading (or at minimum, keep the button visible)
- Show a loading indicator on the button itself during fetch
- Display the total count if known: "Showing 20 of 142 results"

Source: [NN/g -- Infinite Scrolling](https://www.nngroup.com/articles/infinite-scrolling/)

## Back-to-Top Buttons

### When to Show

- Only on long pages where scrolling back is costly (more than 3-4 viewport heights)
- Reveal after the user scrolls down at least one full viewport height
- Hide when the user is near the top of the page

### Positioning and Implementation

```css
.back-to-top {
  position: fixed;
  inset-block-end: 2rem;
  inset-inline-end: 2rem;
  z-index: 10;
  display: grid;
  place-items: center;
  inline-size: 3rem;
  block-size: 3rem;
  border: 1px solid oklch(58% 0.02 250);
  border-radius: 50%;
  background: oklch(100% 0 0);
  color: oklch(25% 0.02 250);
  box-shadow: 0 2px 8px oklch(0% 0 0 / 0.1);
  cursor: pointer;
  opacity: 0;
  translate: 0 1rem;
  transition: opacity 200ms ease, translate 200ms ease;
}

.back-to-top[data-visible="true"] {
  opacity: 1;
  translate: 0;
}

@media (prefers-reduced-motion: reduce) {
  .back-to-top {
    transition: none;
  }
}
```

```html
<button
  type="button"
  class="back-to-top"
  data-visible="false"
  aria-label="Back to top"
>
  <svg aria-hidden="true" width="20" height="20" viewBox="0 0 20 20">
    <path d="M10 4 L3 11 L5 13 L9 9 L9 16 L11 16 L11 9 L15 13 L17 11 Z"
          fill="currentColor" />
  </svg>
</button>
```

```js
const btn = document.querySelector('.back-to-top');
const observer = new IntersectionObserver(
  ([entry]) => {
    btn.dataset.visible = (!entry.isIntersecting).toString();
  },
  { rootMargin: '-100% 0px 0px 0px' }
);
observer.observe(document.body);

btn.addEventListener('click', () => {
  const prefersReducedMotion = window.matchMedia(
    '(prefers-reduced-motion: reduce)'
  ).matches;
  window.scrollTo({
    top: 0,
    behavior: prefersReducedMotion ? 'instant' : 'smooth',
  });
});
```

**Guidelines:**
- Always use `<button>` with `aria-label` -- never a styled `<div>` or `<a href="#">`
- Do not obscure content -- ensure 2rem+ spacing from edges
- On mobile, position within thumb reach (bottom-right for right-handed, but bottom-right works for both)
- Do not use it as a substitute for good information architecture -- if users constantly need back-to-top, the page may be too long

Source: [NN/g -- Back to Top](https://www.nngroup.com/articles/back-to-top/)

## Overscroll Behaviour

`overscroll-behavior` controls what happens when a user scrolls past the boundary of a scroll container. By default, scrolling "chains" to the parent -- reaching the bottom of a modal continues scrolling the page behind it.

### Preventing Scroll Chaining

```css
/* Modal or drawer -- prevent scroll from leaking to body */
.modal-content {
  overflow-y: auto;
  overscroll-behavior-y: contain;
}

/* Chat widget -- keep scroll inside the message list */
.chat-messages {
  overflow-y: auto;
  overscroll-behavior-y: contain;
}

/* Sidebar navigation -- prevent horizontal overscroll */
.sidebar {
  overflow-y: auto;
  overscroll-behavior: contain;
}
```

### Preventing Pull-to-Refresh

On mobile, pulling down past the top of the page triggers the browser's pull-to-refresh. For single-page applications or interfaces with their own pull-to-refresh, disable the native behaviour:

```css
body {
  overscroll-behavior-y: contain;
}
```

**Caution:** Only set this on `body` if the application provides its own refresh mechanism. Removing pull-to-refresh without a replacement removes a feature users expect.

### Values

| Value | Effect |
|-------|--------|
| `auto` | Default -- scroll chains to ancestor, native overscroll effects active |
| `contain` | Scroll does not chain to ancestor, but local overscroll effects (bounce, glow) still apply |
| `none` | No chaining and no local overscroll effects |

Use `contain` rather than `none` in most cases -- it preserves the platform's native bounce or glow effect, which gives users visual feedback that they have reached the end.

Source: [MDN -- overscroll-behavior](https://developer.mozilla.org/en-US/docs/Web/CSS/overscroll-behavior)

## Scroll Margins and Scroll Padding for Anchor Navigation

When a page has a sticky header, clicking an anchor link (`#section-id`) scrolls the target under the header, hiding it. Two complementary properties solve this.

### scroll-padding-top (Container)

Set on the scroll container (usually `html`) to offset all scroll targets globally:

```css
html {
  scroll-padding-top: 5rem;  /* Match sticky header height */
}
```

This affects all scrolling: anchor links, `scrollIntoView()`, scroll snap targets, and browser "Find on page" results.

### scroll-margin-top (Target Elements)

Set on individual elements to offset their scroll target position:

```css
[id] {
  scroll-margin-top: 5rem;
}

/* Or target specific sections */
.section-heading {
  scroll-margin-top: 5rem;
}
```

`scroll-margin-top` works on the element being scrolled to. It creates an invisible margin that pushes the scroll position up, keeping the element visible below the sticky header.

### When to Use Which

| Property | Set on | Scope | Best for |
|----------|--------|-------|----------|
| `scroll-padding-top` | Scroll container (`html`) | All scroll targets in the container | Global offset for sticky header |
| `scroll-margin-top` | Target element | Individual element | Per-element adjustment, overriding global padding |

Both can be used together. `scroll-margin` on a specific element adds to the container's `scroll-padding`.

### Dynamic Header Heights

If the header height changes (e.g. a banner appears or the header collapses), use a CSS custom property:

```css
:root {
  --header-h: 4rem;
}

html {
  scroll-padding-top: var(--header-h);
}

.site-header {
  position: sticky;
  top: 0;
  block-size: var(--header-h);
}
```

Update `--header-h` in JavaScript if the header height changes dynamically, or use a `ResizeObserver` to keep it in sync.

Source: [MDN -- scroll-margin](https://developer.mozilla.org/en-US/docs/Web/CSS/scroll-margin), [MDN -- scroll-padding](https://developer.mozilla.org/en-US/docs/Web/CSS/scroll-padding)

## Scrollbar Styling

### Standards-Based Approach

The CSS Scrollbars Styling Module Level 1 provides two standard properties:

```css
.scroll-container {
  scrollbar-color: oklch(70% 0.02 250) oklch(95% 0.005 250);
  /* thumb-color   track-color */

  scrollbar-width: thin;
  /* auto | thin | none */
}
```

**`scrollbar-width` values:**

| Value | Effect |
|-------|--------|
| `auto` | Platform default scrollbar width |
| `thin` | Thinner scrollbar (platform decides exact width) |
| `none` | Hides scrollbar but content remains scrollable |

**`scrollbar-color` values:**
- Two colours: first is the thumb, second is the track
- `auto` for platform defaults

### WebKit Fallback

Safari and older Chromium versions need the `::-webkit-scrollbar` pseudo-elements. Use `@supports` to separate the two approaches:

```css
/* Standards-based (Firefox, Chrome 121+) */
.scroll-container {
  scrollbar-color: oklch(70% 0.02 250) oklch(95% 0.005 250);
  scrollbar-width: thin;
}

/* WebKit fallback (Safari, older Chrome) */
@supports not (scrollbar-color: auto) {
  .scroll-container::-webkit-scrollbar {
    width: 8px;
    height: 8px;
  }

  .scroll-container::-webkit-scrollbar-track {
    background: oklch(95% 0.005 250);
  }

  .scroll-container::-webkit-scrollbar-thumb {
    background: oklch(70% 0.02 250);
    border-radius: 4px;
  }
}
```

### Migration Strategy

1. Start with the standard properties (`scrollbar-color`, `scrollbar-width`)
2. Add `::-webkit-scrollbar` inside `@supports not (scrollbar-color: auto)` for Safari
3. Remove the WebKit fallback once Safari ships standard support

### scrollbar-gutter: stable

Prevents layout shift when scrollbar appearance toggles (e.g. content loads and overflow changes from `hidden` to `auto`):

```css
.scroll-container {
  overflow-y: auto;
  scrollbar-gutter: stable;
}
```

This reserves space for the scrollbar even when content does not overflow. Particularly useful for:
- Layouts where content loads asynchronously
- Containers that toggle between overflowing and not overflowing
- Preventing horizontal jank when navigating between pages of different lengths

**Values:** `auto` (default), `stable`, `stable both-edges` (reserves space on both sides for symmetry)

### Never Hide Scrollbars Without Indication

Setting `scrollbar-width: none` or `::-webkit-scrollbar { display: none }` hides the scrollbar entirely. If the content is scrollable, users must discover this on their own.

**If you hide the scrollbar:**
- Provide other visual cues (fade edges, peek of next item, scroll indicators)
- Ensure keyboard and screen reader users can still navigate the content
- Only hide in contexts where swipe/touch is the primary interaction (carousels, horizontal lists)

Source: [MDN -- scrollbar-color](https://developer.mozilla.org/en-US/docs/Web/CSS/scrollbar-color), [MDN -- scrollbar-width](https://developer.mozilla.org/en-US/docs/Web/CSS/scrollbar-width)

## Virtual Scrolling for Large Lists

Virtual scrolling (also called windowing) renders only the visible portion of a list plus a small buffer. Instead of creating DOM nodes for thousands of items, it maintains a small set of elements and recycles them as the user scrolls.

### When to Use

- Lists with more than ~500 items where DOM node count causes jank
- Tables with thousands of rows
- Chat histories or log viewers
- Any scroll container where rendering all items causes measurable performance degradation

**Do not use virtual scrolling when:**
- The list has fewer than a few hundred items (native rendering is fast enough)
- SEO matters and content must be crawlable (virtual content is not in the DOM until scrolled)
- Accessibility is the primary concern and you cannot invest in robust testing

### TanStack Virtual (Recommended Library)

Framework-agnostic virtualisation. Works with React, Vue, Svelte, Solid, and vanilla JS.

```jsx
import { useVirtualizer } from '@tanstack/react-virtual';

function VirtualList({ items }) {
  const parentRef = useRef(null);

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 48,
    overscan: 5,
  });

  return (
    <div
      ref={parentRef}
      style={{ height: '400px', overflow: 'auto' }}
    >
      <div
        style={{
          height: `${virtualizer.getTotalSize()}px`,
          position: 'relative',
        }}
      >
        {virtualizer.getVirtualItems().map((virtualItem) => (
          <div
            key={virtualItem.key}
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              width: '100%',
              height: `${virtualItem.size}px`,
              transform: `translateY(${virtualItem.start}px)`,
            }}
          >
            {items[virtualItem.index].name}
          </div>
        ))}
      </div>
    </div>
  );
}
```

### Accessibility Trade-Offs

Virtual scrolling creates significant accessibility challenges:

- **Screen readers** cannot perceive items outside the rendered window. Users cannot browse the full list with arrow keys or find content with Ctrl+F.
- **Focus management** is fragile. Focused items that scroll out of the rendered range lose focus.
- **Find on page** does not work for non-rendered items.

**Mitigations:**
- Provide a search or filter mechanism so users do not need to scroll through thousands of items
- Set `aria-setsize` and `aria-posinset` on each rendered item so screen readers know the list size and current position
- Ensure the scroll container has `role="list"` (or `role="grid"` for tables) and items have appropriate roles
- Add keyboard shortcuts for jumping to specific positions (first, last, page up/down)
- Consider pagination as an alternative -- it solves the same performance problem while being fully accessible

Source: [TanStack Virtual documentation](https://tanstack.com/virtual/latest)

## Common Scroll Mistakes

### Mistake 1: Scroll Hijacking

Overriding the browser's native scroll speed, direction, or behaviour with JavaScript.

**Problems:**
- Breaks expectations for all users
- Causes motion sickness and disorientation
- Breaks assistive technology input (switch devices, mouth sticks, eye tracking)
- Interferes with trackpad, mouse wheel, and keyboard scroll behaviour inconsistently
- Makes content unreachable for some users

**Rule:** Never override native scroll speed, direction, or inertia. CSS scroll snap and scroll-driven animations enhance scrolling without hijacking it.

### Mistake 2: Hidden Scrollbars Without Visual Cues

Setting `scrollbar-width: none` on a scrollable container without any indication that content overflows.

**Problems:**
- Users do not know there is more content
- Keyboard-only users may not discover scrollable content
- Violates WCAG 1.3.1 (Info and Relationships) when overflow is not communicated

**Fix:** If hiding the scrollbar, add visual affordances: faded edges, a "peek" of the next item, scroll indicators, or explicit "scroll for more" text.

### Mistake 3: Scroll Trapping

A scrollable region (modal, iframe, embedded widget) captures scroll input and the user cannot scroll past it with a mouse wheel or trackpad.

**Problems:**
- Users get stuck in a scroll region they cannot escape
- Particularly harmful for keyboard and switch users

**Fix:** Use `overscroll-behavior: contain` on inner scroll containers to prevent chaining without trapping. Ensure modals can be closed with Escape and that focus management returns to the trigger element.

### Mistake 4: Horizontal Scroll Without Affordance on Mobile

A horizontally scrollable container that looks like static content because nothing indicates it can scroll.

**Fix:**
- Show a partial next item ("peek") to signal horizontal content
- Use scroll snap to reinforce the pattern
- Add subtle scroll indicators (dots, arrows) for non-touch devices

### Mistake 5: Unconditional Smooth Scrolling

Applying `scroll-behavior: smooth` to `html` without a `prefers-reduced-motion` check.

**Fix:** Always wrap in `@media (prefers-reduced-motion: no-preference)`.

### Mistake 6: Missing scroll-padding with Sticky Headers

Anchor links scroll targets under the sticky header, making them invisible.

**Fix:** Set `scroll-padding-top` on the scroll container equal to the sticky header height.

## Browser Support Status

| Feature | Chrome | Firefox | Safari | Edge | Baseline Status |
|---------|--------|---------|--------|------|----------------|
| `scroll-snap-type` | 69+ | 68+ | 11+ | 79+ | Widely available (Apr 2022) |
| `scroll-snap-align` | 69+ | 68+ | 11+ | 79+ | Widely available (Apr 2022) |
| `scroll-snap-stop` | 75+ | 103+ | 15+ | 79+ | Widely available (Jul 2022) |
| `scroll-padding` | 69+ | 68+ | 14.1+ | 79+ | Widely available (Apr 2022) |
| `scroll-margin` | 69+ | 68+ | 14.1+ | 79+ | Widely available (Apr 2022) |
| `scroll-behavior` | 61+ | 36+ | 15.4+ | 79+ | Widely available (Mar 2022) |
| `overscroll-behavior` | 63+ | 59+ | 16+ | 18+ | Widely available (Mar 2023) |
| `scrollbar-color` | 121+ | 64+ | -- | 121+ | Partial (no Safari) |
| `scrollbar-width` | 121+ | 64+ | -- | 121+ | Partial (no Safari) |
| `scrollbar-gutter` | 94+ | 97+ | -- | 94+ | Partial (no Safari) |
| `animation-timeline` | 115+ | -- | -- | 115+ | Limited (Chrome/Edge only) |
| `view()` / `scroll()` | 115+ | -- | -- | 115+ | Limited (Chrome/Edge only) |

**Notes:**
- Scroll snap is safe to use everywhere without fallbacks
- `scrollbar-color` and `scrollbar-width` require a WebKit fallback for Safari
- Scroll-driven animations (`animation-timeline`) require `@supports` fallback -- treat as progressive enhancement only
- Firefox has `animation-timeline` behind a flag; Safari has no implementation yet

## Chapter Summary

1. Use `scroll-snap-type: mandatory` only when every child fits within the viewport; prefer `proximity` for mixed-height content
2. Set `scroll-padding-top` on the scroll container to match sticky header height -- prevents anchor links and snap targets from hiding behind fixed elements
3. Tie animations to scroll position with `animation-timeline: scroll()` or `view()`, but always wrap in `@supports (animation-timeline: view())` and `prefers-reduced-motion: no-preference`
4. Never set `scroll-behavior: smooth` without a `prefers-reduced-motion: no-preference` media query
5. Default to pagination for most interfaces; use infinite scroll only for homogeneous feed-style content where SEO and orientation are not priorities
6. Use `overscroll-behavior: contain` on modals, drawers, and embedded scroll regions to prevent scroll chaining to the body
7. Style scrollbars with the standard `scrollbar-color` and `scrollbar-width` properties first, adding `::-webkit-scrollbar` inside `@supports not (scrollbar-color: auto)` for Safari
8. Use `scrollbar-gutter: stable` on containers where content loads asynchronously to prevent layout shift when the scrollbar appears
9. Reserve virtual scrolling for lists exceeding ~500 items, and provide search/filter as an accessible alternative to scrolling thousands of rows
10. Never override native scroll speed or direction (scroll hijacking) -- enhance with scroll snap and scroll-driven animations instead
11. Always provide visual affordance (peek, indicators, faded edges) when hiding scrollbars on scrollable content
