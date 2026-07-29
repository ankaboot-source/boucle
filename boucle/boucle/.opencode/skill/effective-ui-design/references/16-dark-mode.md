# Dark Mode

Learn how to implement dark mode beyond colour selection: handling images, shadows, elevation, user preferences, and edge cases.

This reference covers the implementation side of dark mode. For OKLCH colour palettes, the `light-dark()` function, transparent colour systems, and colour token architecture, see `03-colour.md`.

## Declare `color-scheme` for Browser UA Adaptation

The `color-scheme` property tells the browser which colour schemes your site supports. It does NOT style your authored content -- it only affects browser-provided UI: form controls, scrollbars, spellcheck underlines, and CSS system colour keywords.

**Source:** web.dev/articles/color-scheme -- "color-scheme exclusively determines the default appearance, whereas prefers-color-scheme determines the stylable appearance."

### Meta tag (preferred -- parsed before CSS, renders faster):
```html
<meta name="color-scheme" content="light dark">
```

### CSS property:
```css
:root {
  color-scheme: light dark;
}
```

### What changes when `color-scheme` is set:
- Form controls (inputs, selects, checkboxes, date pickers) get dark-appropriate styling
- Scrollbars adapt to dark appearance
- CSS system colour keywords (`Canvas`, `CanvasText`, `ButtonFace`, `ButtonText`) resolve to dark values
- The root canvas surface colour changes (the white behind your page becomes dark)

### Value ordering:
The first value indicates author preference. `color-scheme: dark light` prefers dark; `color-scheme: light dark` prefers light. The browser uses the user's OS preference if both are listed.

### Per-element override:
Force specific elements into a scheme regardless of the page theme:
```css
.always-dark-form { color-scheme: dark; }
.always-light-embed { color-scheme: light; }
```

**Browser support:** Chrome 81+, Edge 81+, Firefox 96+, Safari 13+.

## Handle Images in Dark Mode

Not all images need adjustment. Product photos, user avatars, and branded imagery should generally be left alone or have dedicated dark variants. Apply these strategies selectively.

### Strategy 1: Dark-specific assets via `<picture>` (highest fidelity)

```html
<picture>
  <source srcset="hero-dark.webp" media="(prefers-color-scheme: dark)">
  <img src="hero-light.webp" alt="Hero image">
</picture>
```

Best for hero images, illustrations, and branded graphics where quality matters most.

**Source:** web.dev/articles/prefers-color-scheme, CSS-Tricks

### Strategy 2: Brightness/contrast filter for photographs

Photographs rarely need inversion. Slightly reduce brightness to stop them "glowing" on dark backgrounds:

```css
@media (prefers-color-scheme: dark) {
  img:not([src$=".svg"]) {
    filter: brightness(0.8) contrast(1.2);
  }
}
```

Research showed "the majority of the surveyed people prefer slightly less vibrant and brilliant images when dark mode is active."

**Source:** web.dev/articles/prefers-color-scheme, CSS-Tricks

### Strategy 3: Invert + hue-rotate for diagrams and line art

Black-on-white diagrams become unreadable on dark backgrounds. Invert them and add `hue-rotate(180deg)` to restore original hues:

```css
@media (prefers-color-scheme: dark) {
  img.diagram,
  img[src$=".svg"]:not(.logo) {
    filter: invert(1) hue-rotate(180deg);
  }
}
```

Standard `invert(1)` flips hues; adding `hue-rotate(180deg)` corrects them. This only works well for monochrome or minimal-colour content.

**Source:** monochrome.sutic.nu/2024/02/25/hue-preserving-invert-css-filter-for-dark-mode

### Strategy 4: `currentColor` for inline SVGs

SVGs using `currentColor` automatically adapt to text colour changes, requiring no special dark mode handling:

```html
<svg xmlns="http://www.w3.org/2000/svg" stroke="currentColor" fill="none">
  <path d="..."/>
</svg>
```

This is the preferred approach for icons and simple graphics. Works with `<use href="...">` references as well.

**Source:** web.dev/articles/prefers-color-scheme

### Strategy 5: Transparent PNG handling

Logos and icons on transparent backgrounds may disappear in dark mode. Solutions:
- Provide separate light/dark assets via `<picture>` (Strategy 1)
- Add a subtle light background or padding to the logo container
- Convert raster logos to SVG with `currentColor`

## Adjust Shadows for Dark Mode

Box shadows are effectively invisible against dark backgrounds. A `box-shadow: 0 2px 8px oklch(0% 0 0 / 0.1)` that works in light mode becomes imperceptible in dark mode.

**Source:** parker.mov/notes/good-dark-mode-shadows -- "Box shadows alone are basically imperceptible in dark mode."

### Approach 1: Darker, more opaque shadows

Increase shadow opacity dramatically for dark mode:

```css
.card {
  box-shadow: light-dark(
    0 1px 3px oklch(0% 0 0 / 0.12),    /* light: subtle */
    0 1px 3px oklch(0% 0 0 / 0.5)       /* dark: much heavier */
  );
}
```

### Approach 2: Use border instead of shadow

A subtle lighter border is more visible than a shadow in dark mode:

```css
.card {
  border: light-dark(
    1px solid oklch(90% 0.005 var(--hue)),
    1px solid oklch(100% 0 0 / 0.08)
  );
}
```

### Approach 3: Elevation through surface colour

Replace shadows with progressively lighter surfaces. This is Material Design's primary recommendation for dark mode (see next section).

### Combined approach (recommended):

Use lighter surfaces as the primary elevation indicator, with heavier shadows as a secondary cue:

```css
.card {
  background: light-dark(white, oklch(22% 0.015 var(--hue)));
  box-shadow: light-dark(
    0 1px 3px oklch(25% 0.02 var(--hue) / 0.12),
    0 2px 6px oklch(0% 0 0 / 0.4)
  );
}
```

See `03-colour.md` for the base dark surface colours (Background, Fill, Overlay) and the `light-dark()` function.

## Build an Elevation System for Dark Mode

In light mode, higher elevation = darker shadow. In dark mode, higher elevation = lighter surface. The surface gets progressively brighter as it rises closer to the "light source."

### Material Design 2: White overlay percentages

The base dark surface is `oklch(13% 0.03 hue)` (approximately `#121212`). Elevated surfaces get a semi-transparent white overlay with increasing opacity:

| Elevation | White Overlay | Use Case |
|-----------|--------------|----------|
| 0dp | 0% | Base background |
| 1dp | 5% | Cards at rest |
| 2dp | 7% | Raised buttons |
| 3dp | 8% | Search bars |
| 4dp | 9% | App bars |
| 6dp | 11% | FABs, snackbars |
| 8dp | 12% | Menus, side sheets |
| 12dp | 14% | FAB pressed |
| 16dp | 15% | Navigation drawers |
| 24dp | 16% | Dialogs |

**Source:** Material Design 2: Dark Theme (m2.material.io/design/color/dark-theme.html)

### Material Design 3: Tonal surface tint

MD3 shifted from white overlays to **primary colour tint** overlays. Elevated surfaces carry a subtle brand colour cast instead of pure white:

```css
/* MD3-style: use brand hue for tint */
:root[data-theme="dark"] {
  --surface-0: oklch(13% 0.03 var(--hue));
  --surface-1: oklch(from var(--brand) 17% calc(c * 0.15) h);  /* cards */
  --surface-3: oklch(from var(--brand) 21% calc(c * 0.2) h);   /* app bar */
  --surface-5: oklch(from var(--brand) 25% calc(c * 0.25) h);  /* dialogs */
}
```

**Source:** Material Design 3: Elevation (m3.material.io/styles/elevation/applying-elevation) -- "Tonal color overlays...the overlay color coming from the primary color slot."

### Apple HIG approach

Apple uses two sets of background colours: "base" (dimmer, for background interfaces) and "elevated" (brighter, for foreground interfaces). Apple additionally uses vibrancy -- dynamically blending foreground and background colours to make foreground content stand out.

**Source:** Apple HIG: Dark Mode (developer.apple.com/design/human-interface-guidelines/dark-mode)

### Practical CSS implementation with OKLCH

For most projects, 3 to 5 surface levels is sufficient:

```css
:root[data-theme="dark"] {
  --surface-0: oklch(13% 0.03 var(--hue));   /* base background */
  --surface-1: oklch(17% 0.025 var(--hue));  /* cards, sections */
  --surface-2: oklch(19% 0.02 var(--hue));   /* raised buttons, bars */
  --surface-3: oklch(21% 0.02 var(--hue));   /* menus, popovers */
  --surface-4: oklch(23% 0.015 var(--hue));  /* dialogs, overlays */
  --surface-5: oklch(25% 0.015 var(--hue));  /* highest elevation */
}
```

See `03-colour.md` for the 3-level Background/Fill/Overlay pattern. This section extends that to a full elevation scale.

## Adjust Contrast for Dark Mode

### Avoid pure white text

Pure white (`oklch(100% 0 0)`) on dark backgrounds causes "halation" -- the text appears to glow and blur, particularly for users with astigmatism (approximately 33% of the population).

```css
/* Don't: pure white */
--text-primary: oklch(100% 0 0);

/* Do: off-white */
--text-primary: oklch(93% 0.01 var(--hue));   /* ~#EDEDED */
--text-secondary: oklch(75% 0.01 var(--hue));
```

**Source:** Atmos (atmos.style/blog/dark-mode-ui-best-practices), UX Planet -- "Something around #E0E0E0 or #F0F0F0 works much better for body text."

### Desaturate accent colours by 20-30%

Fully saturated colours "vibrate" on dark backgrounds, causing visual discomfort. Reduce chroma compared to light mode values:

```css
/* Light mode brand */
--brand: oklch(60% 0.15 250);

/* Dark mode brand: higher lightness, lower chroma */
--brand: oklch(78% 0.12 250);
```

"Colors should have around 20 points lower saturation on dark mode than on light mode."

**Source:** Atmos (atmos.style/blog/dark-mode-ui-best-practices), BOIA -- "highly saturated blues, reds, or greens can appear to vibrate or bleed."

### WCAG still applies in full

WCAG 2.1 Success Criterion 1.4.3 does not include exceptions for dark mode. The same minimums apply to both themes:
- 4.5:1 for normal text
- 3:1 for large text and UI elements

Every colour combination must be verified independently in each theme. Colours that pass on white may fail on dark grey and vice versa.

APCA (the algorithm behind WCAG 3 draft) handles dark backgrounds more accurately than WCAG 2. See `03-colour.md` for APCA contrast values.

**Source:** BOIA (boia.org/blog/offering-a-dark-mode-doesnt-satisfy-wcag-color-contrast-requirements)

## Implement a User Preference Toggle

### Three-state pattern: system / light / dark

The best implementation offers three choices, defaulting to "system":

**Preference cascade:**
1. Check `localStorage` for explicit user choice
2. If value is "system" or absent, defer to `prefers-color-scheme` media query
3. Apply theme via `data-theme` attribute on `<html>`

**Source:** whitep4nth3r.com/blog/best-light-dark-mode-theme-toggle-javascript, lexingtonthemes.com

### JavaScript implementation:

```js
function getTheme() {
  const stored = localStorage.getItem('theme');
  if (stored && stored !== 'system') return stored;
  return matchMedia('(prefers-color-scheme: dark)').matches
    ? 'dark'
    : 'light';
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
}

// Apply immediately
applyTheme(getTheme());

// Listen for system changes (relevant when set to "system")
matchMedia('(prefers-color-scheme: dark)')
  .addEventListener('change', () => {
    const stored = localStorage.getItem('theme');
    if (!stored || stored === 'system') applyTheme(getTheme());
  });

// Toggle handler
function setTheme(choice) {   // "light" | "dark" | "system"
  localStorage.setItem('theme', choice);
  applyTheme(choice === 'system' ? getTheme() : choice);
}
```

### CSS side with `data-theme` attribute:

```css
:root { color-scheme: light; }
:root[data-theme="dark"] { color-scheme: dark; }

:root, :root[data-theme="light"] {
  --bg: oklch(100% 0 0);
  --text: oklch(20% 0.01 var(--hue));
}

:root[data-theme="dark"] {
  --bg: oklch(13% 0.03 var(--hue));
  --text: oklch(93% 0.01 var(--hue));
}
```

See `03-colour.md` for the full set of semantic colour tokens to define in each theme block.

## Prevent Flash of Incorrect Theme

The "flash" occurs because HTML renders before JS executes. If the default theme is light but the user wants dark, there is a visible white flash before JS applies the correct theme.

### Strategy 1: Blocking `<script>` in `<head>` (most reliable)

A small inline script before any stylesheet applies the theme before first paint:

```html
<head>
  <script>
    (function() {
      var t = localStorage.getItem('theme');
      if (t === 'dark' || (!t && matchMedia('(prefers-color-scheme: dark)').matches)) {
        document.documentElement.dataset.theme = 'dark';
        document.documentElement.style.colorScheme = 'dark';
      }
    })();
  </script>
  <link rel="stylesheet" href="styles.css">
</head>
```

This script is synchronous and intentionally tiny. No external file, no `async`, no `defer`.

**React/Next.js note:** This causes a hydration mismatch warning because server-rendered HTML lacks the `data-theme` attribute. Suppress with `suppressHydrationWarning` on `<html>`. Libraries like `next-themes` handle this automatically.

**Source:** CSS-Tricks, notanumber.in/blog/fixing-react-dark-mode-flickering

### Strategy 2: `<meta name="color-scheme">` tag

```html
<meta name="color-scheme" content="light dark">
```

This alone prevents the white flash for the page canvas. The browser renders scrollbars, form controls, and the background in the correct scheme immediately, before any CSS or JS loads. It does not apply your custom dark mode styles.

### Strategy 3: Server-side rendering with cookies

Read the theme preference from a cookie and render the correct attribute server-side:

```js
// Client-side: set cookie alongside localStorage
document.cookie = `theme=${choice};path=/;max-age=31536000;SameSite=Lax`;

// Server-side: read cookie, inject data-theme into HTML
// Works with any server framework (Node, PHP, Python, etc.)
```

**Source:** CSS-Tricks (showed PHP cookie approach)

### Strategy 4: `Sec-CH-Prefers-Color-Scheme` client hint

The server receives the user's colour preference at request time via an HTTP header, enabling the correct CSS to be inlined. Limited browser support -- use as progressive enhancement only.

**Source:** web.dev/articles/prefers-color-scheme

### Strategy 5: Conditional stylesheets (CSS-only, no toggle support)

```html
<link rel="stylesheet" href="light.css" media="(prefers-color-scheme: light)">
<link rel="stylesheet" href="dark.css" media="(prefers-color-scheme: dark)">
```

Zero flash for system-preference-following themes. Does not support a manual override toggle.

## Test Dark Mode Thoroughly

### DevTools emulation

- **Chrome/Edge:** DevTools > Rendering panel > "Emulate CSS media feature prefers-color-scheme" > select light or dark
- **Firefox:** DevTools > Inspector > toggle sun/moon icon in toolbar
- **Safari:** Develop menu > Settings for page > Appearance > Dark

**Source:** web.dev/articles/prefers-color-scheme

### Automated screenshot testing

Use Playwright's `colorScheme` option to capture both themes automatically:

```js
const context = await browser.newContext({ colorScheme: 'dark' });
```

Run visual regression tests for every page in both themes. Do not treat dark mode as an afterthought.

### Forced-colours mode (Windows High Contrast)

Dark mode and forced-colours mode are separate features. A forced-colours user may trigger `prefers-color-scheme: dark` if their chosen background luminosity is below 0.33. Test with:

```css
@media (forced-colors: active) {
  /* box-shadow, background images, custom colours are overridden */
  /* Use system colour keywords: Canvas, CanvasText, LinkText, etc. */
}
```

DevTools: Rendering panel > "Emulate CSS media feature forced-colors" > active.

**Source:** Smashing Magazine (smashingmagazine.com/2022/03/windows-high-contrast-colors-mode-css-custom-properties)

### Contrast re-verification

Check every text/background combination in dark mode independently. Use the browser's colour picker contrast ratio tool or axe-core. Colours that pass in light mode may fail in dark mode and vice versa.

### Real-time switching

Test that system preference changes propagate without a page reload. Use the `matchMedia` change listener and verify all components update correctly.

## Do Not Change These in Dark Mode

### Brand colours
Adjust lightness and chroma for legibility, but do not change the hue. The brand should feel like the same brand in both themes.

### Relative hierarchy
If a heading is more prominent than body text in light mode, it must remain more prominent in dark mode. Visual weight relationships between elements are preserved -- only absolute colour values change.

### Semantic colour meaning
Red still means error. Green still means success. Amber still means warning. Adjust lightness and chroma for the dark background, not the semantic role.

### Content structure and layout
Dark mode is a colour adaptation, not a layout change. Do not rearrange, hide, or show different elements.

### Interactive element affordances
Buttons, links, and interactive elements must remain equally discoverable. If brand colour indicates interactivity in light mode, the same (adjusted) brand colour must indicate interactivity in dark mode.

## Common Dark Mode Mistakes

### Mistake 1: Just inverting colours
Applying `filter: invert(1)` to the whole page produces washed-out images, wrong brand colours, and unpredictable results. Dark mode requires intentional colour design, not a blanket filter.

### Mistake 2: Forgetting images
Brand logos on transparent backgrounds disappear. Photographs glow. Diagrams become unreadable. Every image type needs a handling strategy (see image handling section above).

### Mistake 3: Insufficient contrast
Colours that pass WCAG 4.5:1 on white may fail on dark grey. Every text/background combination must be re-verified for the dark theme independently.

### Mistake 4: Ignoring system preference
Not respecting `prefers-color-scheme` forces users to manually toggle every site they visit. Always honour the OS setting as the default.

### Mistake 5: Pure black backgrounds
`oklch(0% 0 0)` causes excessive contrast with white text, leading to eye strain and halation. Use dark grey (approximately `oklch(13% 0.03 hue)`). See `03-colour.md` for the recommended dark background value.

### Mistake 6: Not desaturating accent colours
Vivid saturated colours vibrate and bleed on dark backgrounds. Reduce chroma by 20-30% for dark mode.

### Mistake 7: Forgetting scrollbars and form controls
Without `color-scheme: dark`, browser-native UI (scrollbars, checkboxes, date pickers, select menus) remains light-themed even when the page is dark.

### Mistake 8: Not testing real-time switching
Users may change system preference while the site is open. Without a `matchMedia` change listener, the page does not update.

## Chapter Summary

1. Set `color-scheme: light dark` (meta tag and CSS) so the browser adapts form controls, scrollbars, and system colours automatically
2. Handle images selectively: dark assets via `<picture>`, brightness filter for photos, invert+hue-rotate for diagrams, `currentColor` for SVGs
3. Increase shadow opacity in dark mode or replace shadows with lighter surface colours for elevation
4. Build an elevation system where higher surfaces are lighter, using 3-5 OKLCH surface levels with brand-tinted chroma
5. Use off-white text (approximately `oklch(93%)`) instead of pure white to prevent halation
6. Desaturate accent colours by 20-30% chroma to prevent vibration on dark backgrounds
7. Implement a three-state toggle (system/light/dark) with `localStorage` and `matchMedia` listener
8. Prevent flash of incorrect theme with a blocking inline script in `<head>` before stylesheets load
9. Test both themes independently: DevTools emulation, automated screenshots, forced-colours mode, and contrast re-verification
10. Preserve brand identity, visual hierarchy, semantic colour meaning, layout, and interactive affordances across both themes
11. WCAG contrast requirements (4.5:1 text, 3:1 UI elements) apply equally to both light and dark themes with no exceptions
