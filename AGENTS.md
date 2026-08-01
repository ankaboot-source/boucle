# AGENTS.md — Guide des agents boucle

> **Maintenance** — Ce document capture les leçons apprises, les anti-patternes
> et les principes de fonctionnement des agents. **Toute nouvelle leçon découverte
> doit être ajoutée ici** pour éviter de répéter les mêmes erreurs. Voir
> [ARCHITECTURE.md](ARCHITECTURE.md) pour l'architecture système complète.

## Fichiers de référence (charter files)

Avant toute intervention sur une issue, les agents DOIVENT consulter les fichiers
suivants à la racine du dépôt :

- [DESIGN.md](DESIGN.md) — charte visuelle du site consommateur. **OBLIGATOIRE** :
  tout composant visuel DOIT s'y conformer.
- [AGENTS.md](AGENTS.md) — ce document. Leçons apprises et conventions agents.
- [README.md](README.md) — vue d'ensemble du projet et démarrage.
- [LOOP.md](LOOP.md) — configuration par consommateur (repo cible, cadence, gates, caps).
- [ARCHITECTURE.md](ARCHITECTURE.md) — architecture système complète (pipeline, state machine, diagrammes Mermaid).
- [CONTEXT.md](CONTEXT.md) — contexte du projet, stack technique, contraintes.

**INTERDIT** de commencer un travail sans avoir lu [ARCHITECTURE.md](ARCHITECTURE.md)
et [LOOP.md](LOOP.md).

## Rôles des agents

| Agent   | Modèle                       | Steps | Temp | Rôle                                                                                                              |
| ------- | ---------------------------- | ----- | ---- | ----------------------------------------------------------------------------------------------------------------- |
| triage  | ollama-cloud/minimax-m3      | 200   | 0.3  | Analyse l'issue, poste un commentaire structuré (TL;DR + Analyse + Critères d'acceptation + Classification S/M/L + Questions + Disposition) |
| worker  | ollama-cloud/minimax-m3      | 50    | —    | Implémente sur branche `boucle/<iid>`, lit `state.md`, utilise codebase-memory-mcp, commit conventionnel           |
| reviewer| ollama-cloud/glm-5.2         | 35    | 0.2  | Revue adverse contre URL preview, verdict ancré par SHA                                                          |
| e2e     | ollama-cloud/kimi-k2.7-code  | 20    | —    | Vérifie sur URL production, verdict ancré par SHA                                                                 |

Voir [ARCHITECTURE.md](ARCHITECTURE.md) pour le détail du pipeline et de la state machine.

## Principes de fonctionnement OBLIGATOIRES

Ces principes sont **NON NÉGOCIABLES**. Tout agent qui les enfreint introduit un
bug récurrent connu et documenté dans la section « Leçons apprises ».

1. **Post-early rule** — L'agent DOIT poster son commentaire ou verdict
   **D'ABORD**, puis le raffiner ensuite. Le gaspillage de steps (l'agent épuise
   son budget sans jamais poster) est le bug #1. **Règle** : un brouillon incomplet
   posté vaut TOUJOURS mieux qu'un raffinement jamais posté.

2. **Silent-failure detection** — `bin/oc` sort avec le code `3` si l'agent n'a
   produit aucun commentaire posté ou drafté. Le CI escalade alors vers un humain.
   Un agent qui ne produit rien DOIT être détecté, **JAMAIS** ignoré.

3. **Log-scraping fallback** — Le CI scrape le stdout de l'agent depuis
   `agent-output.log`. Si l'agent draft un commentaire mais épuise ses steps avant
   de poster, le CI le poste à sa place. **L'agent DOIT donc TOUJOURS produire
   son output sur stdout** (pas uniquement en mémoire, pas uniquement via tool calls).

4. **SHA-anchored verdict** — Le verdict du reviewer/e2e DOIT inclure le SHA
   en **hex nu** : ni quotes, ni whitespace, ni angle brackets.
   Format exact : `<!-- boucle:verdict v=1 role=reviewer sha=abc123def456 -->`.
   Le parseur CI **ÉCHOUE** si le format n'est pas respecté à la lettre.

5. **Idempotence des labels** — GitLab enregistre un *Resource Label Event* à
   chaque PUT, **même si le label est inchangé**. TOUJOURS vérifier si le label
   est déjà présent avant de l'écrire. Un no-op write pollue l'historique et
   peut fausser les transitions de la state machine.

6. **Anti-accumulation** — Le `dispatch` EXIT trap échoue si aucun fichier
   `.boucle-issue` n'est écrit. Un webhook qui ne produit pas de travail DOIT
   échouer, **JAMAIS** consommer un runner silencieusement.

7. **Rebase avant build** — Le build salit le working tree (`public/`).
   Le rebase **REFUSE** un tree sale. TOUJOURS rebase **AVANT** de build,
   **JAMAIS** l'inverse.

8. **Safety-net commit** — L'agent peut épuiser ses steps avant de committer.
   Le CI stage+commit automatiquement les changements non committés avant le
   rebase. L'agent n'a donc **PAS BESOIN** de se soucier de committer parfaitement
   — mais il DOIT éviter les changements non stageables (binaires, configs locales).

9. **Empty-MR guard** — Le worker peut produire zéro changement (steps épuisés).
   Le CI détecte `base_sha == head_sha` et re-trigger le worker ou escalade.
   Un worker DOIT produire au minimum un commit (même trivial) pour éviter cette
   branche.

10. **Serial merge** — `resource_group: boucle-merge` sérialise tous les merges.
    Chaque rebase est contre un `master` qui inclut les MRs précédemment fusionnées.
    **NE JAMAIS** paralléliser les merges.

## Leçons apprises (anti-patterns à ne pas reproduire)

Cette section est **LA PLUS IMPORTANTE** du document. Elle catalogue les
15 erreurs déjà commises et résolues. Toute nouvelle régression doit y être
ajoutée dans le même format `❌ NE PAS / ✅ FAIRE`.

1. **Gaspi de steps par raffinement itératif** (issue #27)
   - ❌ NE PAS raffiner le commentaire en boucle avant de poster.
   - ✅ FAIRE : poster le commentaire **D'ABORD** (même incomplet), puis raffiner
     dans un second commentaire si des steps restent.
   - Contexte : 6 notes de triage répétées, doctor re-trigger en boucle infinie.

2. **Échec silencieux non détecté**
   - ❌ NE PAS ignorer un agent qui ne produit aucun output.
   - ✅ FAIRE : `bin/oc` exit `3` → escalade vers humain. Casse la boucle de
     doctor re-trigger.

3. **MCP hang en CI**
   - ❌ NE PAS compter sur `codebase-memory-mcp` en CI (handshake MCP échoue
     dans la fenêtre de 30s).
   - ✅ FAIRE : `bin/oc` strip les MCP servers du config opencode en CI.
     L'agent utilise les outils `glob`/`grep`/`read` natifs à la place.

4. **No-op label write**
   - ❌ NE PAS `PUT` un label déjà présent.
   - ✅ FAIRE : vérifier l'état actuel avant d'écrire. GitLab enregistre un
     event à chaque `PUT` — un no-op pollue l'historique.

5. **Log-scraping manqué**
   - ❌ NE PAS produire un output uniquement en mémoire.
   - ✅ FAIRE : l'agent DOIT écrire sur stdout. Le CI scrape `agent-output.log`
     en fallback pour rattraper les drafts non postés.

6. **Verdict sans SHA**
   - ❌ NE PAS poster un verdict sans SHA en hex nu.
   - ✅ FAIRE : `<!-- boucle:verdict v=1 role=reviewer sha=abc123 -->` —
     pas de quotes, pas de whitespace, pas d'angle brackets autour du SHA.

7. **Webhook sans travail**
   - ❌ NE PAS laisser un webhook consommer un runner sans produire de travail.
   - ✅ FAIRE : `dispatch` EXIT trap échoue si aucun `.boucle-issue` n'est écrit.

8. **Merge parallèle**
   - ❌ NE PAS paralléliser les merges (rebase contre un `master` stale).
   - ✅ FAIRE : `resource_group: boucle-merge` sérialise. Chaque rebase inclut
     les MRs précédemment fusionnées.

9. **OUTPUT_TOKEN_MAX trop petit**
   - ❌ NE PAS utiliser 1200 tokens max pour le triage (trop petit pour un
     commentaire structuré complet).
   - ✅ FAIRE : 4000 tokens (doit matcher reviewer/e2e).

10. **Build avant rebase**
    - ❌ NE PAS build avant rebase (`public/` salit le tree, rebase échoue).
    - ✅ FAIRE : rebase **AVANT** build, toujours.

11. **Détection d'assignation bot**
    - Un humain peut déclencher boucle en **assignant** l'issue au bot
      (pas de label nécessaire). Le dispatch DOIT détecter l'assignation
      comme trigger valide, en plus du label `boucle:queued`.

12. **Cap de concurrence**
    - `BOUCLE_MAX_PARALLEL_ISSUES` défère le trigger worker si trop d'issues
      sont en cours. **JAMAIS** désactiver ce cap — il évite la saturation
      du runner et les conditions de course sur le rebase.

13. **Hiérarchie de sub-issues**
    - Utiliser l'API work-items hierarchy pour parent-child.
    - **Fallback** : `legacy split-parent marker` si l'API n'est pas disponible
      sur l'instance GitLab cible.

14. **Commit de sécurité**
    - L'agent peut épuiser ses steps avant de committer. Le CI stage+commit
      automatiquement avant rebase. **PAS BESOIN** de paniquer sur un commit
      raté — mais les changements non stageables (binaires) seront perdus.

15. **MR vide**
    - Le worker peut produire zéro changement (steps épuisés). Le CI détecte
      `base_sha == head_sha` → re-trigger ou escalade. Un worker DOIT produire
      au minimum un commit pour franchir ce guard.

<!-- codebase-memory-mcp:start -->
## Codebase Knowledge Graph (codebase-memory-mcp)

Ce projet utilise `codebase-memory-mcp` pour maintenir un graphe de connaissances
du code. **TOUJOURS** préférer les outils MCP à `grep`/`glob`/`file-search`
pour la découverte de code.

Le graphe est construit une fois (par CI ou localement) et se synchronise
automatiquement. Si `search_graph` ne retourne rien, lancer `index_repository`
avec le chemin du repo, puis réessayer.

### Ordre de priorité

1. `search_graph` — trouver fonctions, classes, routes, variables par pattern
2. `trace_path` — tracer qui appelle une fonction ou ce qu'elle appelle
3. `get_code_snippet` — lire le code source d'une fonction/classe précise
4. `query_graph` — exécuter des requêtes Cypher pour des patterns complexes
5. `get_architecture` — résumé haut-niveau du projet

### Quand retomber sur grep/glob

- Recherche de littéraux string, messages d'erreur, valeurs de config
- Recherche dans des fichiers non-code (Dockerfiles, scripts shell, configs)
- Quand les outils MCP retournent des résultats insuffisants

### Exemples

- Trouver un composant page : `search_graph(name_pattern=".*PrisesDeParole.*")`
- Qui appelle un helper : `trace_path(function_name="getCategory", direction="inbound")`
- Lire une source : `get_code_snippet(qualified_name="src/pages/prises-de-parole.astro")`
- Vue d'ensemble : `get_architecture(aspects=["all"])`
<!-- codebase-memory-mcp:end -->

## Conventions de commit

**TOUJOURS** committer les changements avant de finir. Les éditions non
committées ne sont **PAS** durables — elles peuvent être perdues si le
working tree est reset, checkout, ou si la session se termine.

### Format

- Format obligatoire : `feat: <description> (#<iid>) [skip ci]`
- Conventional commits : `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`
- **JAMAIS** de rebase, merge, push ou deploy par le worker — c'est le CI qui s'en charge.
- **TOUJOURS** vérifier `git log --oneline -1` et `git status` (working tree clean)
  après chaque commit.

### Procédure

1. Stage les fichiers modifiés : `git add <paths>` (être précis, **JAMAIS**
   `git add -A` sauf si `git status` est vérifié propre).
2. Committer avec un message conventional-commit concis.
3. Vérifier que le commit est passé : `git log --oneline -1` et `git status`.

**JAMAIS** push sauf demande explicite. **JAMAIS** amend ou force-push sauf
demande explicite. Si un commit échoue (hook pre-commit rejeté), corriger et
créer un **nouveau** commit — ne **JAMAIS** amender le commit raté.

## Workflow de fix upstream

Le workflow upstream-first est défini dans
[`.opencode/UPSTREAM-FIX-WORKFLOW.md`](.opencode/UPSTREAM-FIX-WORKFLOW.md).
Ce fichier est **portable** : il ship avec boucle quand installé dans les
projets consommateurs (via le répertoire `.opencode/`).

### Règle d'or

**Fix upstream dans boucle D'ABORD, puis update boucle dans le consommateur,
PUIS remédier les données existantes.** Ordre obligatoire :

1. Corriger le bug dans le repo boucle upstream.
2. Mettre à jour l'installation de boucle dans le projet consommateur.
3. Remédier les données existantes impactées par le bug.

### INTERDIT

- **JAMAIS** patcher un consommateur pour contourner un défaut boucle.
- **JAMAIS** introduire un workaround local qui ne sera pas reporté upstream.
- **JAMAIS** masquer un bug boucle par une config consommateur.

Un bug sur un projet consommateur DOIT être tracé jusqu'à sa cause racine
dans boucle et corrigé là-bas d'abord.

## Voir aussi

- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture système, pipeline, diagrammes Mermaid
- [CONTEXT.md](CONTEXT.md) — Contexte du projet, stack technique, contraintes
- [README.md](README.md) — Vue d'ensemble, démarrage, usage
- [DESIGN.md](DESIGN.md) — Charte visuelle du site consommateur
- [LOOP.md](LOOP.md) — Configuration par consommateur
- [.opencode/UPSTREAM-FIX-WORKFLOW.md](.opencode/UPSTREAM-FIX-WORKFLOW.md) — Workflow de fix upstream
