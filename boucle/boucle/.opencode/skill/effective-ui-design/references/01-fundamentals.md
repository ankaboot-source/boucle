# Fundamentals

Overarching UI design principles that form the foundation of all guidelines.

## Minimise Usability Risks

Base design decisions on risk - the risk that someone could have difficulty using an interface.

**Common usability risks:**
- Thin, light grey text - some may find it difficult to read
- Icons without labels - some might not understand what icons mean (especially those with cognitive/vision impairments)
- Coloured headings - could be mistaken for links
- Navigation with only arrows/dots (e.g. carousels) - use descriptive labels instead that tell users what content awaits them

**Guidelines:**
- Consider people with poor eyesight, low computer literacy, reduced dexterity and cognitive ability
- Meet WCAG 2.1 level AA requirements as minimum
- Keep an eye out for potential usability risks
- If anything is slightly vague, confusing or unclear - simplify it

## Have a Logical Reason for Every Design Detail

Every element must have a purpose that improves usability.

- Design using objective logic, rather than subjective opinion
- Be able to articulate the rationale behind each decision
- "That looks nice" or "I don't like it" are NOT logical or constructive feedback
- Focus on HOW it works and WHY it works that way

## Minimise Interaction Cost

Interaction cost = sum of physical and mental effort required to achieve a task.

**Actions that add to interaction cost:**
- Looking, scrolling, searching, reading
- Clicking, waiting, typing
- Thinking, remembering

### How to Minimise Interaction Cost

**1. Keep related actions close (Fitts's Law)**
- The closer and larger a target, the faster it is to click
- Keep actions close to the element they relate to
- Ensure sufficient target area: minimum 48pt x 48pt

**2. Reduce distractions**
- Avoid animated banners, pop-ups, unnecessary visuals
- Remove attention-grabbing elements that pull focus from tasks

**3. Minimise choice (Hick's Law)**
- Time to make a decision increases with number and complexity of choices
- Reduce choices to speed up decisions
- Highlight recommended or popular items

## Minimise Cognitive Load

Cognitive load = amount of brain power required to use an interface.

**Quick ways to reduce cognitive load:**
- Remove unnecessary styles, information, and decisions
- Break up information into smaller groups
- Use conventional design patterns (Jakob's Law)
- Maintain consistency - similar elements look and work similarly
- Create clear visual hierarchy

## Create a Design System

A system of predefined options and guidelines for efficient design decisions.

### 1. Set Predefined Style Options

**Colour Options (Colour Palette):**
```
Brand       - Interactive elements (buttons, links)
Text strong - Headings, primary text
Text weak   - Secondary text
Stroke strong - Form borders, icons
Stroke weak - Decorative borders
Fill        - Secondary backgrounds
Background  - White or near-white
```

**Typography Options:** See [05-typography.md](05-typography.md) for the type scale (1.200 Minor Third, base 16px).

**Spacing Options:** See [04-layout-spacing.md](04-layout-spacing.md) for the 8pt grid (XS–XXL).

**Shadow Options:** See [03-colour.md](03-colour.md) for the two shadow levels (Raised, Overlay).

**Border Radius Options:**
- Small: 8pt
- Medium: 16pt
- Large: 32pt

**Icon Options:**
- Use SVG icons exclusively — never emoji, bitmap icons, or icon fonts
- Pick one icon set and use it consistently (e.g. Lucide, Heroicons, Phosphor)
- Default size: `1.5rem` (24px) for UI icons, `1rem` (16px) for inline icons
- Use `currentColor` so icons inherit the parent's text colour
- Match stroke width to the surrounding font weight (2px stroke ≈ regular weight, 2.5px ≈ bold)

```html
<!-- Decorative icon (label provides meaning) -->
<button>
  <svg aria-hidden="true" width="24" height="24" viewBox="0 0 24 24"
       fill="none" stroke="currentColor" stroke-width="2">
    <path d="..."/>
  </svg>
  Save post
</button>

<!-- Standalone icon (icon IS the label) -->
<button aria-label="Close dialog">
  <svg aria-hidden="true" width="24" height="24" viewBox="0 0 24 24"
       fill="none" stroke="currentColor" stroke-width="2">
    <path d="..."/>
  </svg>
</button>
```

**Icon accessibility rules:**
- Icons next to text: add `aria-hidden="true"` to the SVG (the text is the label)
- Icon-only buttons: add `aria-label` to the button (not to the SVG)
- Never use icons without a visible text label unless space is extremely limited — always prefer icon + text over icon alone

### 2. Create Reusable Modules

- Start with smallest components (buttons, avatars, form inputs)
- Combine small components to create larger ones
- Arrange components in specific layouts for reusable page templates
- Create a component library / UI kit

### 3. Define Usage Guidelines

- How to use components and visual styles
- How to write interface text (copywriting)
- Examples from the book:
  - Indicate interactive elements using brand colour
  - Use sentence case
  - Left align buttons and text
  - Avoid disabled buttons
  - Front-load text
  - Be concise, use plain language

## Ensure an Interface is Accessible

Design interfaces that can be used by everyone, regardless of disability.

**Consider:**
- Blindness, low vision, colour blindness
- Motor impairment
- Mental disabilities

**Key principles:**
- Provide comparable experience for all
- Meet WCAG 2.1 level AA as minimum
- Include people with disabilities in usability testing

### Use Semantic HTML

Use meaningful HTML elements instead of generic `<div>` everywhere:

```html
<!-- Don't: ambiguous structure -->
<div>
  <div>Logo + Nav</div>
  <div>
    <div>Main content</div>
    <div>Sidebar</div>
  </div>
  <div>Footer</div>
</div>

<!-- Do: clear structure -->
<header>Logo + Nav</header>
<nav>Navigation</nav>
<main>
  <section>Main content</section>
  <aside>Sidebar</aside>
</main>
<footer>Footer</footer>
```

**Why it matters:**
- Screen readers use semantic elements to navigate (jump to `<nav>`, skip to `<main>`)
- Improves SEO and machine readability
- Makes code self-documenting

**Key elements:** `<header>`, `<nav>`, `<main>`, `<section>`, `<article>`, `<aside>`, `<footer>`, `<figure>`, `<figcaption>`, `<search>`

The `<search>` element (Baseline 2023) wraps any search or filtering interface — not just site search, but also filter controls on a results page:

```html
<search>
  <form action="/search">
    <label for="q">Search</label>
    <input id="q" type="search" name="q">
    <button type="submit">Search</button>
  </form>
</search>
```

It provides a semantic landmark that screen readers expose as a "search" role, letting users jump directly to it.

### Provide Skip Links

Skip links let keyboard users bypass repeated navigation and jump directly to the main content. This is a WCAG 2.4.1 Level A requirement (Bypass Blocks).

```html
<body>
  <a href="#main-content" class="skip-link">Skip to main content</a>
  <header><!-- navigation --></header>
  <main id="main-content" tabindex="-1">
    <!-- page content -->
  </main>
</body>
```

The `tabindex="-1"` on the target element ensures browsers move focus there when the skip link is activated. Without it, some browsers scroll to the element but leave focus on the link.

```css
.skip-link {
  position: absolute;
  transform: translateY(-100%);
  transition: transform 0.2s ease-out;
  z-index: 9999;
  background: var(--bg, #fff);
  padding: 8px 16px;
}

.skip-link:focus-visible {
  transform: translateY(0);
}
```

**Guidelines:**
- Make the skip link the first focusable element on the page
- Hide it visually but keep it accessible (no `display: none`)
- Reveal it on focus so sighted keyboard users can see it
- Point to the `<main>` element (or equivalent primary content container)

### Assistive Technology

**Screen Readers:**
- Software that describes interface using speech or braille
- Users use keyboard to step through elements
- Mobile users swipe or drag finger across screen

**Screen Magnifiers:**
- Enlarges part of interface for people with low vision
- Users have limited view - can only see small part at a time
- Important: Keep this in mind when designing

### Good Accessibility Benefits Everyone

- Anyone could get temporary disability (eye/arm injury)
- Situational disabilities (bright sunny day affecting screen visibility)
- Good accessibility = great usability

### Never Disable Zoom

Setting `user-scalable=no` or `maximum-scale=1` on the viewport meta tag prevents users from zooming in. This violates WCAG 2.1 Success Criterion 1.4.4 (Resize Text, Level AA) and makes the interface unusable for people with low vision.

```html
<!-- Never do this -->
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">

<!-- Correct -->
<meta name="viewport" content="width=device-width, initial-scale=1">
```

**If zoom is disabled to prevent double-tap-to-zoom delay on mobile:** Use `touch-action: manipulation` on interactive elements instead. This disables double-tap zoom on those elements while keeping pinch-to-zoom available everywhere:

```css
button, a, input, select, textarea {
  touch-action: manipulation;
}
```

## Design for Affordance

Affordance is an object's ability to convey its function through its appearance. A raised button suggests pressing; a handle suggests pulling; text that flows off the edge suggests scrolling.

**In digital design:**
- Buttons should look tappable (depth, fill colour, hover states)
- Scrollable areas should show partial content at the edges to hint at more
- Draggable items should have grab handles or visual weight
- Input fields should look like containers that accept text

**The risk of flat design:** Removing all depth cues can make interfaces ambiguous. Ensure interactive elements are still distinguishable from static content through colour, weight, or shape.

## Use Common Design Patterns (Jakob's Law)

Stick with conventional design patterns that people are already familiar with.

- Building on existing mental models means less learning time
- Reduces usability issues, cognitive load, and interaction cost
- Example: Accordion components for expandable content

**Play it safe:**
- Use conventional form field styles
- Save time on usability testing
- Focus creativity on unique selling points

## Use the 80/20 Rule (Pareto Principle)

Roughly 80% of effects come from 20% of causes.

**In product design:**
- ~80% of users use 20% of features
- ~80% of complaints come from 20% of issues
- ~80% of attention is spent on 20% of a page

**Application:**
- Prioritise the small number of things with largest impact
- Optimise for tasks most people will be doing
- Don't over-invest in edge cases

## Keep Costs in Mind

Every minute spent costs money.

**Ways to improve efficiency:**
- Use existing design systems, templates, icon sets
- Outsource time-intensive tasks
- Stick with familiar UI patterns
- Learn technical constraints of implementation
- Talk to developers early and often
- Simple approach is usually cheaper and easier

## Be Consistent

Similar elements look and work in a similar way.

### Within Your Product
- Create design system with guidelines for components, templates, visual styles, language
- Predictable functionality improves usability and reduces errors

### With Other Products
- Maintain consistency with well-established products
- Follow platform guidelines (iOS, Android) unless they test poorly
- Follow well-established, accessible UI patterns

**Conventional patterns:**
- Text links are underlined
- Checkboxes are small squares with tick icon
- Input fields are rectangles with label on top

## Clearly Indicate Interaction States

Interactive elements must change appearance when interacted with.

**8 Interaction States Checklist:**

| State | When | Design Treatment |
|-------|------|------------------|
| **Default** | At rest | Base styling |
| **Hover** | Pointer over (not touch) | Subtle lift, colour shift |
| **Focus** | Keyboard/programmatic focus | Visible focus ring |
| **Active/Press** | Being clicked/tapped | Pressed in, darker |
| **Disabled** | Not interactive | Reduced opacity, no pointer |
| **Loading** | Processing | Spinner, skeleton |
| **Error** | Invalid state | Red border, icon, message |
| **Success** | Completed | Green check, confirmation |

**Common miss:** Designing hover without focus. Keyboard users never see hover states - they need visible focus indicators.

### Focus Rings with :focus-visible

Never remove focus indicators without replacement - it's an accessibility violation.

```css
/* Show focus ring only for keyboard navigation (~96% support) */
:focus-visible {
  outline: 2px solid var(--brand);
  outline-offset: 2px;
}
```

Browsers that support `:focus-visible` automatically suppress focus rings on mouse/touch clicks. No need for a separate `:focus { outline: none }` rule.

**Focus ring requirements:**
- High contrast (3:1 minimum against adjacent colours)
- 2-3px thick
- Offset from element (not inside it)
- Consistent across all interactive elements

### Keyboard Navigation in Composite Widgets

Composite widgets — tab bars, toolbars, menu bars, listboxes, tree views — should act as a single Tab stop. Users press Tab to reach the widget, then use arrow keys to move between items within it. This is the roving tabindex pattern defined in the WAI-ARIA Authoring Practices Guide (APG).

**The pattern:**
1. The focused item gets `tabindex="0"`, all other items get `tabindex="-1"`
2. Arrow keys move focus and update `tabindex` values
3. Tab moves focus out of the widget entirely

```html
<div role="tablist">
  <button role="tab" tabindex="0" aria-selected="true">Tab 1</button>
  <button role="tab" tabindex="-1">Tab 2</button>
  <button role="tab" tabindex="-1">Tab 3</button>
</div>
```

```javascript
tablist.addEventListener('keydown', (e) => {
  const tabs = [...tablist.querySelectorAll('[role="tab"]')];
  const current = tabs.indexOf(document.activeElement);
  let next;

  if (e.key === 'ArrowRight') next = (current + 1) % tabs.length;
  else if (e.key === 'ArrowLeft') next = (current - 1 + tabs.length) % tabs.length;
  else return;

  tabs[current].tabIndex = -1;
  tabs[next].tabIndex = 0;
  tabs[next].focus();
});
```

**When to use roving tabindex:**
- Tab bars, toolbars, menu bars (horizontal: Left/Right arrows)
- Listboxes, tree views (vertical: Up/Down arrows)
- Grids and data tables (all four arrow keys)

**When NOT needed:**
- A simple list of links or buttons — each is an independent Tab stop
- Form fields in sequence — standard Tab order is correct

## Animation and Motion

Animation adds context that static interfaces can't provide. It offloads spatial reasoning to the brain's visual cortex, reducing cognitive load and increasing perceived speed. But animation is a powerful tool that must be used purposefully — decorative animation wears on users after the fiftieth viewing.

**The test for good animation:** If users notice your animation, it may be doing too much. Good microinteraction animations are seamless — users don't consciously register them, they just feel the interface is responsive and clear.

### Animation Patterns

Use these categories to identify and communicate the purpose of an animation:

| Pattern | Purpose | Example |
|---------|---------|---------|
| **Transition** | Move users between places/tasks in the information space | Page-to-page slide, tab switching |
| **Supplement** | Bring info on/off page without changing location or task | Tooltip appearing, dropdown opening |
| **Feedback** | Connect user action to interface reaction | Button press ripple, form validation |
| **Demonstration** | Show how something works instead of telling | Onboarding walkthrough, feature tour |
| **Decoration** | Purely aesthetic, no new information | Background particle effects |

**Prioritisation:** Transitions and feedback provide the most cognitive benefit. Decorations provide the least and risk annoying users. When resources are limited, prioritise animations that answer "What just happened?" for the user.

**Questions to justify an animation:**
- Does it show the user where information came from or went to?
- Does it indicate progress?
- Does it move the user through an information space?
- Does it explain something faster than words could?

### The Cone of Vision

The eye is most sensitive to colour and detail at the centre (foveal region). Peripheral vision is blurry but highly sensitive to motion.

**Practical implications:**
- **Centre of vision:** Colour fades and small movements are sufficient to draw attention
- **Peripheral vision:** Use motion to attract attention — colour changes alone may go unnoticed
- Two independently moving objects on opposite sides of the screen cannot both be tracked
- Overusing motion causes "banner blindness" — the brain learns to ignore excessive animacy

### Easing (Timing Functions)

Easing describes the rate of change over time. Different easings suit different situations:

| Easing | CSS | Best For |
|--------|-----|----------|
| **Ease-out** (deceleration) | `ease-out` | User-initiated actions (clicks, taps). Feels snappy and responsive |
| **Ease-in** (acceleration) | `ease-in` | System-initiated animations (alerts, pop-ups). Starts slowly, less startling |
| **Ease-in-out** | `ease-in-out` | Moving elements toward each other |
| **Linear** | `linear` | Fades and colour changes only. Motion with linear easing looks mechanical |

For unique brand feel, use custom `cubic-bezier()` curves. Keep a chart of your project's easings to maintain consistency.

### Duration (Timing Scale)

Use a predefined set of durations for consistency, similar to a typographic scale:

```
Immediate:  100ms  — Fades, colour changes under cursor/finger
Fast:       300ms  — Button presses, toggles, responsive interactions
Slower:     400ms  — Elements moving on page, dropdowns, tooltips
Deliberate: 700ms  — Large movements across screen, demonstrations
```

These values follow a Fibonacci-like relationship (100 + 300 = 400, 300 + 400 = 700) creating natural harmony.

**Guidelines:**
- Colour/opacity changes under the cursor feel slow above 100ms
- Moving elements across the page needs 300ms+ to track
- Centre-of-vision animations need shorter durations (70-200ms)
- Peripheral animations benefit from longer durations (300-700ms)
- When in doubt, halve your duration — developers consistently overestimate how long animations should run

### Spring Easing with linear()

The `linear()` easing function (Baseline 2023) accepts a list of output values that the browser interpolates between, enabling easing curves that `cubic-bezier()` cannot express — including spring physics.

Spring-based motion feels more natural than cubic-bezier because it models physical deceleration. Apple (iOS 17+), Framer Motion, and the animations.dev community have converged on two parameters: **duration** and **bounce** (0 = critically damped, no overshoot; positive = elastic overshoot).

**Default to critically damped springs (bounce = 0)** — they feel responsive without being playful. Reserve bouncy springs for confirmations, celebrations, or deliberately playful interfaces.

```css
:root {
  /* Critically damped spring — natural deceleration, no overshoot */
  --ease-spring: linear(
    0, 0.009, 0.035, 0.078, 0.136, 0.206, 0.286, 0.373,
    0.464, 0.557, 0.65, 0.738, 0.819, 0.891, 0.951,
    0.998, 1.029, 1.047, 1.051, 1.044, 1.029, 1.01,
    0.99, 0.974, 0.965, 0.961, 0.963, 0.969, 0.978,
    0.988, 0.997, 1.003, 1.005, 1.003, 1
  );

  /* Gentle bounce — for playful/confirming interactions */
  --ease-spring-bouncy: linear(
    0, 0.004, 0.016, 0.035, 0.063, 0.098, 0.141, 0.191,
    0.25, 0.316, 0.391, 0.474, 0.566, 0.666, 0.775,
    0.893, 1.02, 1.086, 1.125, 1.139, 1.131, 1.106,
    1.067, 1.019, 0.968, 0.921, 0.882, 0.855, 0.843,
    0.849, 0.871, 0.905, 0.946, 0.989, 1.027, 1.054,
    1.067, 1.063, 1.044, 1.015, 0.983, 0.956, 0.94,
    0.939, 0.953, 0.977, 1.005, 1.026, 1.035, 1.029,
    1.012, 0.993, 0.98, 0.977, 0.984, 0.997, 1.009,
    1.014, 1.009, 0.999, 0.992, 0.99, 0.994, 1.001, 1
  );
}
```

Generate these values from spring parameters using tools like [linear-easing-generator](https://linear-easing-generator.netlify.app/).

**When CSS springs are enough:**
- Hover effects, button presses, entry/exit transitions, layout shifts

**When a JS animation library is needed (Framer Motion, React Spring, Motion One):**
- Gesture-driven animation (drag, swipe, pinch) — the animation must respond to ongoing input
- Interruptible animations — a new trigger mid-animation must redirect smoothly, not restart
- Complex orchestrated sequences with stagger, layout animations, or shared element transitions

### Only Animate Transform and Opacity

For smooth 60fps animations, only animate `transform` and `opacity`. Other properties (width, height, margin, padding) trigger expensive layout recalculations.

```css
/* Good - GPU accelerated */
.card:hover {
  transform: translateY(-2px);
  opacity: 0.9;
}

/* Avoid - triggers layout */
.card:hover {
  margin-top: -2px;
  height: 102%;
}
```

A consistent frame rate matters more than a high one — a steady 30fps looks smoother than 60fps with dips.

### Animate Height with grid-template-rows

The one exception to "only animate transform and opacity": `grid-template-rows` can animate between `0fr` and `1fr`, enabling smooth accordion-style height transitions without JavaScript height calculations (~93% browser support):

```css
.collapsible {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows 300ms ease-out;
}

.collapsible.is-open {
  grid-template-rows: 1fr;
}

.collapsible__inner {
  overflow: hidden;
  min-height: 0;
}
```

```html
<div class="collapsible">
  <div class="collapsible__inner">
    Content that collapses smoothly
  </div>
</div>
```

**Accessibility caveat:** When collapsed (`0fr`), the content is visually hidden but still in the accessibility tree. Add `visibility: hidden` to the inner element when collapsed so screen readers skip it, and transition visibility alongside:

```css
.collapsible__inner {
  overflow: hidden;
  min-height: 0;
  visibility: hidden;
  transition: visibility 300ms;
}

.collapsible.is-open .collapsible__inner {
  visibility: visible;
}
```

**Future alternative:** `interpolate-size: allow-keywords` (Chrome 129+) will allow direct `height: 0` to `height: auto` transitions — but browser support is not yet sufficient (~70%).

### Every Entrance Needs an Exit

When something animates onto the screen, it must also animate as it leaves. Alerts that beautifully slide in but instantly vanish on dismissal make the interface feel unfinished. Invest in a system that waits for exit animations to complete before removing elements.

**Exit animations should be faster than entrances.** Users have already processed the element — the exit just needs to confirm it's gone. Use 75-85% of the entrance duration for the exit:

| | Entrance | Exit |
|---|---|---|
| **Duration** | 300ms | 225-250ms |
| **Easing** | `ease-out` (decelerate in) | `ease-in` (accelerate out) |
| **Perception** | "Here I am" — arrives confidently | "Done" — leaves quickly |

The asymmetry is subtle but noticeable. Symmetric enter/exit feels sluggish because the exit draws too much attention to something the user already dismissed.

### Use @starting-style for Entry Animations

`@starting-style` (Baseline 2024) defines the initial state for CSS transitions when an element first appears — enabling entry animations without JavaScript. Previously, animating an element "from hidden to visible" required JS to add a class after insertion.

```css
dialog[open] {
  opacity: 1;
  transform: translateY(0);
  transition: opacity 300ms ease-out, transform 300ms ease-out;

  @starting-style {
    opacity: 0;
    transform: translateY(-8px);
  }
}
```

This is particularly useful for elements that toggle visibility: dialogs, popovers, tooltips, and notification toasts. Combine with `allow-discrete` to also transition `display: none`:

```css
.tooltip {
  transition: opacity 200ms ease-out, display 200ms allow-discrete;
  opacity: 1;

  @starting-style { opacity: 0; }
}
.tooltip[hidden] {
  opacity: 0;
  display: none;
}
```

### Use the Popover API for Tooltips, Dropdowns, and Menus

The Popover API (Baseline 2025) provides native behaviour for floating UI elements — no JavaScript libraries needed for the basics:

```html
<button popovertarget="actions-menu">Actions</button>
<div id="actions-menu" popover>
  <ul role="menu">
    <li><button>Edit</button></li>
    <li><button>Duplicate</button></li>
    <li><button>Delete</button></li>
  </ul>
</div>
```

**What the browser handles automatically:**
- Renders in the **top layer** (no z-index wars)
- **Dismisses on outside click** or Escape key
- **Manages focus** — moves focus to the popover, returns it on close
- Prevents background scrolling

**When to use popover:**
- Dropdown menus and action menus
- Non-modal information panels
- Notification toasts (combine with `popover="manual"` for persistent display)

**When to use `<dialog>` instead:**
- Modal dialogs that require user action before continuing
- Confirmation prompts, form overlays

Combine with `@starting-style` for animated entry/exit — the Popover API and `@starting-style` were designed to work together.

### Use the `inert` Attribute for Non-Modal Content

The `inert` attribute (Baseline 2023) makes an element and all its descendants non-interactive and invisible to assistive technology. It is the correct way to trap focus inside a custom overlay, off-canvas drawer, or wizard step.

```html
<nav class="drawer" id="drawer">
  <!-- Drawer content -->
</nav>
<main id="main-content" inert>
  <!-- Main content is unreachable while drawer is open -->
</main>
```

**When `inert` is set:**
- Click/tap events are ignored
- The element is removed from the tab order
- Screen readers skip the entire subtree
- `find-in-page` does not match text inside `inert` content

**You do NOT need `inert` when using:**
- `<dialog>.showModal()` — the browser automatically makes everything outside the dialog inert
- Popover API — the browser manages focus and dismissal

**Use `inert` when:**
- Building a custom drawer/sidebar that overlays the page
- Implementing a step-by-step wizard where only the current step should be interactive
- Creating a custom modal without `<dialog>` (though `<dialog>` is preferred)

Style inert regions to reinforce their inactive state:

```css
[inert] {
  opacity: 0.5;
  pointer-events: none;
}
```

### Avoid Flashes of Unloaded States (FOULS)

When loading content dynamically, ensure users never see empty/unloaded pages:

1. Start in a **loading state** (skeleton screens, shimmer placeholders)
2. **Transition** loaded content in smoothly
3. Never show the unloaded state — build with an "always be loading" mentality

### Signal Oncoming Animations

Anticipatory animation helps users mentally prepare. For example, hovering over a collapsible sidebar can cause it to slightly shift in the direction it will expand if clicked.

### Respect Reduced Motion Preferences

Vestibular disorders affect ~35% of adults over 40. Seizure-triggering animations can be dangerous — never flash elements more than twice per second.

```css
/* Safety net: disable all motion by default */
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation: none;
    transition: none;
  }
}
```

No `!important` — this allows more specific selectors (dialogs, view transitions, popovers) to override with safe opacity fades. WCAG 2.3.3 explicitly excludes opacity changes from "motion animation", so fades do not trigger vestibular disorders.

Replace motion-based animations with fades where a visual signal is still needed:

### View Transitions API

The View Transition API provides native browser support for animated transitions between UI states — both within a single page (SPA) and across page navigations (MPA). It answers the question "what just happened?" by showing spatial relationships between states, reducing cognitive load.

**Browser support:** Same-document transitions are Baseline 2025 (Chrome 111+, Safari 18+, Firefox 144+). Cross-document (MPA) transitions have no Firefox support — use as progressive enhancement only.

#### Same-Document Transitions (SPA)

Wrap DOM updates in `document.startViewTransition()`:

```javascript
function navigate(item) {
  if (!document.startViewTransition) {
    updateDOM(item);
    return;
  }

  document.startViewTransition(() => updateDOM(item));
}
```

The browser snapshots the old state, runs the callback, then cross-fades between old snapshot and live new DOM over 250ms by default. The old state is a static bitmap; the new state is live (videos continue, content is interactive).

#### Cross-Document Transitions (MPA)

Opt in with CSS on both pages — no JavaScript needed:

```css
@view-transition {
  navigation: auto;
}
```

Both pages must be on the same origin and both must opt in. Navigations taking longer than 4 seconds are automatically skipped.

#### Shared Element Transitions

Give matching elements the same `view-transition-name` on both pages (or both states). The browser automatically morphs position, size, and content between them:

```css
/* List page */
.product-thumbnail { view-transition-name: product-image; }

/* Detail page */
.product-hero { view-transition-name: product-image; }
```

Each name must be unique across all rendered elements at the same time. Use `view-transition-name: match-element` (Baseline 2025) for lists where items reorder but don't change identity. Use `view-transition-class` to apply shared animation styles to groups of named elements.

#### Custom Animations

Override the default cross-fade by targeting the pseudo-elements:

```css
::view-transition-old(root) {
  animation: 300ms ease-in slide-out-left;
}
::view-transition-new(root) {
  animation: 300ms ease-out slide-in-right;
}
```

Use `:active-view-transition-type()` for directional animations (forward vs backward navigation).

#### When to Use View Transitions vs @starting-style

| | View Transitions | `@starting-style` |
|---|---|---|
| **Purpose** | Animate between two complete UI states | Animate an element's first appearance |
| **Scope** | Full page or named elements | Individual elements |
| **Trigger** | `startViewTransition()` or navigation | Element insertion, `display: none` → visible |
| **Best for** | Page transitions, list reordering, shared elements | Dialogs, popovers, tooltips, toasts |

#### Performance and Accessibility

- Keep transitions under 500ms — interaction is blocked during the animation
- Use `view-transition-name` sparingly — each named element creates a bitmap snapshot
- Do not lazy-load images that participate in transitions

**Always respect `prefers-reduced-motion`.** For MPA transitions, only enable when motion is acceptable:

```css
@media (prefers-reduced-motion: no-preference) {
  @view-transition {
    navigation: auto;
  }
}
```

For SPA transitions, substitute a quick cross-fade instead of disabling entirely — fades do not trigger vestibular disorders:

```css
@media (prefers-reduced-motion: reduce) {
  ::view-transition-group(*) {
    animation: none;
  }
  ::view-transition-old(*) {
    animation: 150ms ease-out fade-out;
  }
  ::view-transition-new(*) {
    animation: 150ms ease-in fade-in;
  }
}
```

## Chapter Summary

1. Minimise usability risk by keeping interfaces simple and familiar
2. Every interface detail needs a logical reason behind it
3. Minimise interaction cost and cognitive load as much as possible
4. Create a design system of predefined styles, modular components, and usage guidelines
5. Good accessibility means great usability — provide skip links, never disable zoom, use semantic HTML
6. Use roving tabindex in composite widgets (tabs, toolbars, menus) — one Tab stop, arrow keys within
7. Use `inert` for off-screen content and custom overlays — native `<dialog>.showModal()` handles this automatically
8. Only animate `transform` and `opacity` — except `grid-template-rows` for height animations (accordions)
9. Use `linear()` for spring-like easing in pure CSS; reserve JS animation libraries for gesture-driven or interruptible motion
10. Exit animations should be ~75-85% of entrance duration with ease-in (vs ease-out for entrance)
11. Use `@starting-style` for CSS-only entry animations; Popover API for native tooltips/dropdowns/menus
12. Use the View Transition API for page transitions and shared element animations — always respect `prefers-reduced-motion` and keep under 500ms
