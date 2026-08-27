# Diagram theme — boucle.dev design system (light/transparent)

> **Static source of truth** for every Mermaid diagram emitted in a boucle spec.
> The triage agent references this file instead of inlining the theme block, so the
> design system lives in one place and never drifts across agent prompts.
>
> **Light or transparent background ONLY** — the forge comment surface is white.
> **NEVER** dark, **NEVER** the default Mermaid theme (purple/indigo) — both are off-brand.

## Boucle.dev tokens (extracted from boucle.dev CSS)

The boucle.dev site is dark (`--surface-base: #0d1117`). Diagrams adapt the palette to a
light surface while keeping the brand identity (gold, violet, cyan).

| Token | Value | Role in diagrams |
|---|---|---|
| `primaryColor` | `#f5c842` | boucle gold — primary nodes |
| `primaryTextColor` | `#0d1117` | dark text on gold (contrast) |
| `primaryBorderColor` | `#c9a233` | gold dim — node borders |
| `secondaryColor` | `#fdf3d7` | light gold tint — secondary nodes |
| `tertiaryColor` | `#e8e6f5` | light violet tint (echoes `#7b2ff7`) — tertiary nodes |
| `lineColor` | `#a0a0b8` | muted — edges/arrows |
| `clusterBkg` | `#faf7f2` | warm off-white — subgraph backgrounds |
| `clusterBorder` | `#c9a233` | gold dim — subgraph borders |
| `edgeLabelBackground` | `#ffffff` | white — edge label backgrounds |
| `background` | `transparent` | blends into the forge comment; use `#ffffff` if opaque is required |
| `fontFamily` | `Sora, system-ui, sans-serif` | boucle body font |
| `fontSize` | `14px` | readable on white |

## Mermaid theme block (paste as the FIRST line of every Mermaid fence)

```
%%{init: {"theme":"base","themeVariables":{"background":"transparent","primaryColor":"#f5c842","primaryTextColor":"#0d1117","primaryBorderColor":"#c9a233","lineColor":"#a0a0b8","secondaryColor":"#fdf3d7","tertiaryColor":"#e8e6f5","clusterBkg":"#faf7f2","clusterBorder":"#c9a233","edgeLabelBackground":"#ffffff","fontFamily":"Sora, system-ui, sans-serif","fontSize":"14px"}}}%%
```

## Diagram-type catalogue (27 types — from [diagram-design](https://github.com/cathrynlavery/diagram-design))

Pick the type by answering one question: **what decision does the human validate by
reading this?** A navigation, section or layout change is validated on the visitor's
path through the product (`flowchart`, `journey`); a data model on its entities and
their fields (`erDiagram`); a lifecycle on its states and transitions
(`stateDiagram-v2`).

**A diagram of the files you are about to edit is never the answer.** Nodes named
`content_config_ts`, `index_astro`, `config_yml` are the most common wrong diagram: easy
to draw, impossible to fault, and empty — the spec's Impacted files line already lists
exactly that, and a reader who has never opened the repository learns nothing from it.
If you are about to name a node after a file, you have skipped the question above.

When a concept maps to several types, pick the dominant axis — do NOT hybridize grammars. Types marked **(no native Mermaid)** have no
first-class Mermaid block; approximate with `flowchart` + `subgraph`, or state in the
caption that the Mermaid is a structural sketch of a type the skill renders as HTML/SVG.

| # | Concept | Mermaid block | When to use |
|---|---|---|---|
| 1 | Architecture | `flowchart LR` / `flowchart TB` | Components + connections in a system |
| 2 | IT current-state | `flowchart` + `subgraph` per phase/dept | Legacy landscape grouped by phase/department (the *before* state) |
| 3 | Flowchart | `flowchart TD` | Decision logic with branches |
| 4 | Sequence | `sequenceDiagram` | Time-ordered messages between actors |
| 5 | State machine | `stateDiagram-v2` | States + transitions + guards |
| 6 | ER / data model | `erDiagram` | Entities + fields + relationships |
| 7 | Timeline | `timeline` *(Mermaid ≥10.9)* or `gantt` | Events positioned in time |
| 8 | Swimlane | `flowchart` with `subgraph` per lane | Cross-functional process with handoffs |
| 9 | Quadrant | `quadrantChart` | Two-axis positioning / prioritization |
| 10 | Radar / Spider | **(no native Mermaid)** — `flowchart` sketch or note | Multiple entities scored across 3–5 quantitative criteria |
| 11 | Loop / flywheel | `flowchart` cycle (arrows forming a loop) | Reinforcing cycle where the last step feeds the first |
| 12 | Nested | `flowchart` with nested `subgraph` | Hierarchy through containment / scope |
| 13 | Tree | `flowchart TD` (tree-shaped) or `mindmap` | Parent → children relationships |
| 14 | Org chart | `flowchart TD` with `subgraph` per team | Human/agent/team ownership, reporting, routing, escalation |
| 15 | Layer stack | `flowchart TB` with `subgraph` per layer | Stacked abstraction levels |
| 16 | Venn | **(no native Mermaid)** — `flowchart` sketch or note | Overlap between sets |
| 17 | Pyramid / funnel | `flowchart TB` (narrowing) | Ranked hierarchy or conversion drop-off |
| 18 | Bar chart | `xychart-beta` *(Mermaid ≥11)* or note | Quantitative comparison across categories |
| 19 | Line chart | `xychart-beta` *(Mermaid ≥11)* or note | Continuous trends over time |
| 20 | Gantt | `gantt` | Tasks and phases on a timeline |
| 21 | Scatter plot | **(no native Mermaid)** — note | Distribution and correlation between two variables |
| 22 | High-level | `flowchart LR` with `subgraph` clusters | End-to-end data stack on a container cluster |
| 23 | Process | `flowchart` or `sequenceDiagram` | Multi-actor sequential process with data handoffs |
| 24 | Medallion | `flowchart LR` with `subgraph` per tier (bronze/silver/gold) | Multi-tier data storage with quality levels and access policies |
| 25 | Data flow | `flowchart LR` with `subgraph` per role/step | Role-scoped data flow: who does what at each pipeline step |
| 26 | DP integration | `flowchart LR` (sources → core → consumers) | Integration topology of a data platform |
| 27 | DP security matrix | **(no native Mermaid)** — table in prose or note | Per-role / per-component access permissions matrix |

## Syntax rules — the traps that break a render

A diagram the Mermaid parser rejects renders as an **error box**, not as a diagram
(boucle.dev#86 shipped one). `bin/check-mermaid` parses every `mermaid` fence in the
spec with the real Mermaid parser and blocks the spec gate on a parse error, so these
are not style preferences — a spec that breaks one of them goes back to triage.

Every rule below was verified against the parser; the wrong column is a real error,
not a guess.

| Trap | ❌ Rejected | ✅ Accepted |
|---|---|---|
| **`erDiagram` attributes take exactly `type name`** — a third bare token (a path, a value, an expression) is a parse error | `string file src/content/x.md` | `string file "src/content/x.md"` |
| … unless the third token is a key, which may then carry a quoted comment | — | `string id PK "primary key"` |
| **Parentheses inside an unquoted label** — in a node label or an edge label | `A[check-mermaid (parser)]`<br>`A -->\|reads (json)\| B` | `A["check-mermaid (parser)"]`<br>`A -->\|"reads (json)"\| B` |
| **Mermaid keywords as node ids** — `end`, `graph`, `subgraph`, `class`, `click`, `style` | `end --> A` | `gate_end["end"] --> A` |

Two things that are **allowed**, so do not contort the diagram to avoid them: a slash or
a dot in an unquoted label (`A[src/lib/x.sh]`, `content.config.ts --> B`), and a
multi-word `erDiagram` relationship label (`a ||--|| b : validated by`).

When in doubt, **quote the label**. A quoted label is never a syntax error; an unquoted
one is a bet on which characters the grammar happens to allow.

## Diagram discipline

- **Density ≤ 9 nodes.** Above 9 nodes, split into an overview + a detail diagram, or simplify. A wall of boxes is noise, not clarity.
- **One diagram per concept.** If the issue touches both a data model and a process, post two diagrams (one `erDiagram`, one `flowchart`) under the same `## Diagram` section, each with its own theme block and a one-line caption.
- **Every node is a distinct idea; every edge carries information.** If removing an edge wouldn't hurt, remove it.
- **Caption each diagram** with one line above the fence: what decision the human is validating by reading it.
- **The diagram is part of the spec contract** — the worker implements what it shows, the reviewer checks the implementation against it.
