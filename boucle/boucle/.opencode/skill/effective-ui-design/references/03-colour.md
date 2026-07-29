# Colour

Learn how to use colour sparingly and purposefully to add meaning to an interface.

## Ensure Sufficient Contrast

Contrast = difference in perceived brightness between two colours (ratio 1:1 to 21:1).

### WCAG 2.1 Level AA Requirements

**3:1 Minimum - Large text and UI elements:**
- Text above 18px bold OR above 24px regular
- UI elements (form fields, buttons, checkboxes)
- Decorative elements don't need to meet this ratio

**4.5:1 Minimum - Small text:**
- Text 18px or less

### Common Contrast Issues
- Close icon contrast < 3:1
- Secondary text contrast < 4.5:1
- Search field border < 3:1
- Placeholder text < 4.5:1
- Button background against text < 4.5:1
- Link text contrast < 4.5:1

### APCA (Accessible Perceptual Contrast Algorithm)

Improved method in WCAG 3 draft - solves WCAG 2 limitations.

**APCA Contrast Values:**
- 90 - Preferred for body text (14px regular+)
- 75 - Minimum for body text (18px regular+)
- 60 - Minimum for other text (24px regular OR 16px bold+)
- 45 - Minimum for large text (36px regular OR 24px bold+) and UI elements
- 30 - Absolute minimum (placeholder text, disabled button text)
- 15 - Minimum for non-text elements

**Key differences from WCAG 2:**
- No ratios - uses contrast numbers (higher = more contrast)
- Value depends on text size AND weight
- Swapping text/background colours affects contrast
- Works better for dark interfaces

**Recommendation:** Use APCA for personal projects. For commercial projects requiring compliance, stick with WCAG 2 until WCAG 3 releases, but try to pass both.

## Don't Rely on Colour Alone to Convey Meaning

For accessibility to colour blind users:
- Use additional visual cues to differentiate elements
- Never use colour as the ONLY indicator

**Examples:**
- Form errors: Add icon + thicker border + background (not just red colour)
- Text links: Add underline (not just blue colour)

## Use System Colours to Indicate Status

**3 System Colours (Traffic light colours):**
- **Red (Error)** - negative message, error, urgent attention needed
- **Amber (Warning)** - caution, risky action
- **Green (Success)** - positive message, action completed

**Accessibility requirements:**
- Don't rely on system colours alone - use icons as additional cues
- System colours for text: minimum 4.5:1 contrast
- System colours for UI elements/icons: minimum 3:1 contrast

## Use Colour to Define Visual Hierarchy

Present information in order of importance.

### Saturation
- Higher saturation = more prominent
- Use saturated colours for important elements (links, buttons)

### Hue
- Certain hues are more prominent (red stands out most)
- Use prominent hues for important elements

### Contrast
- Higher contrast = more prominent
- Make headings darker than body text

## Use Black and White for Timeless Aesthetic

Benefits:
- Fewer distractions
- Highlights content
- Timeless look

**Design tip:** Design in black and white FIRST, regardless of brand colours. Focus on spacing, size, layout, contrast before adding colour.

**Proportion depends on brand:**
- Mostly white = simple, classic, minimal feel
- Mostly black = dramatic, powerful, luxurious feel

### Avoid Pure Black (#000000)
- High contrast against white causes eye strain
- Use dark grey instead
- Black: 0% brightness, White: 100% brightness - large difference strains eyes

## Add a Tinge of Colour to Black and White (Tinted Neutrals)

Pure grey doesn't exist in nature - real shadows always have a colour cast. Adding a minimal tint of your brand colour to neutrals creates subconscious cohesion.

```css
/* Pure grays - feel "dead" */
--gray-100: oklch(95% 0 0);
--gray-900: oklch(15% 0 0);

/* Tinted grays - feel alive */
--gray-100: oklch(95% 0.01 250);  /* Tiny hint of blue */
--gray-900: oklch(15% 0.01 250);
```

The chroma is tiny (0.01) but perceptible. Benefits:
- Get benefits of black/white interface
- Creates visual harmony with brand colour
- Adjust mood with pinch of colour

## Use 1 Brand Colour

Single unique colour alongside black and white.

**Benefits:**
- Conveys brand mood/personality
- Can indicate interactive elements

**Colour Psychology Note:**
- Not universal - affected by culture, personal experience, colour blindness, surrounding elements
- Use as loose guideline only
- Test with users

**Tips for choosing brand colour:**
- Choose distinctive colour
- Remember system colours (red, amber, green) have strong meanings - using red for other elements causes confusion

## Apply Brand Colour to Interactive Elements

**Simple, effective approach:**
- Use brand colour for text links and buttons
- Teaches users what's interactive
- Don't add to ALL interactive elements (some already have visual cues)
- NEVER use brand colour on non-interactive elements

**CRITICAL:** Brand colour must have 4.5:1 contrast against background.

### What About Low Contrast Colours?

If brand colour is too light (e.g., yellow):
- Try darkening slightly (without losing brand recognition)
- Add text shadow to white button text
- Use text colour for button text/links
- Add border to buttons (3:1 contrast)

### If Brand Colour Has Meaning (Red/Green/Amber)
Avoid using for interactive elements to prevent conflicting meanings.

### Multiple Brand Colours
- Use highest contrast colour for interactive elements
- Use others sparingly for decorative elements
- NEVER use more than one colour for interactive elements

## Consider OKLCH for Modern Colour Systems

OKLCH is a modern alternative to HSB/HSL that is "perceptually uniform" - equal numerical steps result in equal visual changes across all colours.

**The HSL Problem:**
- 50% lightness in yellow looks much brighter than 50% in blue
- Darkening/lightening colours produces unexpected results
- Hard to create consistent palettes

**OKLCH Benefits:**
- Predictable lightness across all hues
- Better for generating colour variations
- Easier to meet contrast requirements
- Wide gamut support (P3 displays)
- Browser support: Chrome 111+, Safari 15.4+, Firefox 113+

```css
/* OKLCH: lightness (0-100%), chroma (0-0.4+), hue (0-360) */
--brand: oklch(60% 0.15 250);        /* Blue */
--brand-light: oklch(85% 0.08 250);  /* Lighter - reduce chroma */
--brand-dark: oklch(35% 0.12 250);   /* Darker */
```

**Tip:** When moving toward white or black, reduce chroma. High chroma at extreme lightness looks garish.

### Derive Colour Variations with Relative Color Syntax

Relative color syntax (Baseline 2024) lets you derive new colours from existing ones — no manual calculations or preprocessors needed. Create hover states, tints, and shades programmatically:

```css
:root {
  --brand: oklch(60% 0.15 250);

  /* Darken for hover — reduce lightness by 15% */
  --brand-hover: oklch(from var(--brand) calc(l - 0.1) c h);

  /* Lighten for tint — increase lightness, reduce chroma */
  --brand-tint: oklch(from var(--brand) 92% calc(c * 0.4) h);

  /* Desaturate for disabled — reduce chroma */
  --brand-disabled: oklch(from var(--brand) l calc(c * 0.3) h);

  /* Shift hue for complementary — rotate 180° */
  --accent: oklch(from var(--brand) l c calc(h + 180));
}
```

**Why this matters for design systems:**
- Define a single brand colour → derive the entire palette
- Hover, active, and disabled states stay mathematically consistent
- Changing the base colour cascades through all variations
- Works with any colour space (`oklch`, `hsl`, `rgb`, etc.) — prefer OKLCH for perceptual uniformity

## Consider the 60-30-10 Rule

A guideline (not strict rule) for colour distribution from interior design:

- **60%** - Dominant colour (backgrounds, white space)
- **30%** - Secondary colours (text, borders, cards)
- **10%** - Accent colour (CTAs, links, highlights)

The accent colour works *because* it's rare. Overuse kills its impact. This is a helpful starting point, but context matters more than rigid proportions.

## Create a Colour Palette

Small set of predefined colours with rules governing usage.

### 7 Colour Variations (Solid Palette — OKLCH)

```
Brand:         oklch(60% 0.15 hue)     - Interactive elements
               Must have 4.5:1 against fill

Text strong:   oklch(25% 0.02 hue)     - Headings, primary text
               Very dark grey with brand tinge
               Must have 4.5:1 against fill

Text weak:     oklch(45% 0.02 hue)     - Secondary text
               Dark grey with brand tinge
               Must have 4.5:1 against fill

Stroke strong: oklch(58% 0.02 hue)     - Form borders, icons
               Medium grey with brand tinge
               Must have 3:1 against fill

Stroke weak:   oklch(92% 0.005 hue)    - Decorative borders
               Light grey with brand tinge
               No contrast requirement (decorative only)

Fill:          oklch(97% 0.003 hue)    - Secondary backgrounds
               Very light grey with brand tinge

Background:    oklch(100% 0 0)         - White
```

Verify contrast with tools like [oklch.fyi](https://oklch.fyi/) or Chrome DevTools — maximum chroma varies by hue, so adjust values per project.

### Interaction States

**Change opacity:**
- Default: 100%
- Hover: 80%
- Disabled: 20%
- Focus: outline

**Change fill colour:**
- Hover: Fill colour variation
- Press: Stroke weak colour variation

**Change elevation:**
- Hover: Add/increase shadow

**Toggle underline:**
- Text links: Remove underline on hover
- Navigation: Add underline on hover

**Use animation:**
- Move button up slightly on hover
- Keep subtle and quick

## Dark Colour Palette (OKLCH)

```
Brand:         oklch(78% 0.12 hue)
Text strong:   oklch(98% 0 0)          - White
Text weak:     oklch(80% 0.01 hue)
Stroke strong: oklch(58% 0.02 hue)
Stroke weak:   oklch(25% 0.03 hue)
Fill:          oklch(18% 0.02 hue)
Background:    oklch(13% 0.03 hue)
```

**Tips:**
- Increase contrast above WCAG minimum (dark interfaces harder to see)
- Check with APCA for accuracy
- Start with white for Text strong
- Gradually increase saturation, decrease brightness
- Avoid pure black background

### Use light-dark() for Theme Switching

The `light-dark()` function (Baseline 2024) returns one of two colours based on the active colour scheme — eliminating the need for `@media (prefers-color-scheme)` queries on individual properties:

```css
:root {
  color-scheme: light dark;
}

body {
  color: light-dark(oklch(20% 0.01 250), oklch(95% 0.01 250));
  background: light-dark(#fff, oklch(15% 0.02 250));
}

.card {
  background: light-dark(white, oklch(22% 0.015 250));
  border-color: light-dark(oklch(90% 0.01 250), oklch(30% 0.02 250));
}
```

**When to use `light-dark()`:**
- Individual property values that differ between themes
- Simpler and more readable than media query blocks for per-property changes

**When to keep `@media (prefers-color-scheme)`:**
- Structural changes (different layouts, different components per theme)
- Swapping images or assets between themes

**Combine with semantic tokens** for the best of both worlds — define tokens with `light-dark()`, reference tokens in components:

```css
:root {
  color-scheme: light dark;
  --text-strong: light-dark(oklch(20% 0.01 250), oklch(95% 0.01 250));
  --text-weak: light-dark(oklch(40% 0.01 250), oklch(75% 0.01 250));
  --bg: light-dark(#fff, oklch(15% 0.02 250));
  --fill: light-dark(oklch(97% 0.005 250), oklch(22% 0.015 250));
}
```

## Add Depth Using Colour and Shadows

Elements with higher elevation appear closer and more prominent.

### Define 2 Shadow Options
- **Raised** - small, sharp shadow for interactive elements (cards)
- **Overlay** - larger, softer shadow for floating elements (dropdowns, dialogs)

**Shadow tips:**
- Light comes from top (mimics real world)
- Use "Text strong" colour instead of black
- Small/sharp = slightly raised
- Large/soft = elevated higher

### Colour Indicates Depth
- Light colours look more elevated than dark
- Place lighter colours on top of darker colours

### Dark Interface Elevation
Shadows hard to see - rely on colour instead.

**3 Background Colours:**
- Base - darkest, main background
- Raised - slightly brighter
- Overlay - slightly brighter than raised

## Transparent Colours

Lower opacity makes colours see-through (alpha value 0-1).

### Problem with Solid Colours
Solid colours remain same regardless of background. Elements can have inconsistent prominence on different backgrounds.

**Common failure: fixed grays on coloured backgrounds.** A gray like `#6b6b6b` that passes 4.5:1 contrast on white can drop below 3:1 on a brand-coloured banner or tinted card — the contrast ratio depends on the *actual rendered background*, not an assumed white. This is the most common real-world contrast failure in component libraries.

Always check contrast against the rendered background, not white. Chrome DevTools' contrast picker evaluates the actual composite colour beneath the text.

### Transparent Colour Solution
Allows background to mix with foreground - maintains consistent prominence.

### Transparent Colour Palette (Dark Mode)

**5 variations of white:**
```
Text strong:   100% opacity (4.5:1 against overlay)
Text weak:     78% opacity (4.5:1 against overlay)
Stroke strong: 60% opacity (3:1 against overlay)
Stroke weak:   12% opacity (decorative)
Fill:          6% opacity
```

**5 variations of black (Light Mode):**
```
Text strong:   90% opacity (4.5:1 against fill)
Text weak:     60% opacity (4.5:1 against fill)
Stroke strong: 45% opacity (3:1 against fill)
Stroke weak:   10% opacity (decorative)
Fill:          4% opacity
```

**Brand colour variations (4 each for light/dark):**
- 100% - Brand
- 80% - Text
- 20% - Stroke strong
- 5% - Fill

**System colour variations (4 each for red/amber/green):**
- 100% - Text (4.5:1)
- 80% - Stroke strong (3:1)
- 20% - Stroke weak
- 5% - Fill

### Transparent Layers for Interaction States
- Hover: Fill colour variation overlay
- Press: Stroke weak colour variation overlay

## Colour Token Architecture

Use a 3-tier system for scalable, maintainable colour systems:

```
┌─────────────────────────────────────────────────────┐
│  1. Raw Value         oklch(48% 0.2 162)            │
│                       ↓                             │
│  2. Primitive Colour  green.1000                    │
│                       ↓                             │
│  3. Semantic Colour   text.success                  │
└─────────────────────────────────────────────────────┘
```

### 1. Raw Values
The actual colour definition in OKLCH (or hex as fallback).
- Only referenced by primitive tokens, never used directly in components
- Easy to adjust globally

### 2. Primitive Colours
Named by appearance. Format: `[colour.mode.number]`
- Number 0-1000 indicates contrast level (1000 = highest)
- Examples: `grey.light.1000`, `green.dark.800`, `blue.500`

### 3. Semantic Colours (Tokens)
Named by usage - what the colour *does*. Format: `[element.tone.emphasis.state]`

**Elements:** Text, Stroke, Icon, Fill, Background
**Tones:** Neutral, Brand, Error, Warning, Success
**Emphasis:** Strong, Weak
**States:** Hover, Press, Focus, Disabled

**Examples:**
- `text.success` → `green.1000` → `oklch(48% 0.2 162)`
- `stroke.strong` → `grey.600` → `oklch(45% 0.01 250)`
- `fill.error.weak` → `red.100` → `oklch(95% 0.05 25)`

**Why this matters:**
- Change `green.1000` once → all success states update
- Swap themes by remapping semantic → primitive
- Components only reference semantic tokens = consistent usage

## Adjust Photo Colour Temperature

Match photo colour temperature to palette for harmonious look:
- Cool palette (blue) = cooler photos
- Warm palette (orange) = warmer photos

Not for product photos where realistic colours matter.

## Chapter Summary

1. Ensure text/UI elements have sufficient contrast; don't rely on colour alone
2. Design in black and white first, then add colour purposefully (brand colour for interactive elements)
3. Create small predefined colour palette with usage rules
4. Use OKLCH for perceptually uniform palettes; derive variations with relative color syntax
5. Use `light-dark()` for clean theme switching without media query duplication
6. Consider transparent colours for consistent prominence across backgrounds
7. Name colours systematically using a 3-tier token architecture
