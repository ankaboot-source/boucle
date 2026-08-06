# Loading States

Learn how to communicate system status during wait times with appropriate feedback patterns, skeleton screens, and accessible loading indicators.

## Response Time Thresholds

Three response time limits govern which feedback pattern to use (Jakob Nielsen, NNGroup):

| Threshold | User Perception | Required Feedback |
|-----------|----------------|-------------------|
| **< 100ms** | Instantaneous, direct manipulation | None - display result immediately |
| **100ms - 1s** | Noticeable delay, thought flow unbroken | Subtle indicator (cursor change, button state) |
| **1s - 10s** | Conscious waiting, attention held | Skeleton screen or spinner with status text |
| **> 10s** | Attention lost, user may leave | Determinate progress bar with cancel option |

**Guidelines:**
- Provide visual feedback the moment a user initiates an action (button state change, page transition)
- Showing a loader for waits under 1 second harms perceived performance - delay the indicator by 300ms
- For 2-10 second waits, combine a busy cursor with inconspicuous progress updates
- For waits over 10 seconds, show estimated completion time and a clear way to cancel

## Skeleton Screens

Skeleton screens display wireframe-like placeholders that preview the final page layout during loading. They reduce perceived wait time by turning passive waiting (staring at a spinner) into active waiting (processing the emerging layout).

### Three Types of Skeleton Screen

**1. Static content skeleton (recommended)**
- Grey boxes and lines that mimic the structure of the final content
- Shapes match the dimensions and positions of real headings, text blocks, and images

**2. Animated skeleton (shimmer)**
- Adds a sweeping gradient animation across the placeholder shapes
- Creates a sense of progress and activity
- Can be distracting or trigger accessibility issues for some users

**3. Frame-only skeleton (avoid)**
- Shows only header, footer, and background - no content wireframe
- Users assume the page is broken if they wait too long on a mostly blank screen

### When to Use Skeleton Screens

**Use when:**
- Full-page loads take 1-10 seconds
- Loading content-heavy pages (feeds, dashboards, article lists)
- The layout structure is predictable before data arrives

**Avoid when:**
- Page loads in under 1 second (unnecessary, adds visual noise)
- Loading exceeds 10 seconds (use a determinate progress bar instead)
- The layout depends entirely on the data (unknown structure)
- Loading a single small component (use an inline spinner instead)

### Layout Matching

The skeleton must accurately represent the final layout to set correct expectations:

```html
<article class="card" aria-busy="true">
  <div class="card__skeleton" aria-hidden="true">
    <div class="skeleton-image"></div>
    <div class="skeleton-heading"></div>
    <div class="skeleton-line"></div>
    <div class="skeleton-line skeleton-line--short"></div>
  </div>
  <span class="visually-hidden">Loading article</span>
</article>
```

```css
.skeleton-image {
  width: 100%;
  aspect-ratio: 16 / 9;
  background: oklch(92% 0.005 0);
  border-radius: 8px;
}

.skeleton-heading {
  width: 70%;
  height: 24px;
  margin-block-start: 16px;
  background: oklch(92% 0.005 0);
  border-radius: 4px;
}

.skeleton-line {
  width: 100%;
  height: 14px;
  margin-block-start: 8px;
  background: oklch(92% 0.005 0);
  border-radius: 4px;
}

.skeleton-line--short {
  width: 40%;
}
```

### Cross-Fade Transition

Fade from skeleton to real content rather than swapping instantly:

```css
.card__skeleton {
  transition: opacity 200ms ease-out;
}

.card[aria-busy="false"] .card__skeleton {
  opacity: 0;
  pointer-events: none;
}
```

## Shimmer Animation (CSS)

The shimmer effect animates a gradient layer across skeleton shapes to signal activity. Use OKLCH colours for consistency with the project palette:

```css
.skeleton-shimmer {
  background:
    linear-gradient(
      90deg,
      oklch(92% 0.005 0) 0%,
      oklch(96% 0.003 0) 40%,
      oklch(92% 0.005 0) 80%
    );
  background-size: 200% 100%;
  animation: shimmer 1.5s ease-in-out infinite;
}

@keyframes shimmer {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}

@media (prefers-reduced-motion: reduce) {
  .skeleton-shimmer {
    animation: none;
  }
}
```

### Using `:empty` for Automatic Skeleton Display

The `:empty` pseudo-class shows the skeleton only when a container has no content, removing it automatically when data arrives:

```css
.card:empty {
  background:
    linear-gradient(
      90deg,
      oklch(92% 0.005 0) 0%,
      oklch(96% 0.003 0) 40%,
      oklch(92% 0.005 0) 80%
    );
  background-size: 200% 100%;
  animation: shimmer 1.5s ease-in-out infinite;
  min-height: 200px;
  border-radius: 8px;
}
```

### `content-visibility` for Off-Screen Performance

Skip rendering skeleton animations that are not visible in the viewport:

```css
.card {
  content-visibility: auto;
  contain-intrinsic-size: auto 300px;
}
```

## Spinners and Progress Indicators

### Indeterminate Indicators (Spinners)

Use when the wait duration is unknown or between 1-10 seconds:

- Animated spinner or circular indicator showing system activity
- No timeline information - signals "something is happening"
- Place near the content being loaded, not centred on the page
- Include descriptive text: "Loading comments..." or "Updating settings..."

### Determinate Indicators (Progress Bars)

Use for waits over 10 seconds or when processing measurable units:

- Visual bar filling from 0-100%
- Shows current progress, completion status, and remaining work
- Start the animation slower and accelerate toward completion - exceeding expectations creates more satisfaction than disappointing early speed
- Provide approximate timeframes: "About 3 minutes remaining"
- Always provide a cancel option for long processes

### Placement Guidelines

- Place the indicator where the user is already looking
- Full-page loads: skeleton screen over the content area
- Button actions: spinner inside the button (see Button Loading States)
- List/feed: spinner at the bottom of existing content
- Modal actions: spinner within the modal

## Button Loading States

When a button triggers an action that takes more than 300ms, show a loading state on the button itself. Users are already looking at the button when they click it.

### Implementation Pattern

```html
<button type="submit" class="btn btn--primary" aria-busy="false">
  <svg class="btn__spinner" aria-hidden="true" viewBox="0 0 24 24"
       fill="none" stroke="currentColor" stroke-width="2">
    <circle cx="12" cy="12" r="10" opacity="0.25" />
    <path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round" />
  </svg>
  <span class="btn__label">Save post</span>
</button>
```

```css
.btn__spinner {
  display: none;
  width: 1em;
  height: 1em;
  animation: spin 0.6s linear infinite;
}

.btn[aria-busy="true"] .btn__spinner {
  display: inline-block;
}

.btn[aria-busy="true"] .btn__label {
  /* Optionally change label text via JS: "Save post" -> "Saving..." */
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

@media (prefers-reduced-motion: reduce) {
  .btn__spinner {
    animation-duration: 1.5s;
  }
}
```

### Button Loading Guidelines

- The spinner must not change the button dimensions - reserve space or replace the icon
- Change the label to describe the ongoing process: "Save post" becomes "Saving..."
- Prevent double submission: set `aria-disabled="true"` during loading
- Prefer `aria-disabled="true"` over `disabled` - `aria-disabled` keeps the button focusable and discoverable by screen readers while preventing activation
- Set `aria-busy="true"` on the button to indicate processing
- On success, briefly show a check icon or "Saved" before restoring the default state

### `aria-disabled` vs `disabled`

```css
/* aria-disabled: stays focusable, screen readers can still reach it */
.btn[aria-disabled="true"] {
  opacity: 0.6;
  cursor: not-allowed;
  pointer-events: none;
}

/* disabled: removed from tab order, invisible to some screen readers */
.btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}
```

Use `aria-disabled="true"` for loading states. Use the native `disabled` attribute only when a button is permanently unavailable (and provide an explanation why).

## Optimistic UI

Optimistic UI shows the result of an action before the server confirms it, making the interface feel instant. The UI assumes success and rolls back only if the server returns an error.

### When to Use Optimistic UI

**Good candidates:**
- Like/favourite toggles
- Adding items to a list
- Marking items as read/unread
- Simple state changes with high success rates (> 99%)
- Server response time under 2 seconds

**Avoid for:**
- Payment processing
- Account deletion or other destructive actions
- Actions with complex server-side validation
- Operations that depend on external services with unreliable availability
- Anything where showing a false success state causes real harm

### Implementation Pattern

```javascript
async function toggleFavourite(itemId) {
  // 1. Store previous state for rollback
  const previousState = getItemState(itemId);

  // 2. Apply optimistic update immediately
  updateUI(itemId, { isFavourite: !previousState.isFavourite });

  try {
    // 3. Send request to server in background
    await api.toggleFavourite(itemId);
  } catch (error) {
    // 4. Rollback on failure
    updateUI(itemId, previousState);
    showToast("Could not update. Please try again.");
  }
}
```

### Rollback Strategy

- Always store the previous state before applying the optimistic update
- On failure, revert to the stored state and show a non-intrusive error (toast notification)
- Never silently fail - the user must know the action did not complete
- Keep rollback animations subtle: a quick fade is enough, avoid dramatic reversals

## Accessibility

### `aria-busy` for Loading Regions

Set `aria-busy="true"` on a container while its content is being updated. This tells assistive technology to wait before announcing the new content:

```html
<section aria-busy="true" aria-live="polite">
  <!-- Skeleton or loading indicator -->
</section>
```

When loading completes:
1. Replace skeleton content with real content
2. Set `aria-busy="false"`
3. The `aria-live="polite"` region will then announce the update

**Caveats:**
- Support for `aria-busy` varies across browser/screen reader combinations
- Pair `aria-busy` with `aria-hidden="true"` on the skeleton shapes themselves so screen readers skip the placeholder content
- Include a visually hidden "Loading" text that screen readers can announce

### Visually Hidden Loading Text

```css
.visually-hidden {
  position: absolute;
  overflow: hidden;
  clip: rect(1px, 1px, 1px, 1px);
  width: 1px;
  height: 1px;
  white-space: nowrap;
}
```

```html
<div aria-busy="true">
  <div class="skeleton" aria-hidden="true"><!-- shapes --></div>
  <span class="visually-hidden">Loading content</span>
</div>
```

### `aria-live` Regions for Status Updates

Use `aria-live="polite"` for loading completion announcements. Use `aria-live="assertive"` only for errors that require immediate attention:

```html
<div role="status" aria-live="polite">
  <!-- Empty initially, populated on completion -->
</div>
```

### Screen Reader Announcements

- Announce the start of loading: "Loading articles"
- Announce completion: "5 articles loaded"
- Announce errors: "Failed to load articles. Try again."
- Do not announce every skeleton shape or animation frame

### Contrast for Skeleton Shapes

Skeleton placeholder shapes must meet WCAG 1.4.11 non-text contrast requirements:
- Minimum 3:1 contrast ratio against the page background
- `oklch(92% 0.005 0)` on `oklch(100% 0 0)` provides approximately 1.2:1 - below WCAG requirements
- If skeletons serve as meaningful indicators of content position, use a darker fill: `oklch(82% 0.01 0)` provides approximately 2:1
- Skeleton screens that are purely decorative (an animated shimmer on a neutral background) may claim an exemption, but err on the side of sufficient contrast

### Reduced Motion

Always respect `prefers-reduced-motion`. Disable shimmer animations but keep static skeleton shapes visible:

```css
@media (prefers-reduced-motion: reduce) {
  .skeleton-shimmer {
    animation: none;
  }
}
```

### Cursor Feedback

Set `cursor: progress` on loading regions so mouse users see visual feedback:

```css
[aria-busy="true"] {
  cursor: progress;
}
```

## Perceived Performance

Perceived performance is how fast the interface feels, regardless of actual load time. Improving perceived performance often has a greater impact on user satisfaction than improving actual speed.

### Progressive Loading

Load and display content in stages, most important first:

1. Render the page shell (navigation, layout structure) immediately
2. Show skeleton placeholders for content areas
3. Load primary content (headings, first paragraph, hero image)
4. Load secondary content (comments, recommendations, sidebar)

### LCP Optimisation

Largest Contentful Paint should be under 2.5 seconds for 75% of page visits:

- Never lazy-load the LCP element - set `fetchpriority="high"` on it
- Inline critical CSS or keep stylesheets smaller than the LCP resource
- Avoid third-party domains for the LCP image (reuse existing connections)
- Use responsive images with `srcset` and modern formats (AVIF, WebP)
- Implement server-side rendering so images are discoverable from HTML source

### Lazy Loading

Defer off-screen content to prioritise visible content:

```html
<!-- LCP image: never lazy-load, high priority -->
<img src="hero.avif" alt="..." fetchpriority="high" width="800" height="450">

<!-- Below-fold images: lazy-load -->
<img src="feature.avif" alt="..." loading="lazy" width="400" height="300">
```

### Prevent Layout Shift with `aspect-ratio`

Images and embeds without dimensions cause content to jump when they load. Always set `aspect-ratio` or explicit `width`/`height`:

```css
.card__image {
  width: 100%;
  aspect-ratio: 16 / 9;
  object-fit: cover;
  background: oklch(92% 0.005 0); /* Placeholder colour while loading */
}
```

This reserves space in the layout before the image arrives, preventing Cumulative Layout Shift (CLS target: < 0.1).

## Decision Matrix: When to Use Which Pattern

| Scenario | Wait Time | Pattern | Why |
|----------|-----------|---------|-----|
| Button form submit | 0.3-2s | Button spinner + label change | User already looking at button |
| Like/toggle action | < 2s | Optimistic UI | High success rate, instant feel |
| Full page load | 1-10s | Skeleton screen | Previews layout, reduces perceived wait |
| Single component load | 1-5s | Inline spinner with text | Localised feedback |
| File upload | 5-60s | Determinate progress bar | User needs progress and cancel option |
| Background save | < 2s | No indicator (or subtle) | Don't interrupt workflow |
| Search results | 1-3s | Skeleton of result list | Known layout, turns waiting into scanning |
| Infinite scroll | 0.5-3s | Spinner at list bottom | Contextual, non-blocking |
| Data export | 10s+ | Progress bar + cancel | Long process needs completion estimate |

## Common Loading State Mistakes

### Mistake 1: Layout shift when loading state appears or disappears
- Skeleton dimensions do not match real content dimensions
- Spinner insertion pushes surrounding elements
- Fix: Reserve exact space with `aspect-ratio`, fixed heights, and `min-height`

### Mistake 2: Blocking all interaction during loading
- Disabling the entire page when only one section is loading
- Fix: Scope the loading indicator and `aria-busy` to the specific region being updated

### Mistake 3: No feedback at all for 1-2 second waits
- Users assume their click did not register and click again
- Fix: Provide instant visual feedback (button state change) within 100ms, show spinner after 300ms

### Mistake 4: Showing a spinner for under 300ms
- A flash of spinner creates visual noise and feels broken
- Fix: Delay showing the spinner by 300ms - if the action completes before then, skip it

### Mistake 5: No rollback for optimistic UI
- Silently swallowing server errors after showing optimistic success
- Fix: Always store previous state and revert on failure with a clear error message

### Mistake 6: Skeleton that does not match the loaded layout
- Users build incorrect mental models from misleading placeholders
- Fix: Skeleton shapes must mirror the position, size, and count of real content elements

### Mistake 7: Animated skeleton with no reduced motion support
- Can trigger vestibular disorders in users with motion sensitivity
- Fix: Wrap all shimmer animations in `@media (prefers-reduced-motion: no-preference)`

### Mistake 8: Using a frame-only skeleton
- Header and footer with empty content area looks broken, not loading
- Fix: Always include content-area placeholders that hint at the incoming layout

### Mistake 9: No screen reader announcements
- Sighted users see the spinner, but screen reader users get no feedback
- Fix: Use `aria-busy`, `aria-live`, visually hidden loading text, and announce completion

### Mistake 10: Progress bar that stalls or jumps backward
- Destroys user trust in the estimated completion
- Fix: Start slower and accelerate toward completion - never move backward

## Chapter Summary

1. Use response time thresholds to pick the right feedback pattern: no indicator under 100ms, subtle change up to 1s, skeleton or spinner for 1-10s, progress bar over 10s
2. Skeleton screens must mirror the final layout structure - never use frame-only skeletons that show only header and footer
3. Delay showing spinners by 300ms to avoid flashing indicators on fast responses
4. Button loading states belong on the button itself: inline spinner, label change ("Saving..."), `aria-busy="true"`, and `aria-disabled="true"` to prevent double submission
5. Use optimistic UI for simple, high-success-rate actions (likes, toggles) - always store previous state and roll back on failure
6. Announce loading to screen readers with `aria-busy`, `aria-live="polite"`, and visually hidden status text - announce both start and completion
7. Shimmer animations use a moving linear gradient in OKLCH colours and must respect `prefers-reduced-motion`
8. Prevent layout shift with `aspect-ratio` on images and embeds, and ensure skeleton dimensions match real content
9. Optimise LCP by never lazy-loading the largest content element and setting `fetchpriority="high"`
10. Use determinate progress bars for waits over 10 seconds - start slow, accelerate toward completion, and always provide a cancel option
11. Scope loading indicators to the specific region being updated - never block the entire page when only one section is loading
