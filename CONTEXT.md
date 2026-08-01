# CONTEXT.md — Contexte du projet boucle

> **Maintenance** — Ce document capture le contexte, la stack technique et les
> contraintes de boucle. Toute modification de la portée, de la stack ou des
> contraintes doit le mettre à jour. Voir [AGENTS.md](AGENTS.md) pour les
> conventions de contribution.

## Purpose

boucle est une boucle de développement autonome qui transforme des issues
GitLab en sites déployés sur Cloudflare Pages, sans intervention humaine
continue. L'objectif principal est de **réduire le coût humain du
développement de sites militants** (Urgence Palestine et autres collectifs
associatifs) tout en maintenant la qualité par :

- **Revue adversaire** systématique (agent `reviewer`, modèle différent du
  worker) contre l'URL preview.
- **Vérification de bout en bout** sur l'URL production (agent `e2e`).
- **Spec gate humain** pour les issues de taille M, garantissant que
  l'humain valide l'interprétation avant implémentation.

boucle est aussi auto-hébergée : le projet boucle se met à jour depuis son
propre upstream, et l'orchestrateur CI est réutilisable dans plusieurs
projets consommateurs via submodule.

## Stack technique

| Couche | Technologie |
| --- | --- |
| Forge | GitLab (framagit.org par défaut, GitLab.com supporté) |
| CI/CD | GitLab CI — pipeline 8 stages (check, dispatch, triage, work, review, merge, deploy, verify) |
| Orchestrateur agents | `opencode` CLI, lancé via `bin/oc` (harness avec retry, empty-output guard, metrics, log capture) |
| Agents IA | 4 agents spécialisés sous `.opencode/agents/` |
| Modèles LLM | `minimax-m3` (triage, worker), `glm-5.2` (reviewer), `kimi-k2.7-code` (e2e) |
| Coding agent | `pi` (`.pi/agents/*.md`) — utilisé par `worker` |
| Knowledge graph | `codebase-memory-mcp` — utilisé par triage/worker (stripé en CI) |
| Deploy target | Cloudflare Pages (via `wrangler`) |
| Site consommateur | Astro — static site generation |
| Tests shell | `bats` (Bash Automated Testing System) |
| Lint shell | `shellcheck`, `shfmt` |
| Hooks | `pre-commit` (configuré par `bin/setup`) |

## Contraintes

Ces contraintes sont **non négociables** et guident toute décision
d'architecture ou d'implémentation. Voir [AGENTS.md](AGENTS.md) pour les
leçons apprises détaillées.

- **Fail-open** : l'auto-update ne doit **JAMAIS** bloquer le pipeline. Toute
  erreur réseau, de signature ou de tarball est convertie en warning + exit 0.
  Mieux vaut une version stale qu'un pipeline cassé.
- **Upstream-first** : un bug doit être corrigé dans boucle **D'ABORD**, puis
  la mise à jour est appliquée dans le consommateur, puis les données
  existantes impactées sont remédiées. Vous ne devez **JAMAIS** patcher un
  consommateur pour contourner un défaut boucle.
- **Label-driven state machine** : l'état de chaque issue est piloté
  exclusivement par les labels GitLab `boucle:*`. Pas de base de données
  externe, pas d'API state séparée. Les labels sont la source de vérité.
- **Post-early rule** : les agents doivent poster leur commentaire **D'ABORD**
  (même partiel), puis raffiner ensuite. Le gaspillage de steps par
  raffinement itératif est le bug #1 documenté. Un brouillon incomplet posté
  vaut TOUJOURS mieux qu'un raffinement jamais posté.
- **Idempotence** : tous les scripts `bin/*` (`setup`, `doctor`, `update`,
  `oc`) doivent être idempotents. Rejouer un script ne doit avoir aucun effet
  de bord supplémentaire.
- **Serial merge** : `resource_group: boucle-merge` sérialise tous les merges.
  Vous ne devez JAMAIS paralléliser les merges — un rebase concurrent contre
  un `master` stale produit des conflits et des conditions de course.
- **Anti-feedback-loop** : l'auto-update doit skipper les pipelines
  déclenchés par push-source (variable `CI_PIPELINE_SOURCE == "push"`),
  sinon on tombe dans une boucle `update → commit → update → commit…`.
- **SHA-anchored verdict** : les verdicts `reviewer` et `e2e` doivent inclure
  le SHA en hex nu, sans quotes, sans whitespace, sans angle brackets.
  Format exact : `<!-- boucle:verdict v=1 role=reviewer sha=abc123def456 -->`.
  Le parseur CI ÉCHOUE si le format n'est pas respecté à la lettre.

## Limites connues

- **codebase-memory-mcp hang en CI** : le handshake MCP peut dépasser la
  fenêtre de 30 secondes du runner. `bin/oc` strip les MCP servers du config
  opencode en CI ; les agents retombent sur les outils natifs
  `glob`/`grep`/`read`.
- **Steps épuisés avant commit** : le worker peut épuiser son budget de steps
  avant de committer. Le CI applique un safety-net commit automatique avant
  rebase pour ne pas perdre le travail. L'agent doit éviter les changements
  non stageables (binaires, configs locales non-committées).
- **Verdict sans SHA** : si l'agent reviewer poste un verdict non conforme au
  format SHA-anchored, le CI tente un fallback SHA-unanchored parsing. Ce
  fallback est best-effort et ne doit pas être considéré comme une garantie.
- **No-op label writes** : GitLab enregistre un *Resource Label Event* à
  chaque PUT, même si le label est inchangé. Tout code de label-manipulation
  doit vérifier l'état actuel avant d'écrire, sinon l'historique d'events
  explose et peut fausser les transitions de state machine.
- **MR vide** : si le worker produit zéro changement, le CI détecte
  `base_sha == head_sha` et re-trigger ou escalade. Le worker DOIT produire
  au minimum un commit (même trivial) pour franchir ce guard.
- **Webhook sans travail** : un webhook qui ne produit pas de fichier
  `.boucle-issue` ne doit pas consommer un runner silencieusement. L'EXIT trap
  de `dispatch` fait échouer le job si aucun travail n'est produit.

## Décisions architecturales clés

1. **Label-driven state machine** (vs DB externe) : pas de base de données,
   pas d'API state séparée. Les labels GitLab sont la source de vérité unique.
   Avantage : zéro infra à gérer, tout est versionné dans Git via les
   resource label events. Coût : couplage fort à l'API GitLab.

2. **4 agents spécialisés** (vs 1 agent généraliste) : chaque agent a un
   modèle adapté à sa tâche (`minimax-m3` pour l'analyse et l'écriture,
   `glm-5.2` pour la revue adversaire, `kimi-k2.7-code` pour la vérification
   e2e). Le reviewer utilise un **modèle différent** du worker pour limiter
   la sycophancy.

3. **`bin/oc` comme harness unique** : un seul entrypoint wrap `opencode run`
   avec gestion du retry, empty-output guard (exit code 3 si rien posté),
   metrics, log capture (CI scrape `agent-output.log` en fallback), et
   stripping des MCP servers en CI.

4. **Fail-open self-update** : l'auto-update ne bloque jamais le pipeline.
   Toute erreur est convertie en warning + exit 0. Le tracking de version
   via `.boucle-version` permet de voir d'un coup d'œil si on est à jour ou
   stale. Trade-off : on peut accumuler du retard sur les versions upstream.

5. **Event-driven catchup** : le catchup des merges directs (sans passer par
   la MR boucle) est déclenché par événement (webhook MR merge), pas par
   polling `doctor`. Évite une boucle `poll → nothing → poll`.

6. **Human-readable spec validation** : le commentaire triage DOIT commencer
   par un TL;DR de 2-4 phrases en langage non-technique. La preview visuelle
   est opt-in. L'approbation se fait par emoji (`:+1:`) ou reply courte.
   Réduit la friction de validation sans sacrifier la rigueur.

7. **Serial merge via `resource_group`** : tous les jobs `merge` partagent le
   même `resource_group: boucle-merge`. GitLab sérialise leur exécution.
   Chaque rebase part d'un `master` qui inclut les MRs précédemment
   fusionnées.

## Voir aussi

- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture système, pipeline, diagrammes Mermaid
- [AGENTS.md](AGENTS.md) — Guide des agents, leçons apprises, anti-patternes
- [README.md](README.md) — Vue d'ensemble, démarrage, usage
- [DESIGN.md](DESIGN.md) — Charte visuelle du site consommateur
- [LOOP.md](LOOP.md) — Configuration par consommateur
- [.opencode/UPSTREAM-FIX-WORKFLOW.md](.opencode/UPSTREAM-FIX-WORKFLOW.md) — Workflow de fix upstream
