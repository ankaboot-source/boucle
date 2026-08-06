---
name: bergside-design-systems
description: Catalog of 67 opinionated design system skills (brutalism, neobrutalism, glassmorphism, claymorphism, editorial, retro, neon, skeumorphism, dithered, riso, etc.). Load this skill to discover available aesthetics, then pull the specific style you need.
---

# bergside Design Systems Catalog

This skill provides access to **67 opinionated design system skills** from
[bergside/awesome-design-skills](https://github.com/bergside/awesome-design-skills)
(MIT, Copyright (c) 2026 Bergside).

## How to use

1. Read `index.json` in this directory — it maps slugs to skill paths.
2. Identify the aesthetic that fits the project (see slug list below).
3. Pull the specific design system at runtime:

```bash
npx typeui.sh pull <slug>
```

This fetches the SKILL.md + DESIGN.md for that aesthetic into the project.

## Available aesthetics (67)

### Bold / expressive
- `brutalism`, `neobrutalism`, `bold`, `dramatic`, `vibrant`, `colorful`, `neon`, `expressive`, `power`

### Clean / minimal
- `minimal`, `clean`, `sleek`, `modern`, `flat`, `basic`, `professional`, `corporate`, `enterprise`, `impeccable`, `spacious`, `refined`, `premium`, `mono`, `sophisticated`

### Textured / material
- `glassmorphism`, `claymorphism`, `neumorphism`, `skeumorphism`, `paper`, `dithered`, `riso`, `terracotta`, `material`

### Editorial / refined
- `editorial`, `premium`, `refined`, `impeccable`, `spacious`, `storytelling`, `perspective`

### Retro / nostalgic / pop culture
- `retro`, `vintage`, `sega`, `pacman`, `tetris`, `matrix`, `doodle`, `sketch`

### Creative / artistic
- `artistic`, `creative`, `fantasy`, `fiction`, `cosmic`, `immersive`, `storytelling`, `perspective`, `cafe`, `agentic`, `futuristic`

### Brand / product-specific
- `shadcn`, `bento`, `ant`, `claude`, `codex`, `roku`, `lingo`, `pulse`, `square`, `stitch`

### Utility / system
- `contemporary`, `friendly`, `gradient`, `geometric`, `levels`, `gradient`, `friendly`

## Example

See `examples/brutalism/` for a fetched example showing the SKILL.md + DESIGN.md format.

## Source

- Repo: https://github.com/bergside/awesome-design-skills
- License: MIT (Copyright (c) 2026 Bergside)
- CLI: `npx typeui.sh pull <slug>` (supports `-p cursor,claude`, `--dry-run`, `npx typeui.sh list`)
