# AGENTS.md

Instructions for AI agents working on the **boucle** project.

<!-- codebase-memory-mcp:start -->
## Codebase Knowledge Graph (codebase-memory-mcp)

This project uses codebase-memory-mcp to maintain a knowledge graph of the codebase.
ALWAYS prefer MCP graph tools over grep/glob/file-search for code discovery.

The graph is built once (by CI or locally) and auto-syncs on changes. If `search_graph`
returns no results, run `index_repository` with the repo path, then retry.

### Priority Order
1. `search_graph` — find functions, classes, routes, variables by pattern
2. `trace_path` — trace who calls a function or what it calls
3. `get_code_snippet` — read specific function/class source code
4. `query_graph` — run Cypher queries for complex patterns
5. `get_architecture` — high-level project summary

### When to fall back to grep/glob
- Searching for string literals, error messages, config values
- Searching non-code files (Dockerfiles, shell scripts, configs)
- When MCP tools return insufficient results

### Examples
- Find a page component: `search_graph(name_pattern=".*PrisesDeParole.*")`
- Who calls a helper: `trace_path(function_name="getCategory", direction="inbound")`
- Read source: `get_code_snippet(qualified_name="src/pages/prises-de-parole.astro")`
- Architecture overview: `get_architecture(aspects=["all"])`
<!-- codebase-memory-mcp:end -->

## Bug resolution workflow

The upstream-first bug fix workflow is defined in
[`.opencode/UPSTREAM-FIX-WORKFLOW.md`](.opencode/UPSTREAM-FIX-WORKFLOW.md).

That file is portable: it ships with boucle when installed in consumer
projects (via the `.opencode/` directory). Read it and follow it for any
bug reported on a consumer project.

Summary: **fix upstream in boucle first, then update boucle in the
consumer, then remediate existing data.** Never patch a consumer to
work around a boucle defect.

## Committing changes

**Always commit your changes before finishing.** Edits that are not
committed are not durable — they can be lost if the working tree is
reset, checked out, or if the session ends. After completing any work:

1. Stage the files you changed: `git add <paths>` (be specific; avoid
   `git add -A` unless you have verified `git status` is clean of
   unrelated changes).
2. Commit with a concise conventional-commit message matching the repo
   style (e.g. `feat: add image reading from issues`, `fix: ...`,
   `docs: ...`, `chore: ...`).
3. Verify the commit landed: `git log --oneline -1` and
   `git status` (working tree should be clean).

Do not push unless explicitly asked. Do not amend or force-push unless
explicitly asked. If a commit fails (e.g. a pre-commit hook rejects
it), fix the issue and create a new commit — do not amend the failed
one.

## Charte design

[`./DESIGN.md`](./DESIGN.md) est la **référence obligatoire** pour toute
contribution touchant au design, à la typographie, aux couleurs, à la
mise en page, aux animations et aux symboles du site. Avant toute
proposition visuelle (nouveau composant, variante de CTA, retouche
typographique, motion, palette, symbolique), consulter ce document et
s'aligner sur sa direction (brutalisme éditorial) et ses interdits.

Les **trois règles d'or** énoncées au §4 de `DESIGN.md` doivent guider
chaque décision et chaque revue :

1. **Intentionnalité** — chaque élément a une raison d'être là. Si on ne
   peut pas dire laquelle en une phrase, on l'enlève. Le décoratif pur
   est interdit.
2. **Imperfection** — on assume l'aspérité : coins durs, contrastes
   francs, hiérarchies sans nuance. Mieux vaut une page honnête et rude
   qu'une page léchée et oubliable.
3. **Caractère** — une voix de collectif, directe, solidaire, sans
   complaisance ni condescendance. Pas une voix de chatbot, pas une voix
   d'ONG corporate.

Conformément au §6 de `DESIGN.md`, **toute PR touchant au design doit
citer `DESIGN.md` dans sa description** et expliquer — même brièvement —
où se situent les choix par rapport aux interdits du §2 et aux trois
règles d'or du §4. Une PR de design qui ne cite pas `DESIGN.md` est
incomplète et doit être amendée avant revue.

Les valeurs concrètes (couleurs, échelles, durées, familles typo,
tokens) vivent dans [`src/styles/tokens.css`](src/styles/tokens.css) ;
`DESIGN.md` en expose l'intention, les interdits et la direction
esthétique.
