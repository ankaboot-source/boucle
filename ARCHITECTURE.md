# ARCHITECTURE.md — Architecture de boucle

> **Maintenance** — Ce document est la référence architecturale de boucle.
> Toute modification du code, du pipeline CI, ou des agents doit mettre à jour
> ce document en conséquence. Voir [AGENTS.md](AGENTS.md) pour les conventions
> de contribution.

---

## 1. Vue d'ensemble

Boucle est une boucle de développement autonome : un issue GitLab déclenche un pipeline CI qui orchestre 4 agents IA (triage, worker, reviewer, e2e) pour analyser, implémenter, revoir, fusionner et déployer sur Cloudflare Pages. La machine à états est pilotée par labels GitLab (`boucle:*`).

**Principe fondamental** — la boucle est pilotée par **labels GitLab**, pas par un orchestrateur central. Chaque transition d'état est un job CI qui observe les labels, agit, puis ré-applique un nouveau label. Cela rend le système résilient aux pannes (un job échoué est simplement relancé), distribué (n'importe quel runner peut reprendre) et auditable (chaque transition est visible dans le timeline de l'issue).

**Garde-fous humains** — boucle n'agit jamais seule pour deux décisions :
1. **Validation du cahier des charges** (`boucle:spec-review`) — l'auteur de l'issue doit confirmer que la spec produite par le triage correspond à son besoin.
2. **Approbation de la Merge Request** (`boucle:approval`) — un humain doit cliquer "Merge" sur la MR.

Tout le reste — triage, implémentation, revue, déploiement, vérifications e2e — est automatique.

---

## 2. Architecture générale

```mermaid
flowchart LR
    subgraph Forge["GitLab (framagit.org)"]
        Issues[Issues + labels boucle:*]
        MRs[Merge Requests]
        Labels[Labels boucle:*]
        Webhook[Webhook]
    end

    subgraph Pipeline["GitLab CI Pipeline (8 stages)"]
        Check[check]
        Dispatch[dispatch]
        Triage[triage]
        Work[work]
        Review[review]
        Merge[merge]
        Deploy[deploy]
        Verify[verify]
        Doctor[doctor]
    end

    subgraph Scripts["bin/"]
        Oc[bin/oc]
        Setup[bin/setup]
        Update[bin/update]
        Doctor[bin/doctor]
        Fetch[bin/fetch-issue-attachments]
        Render[bin/render-preview.cjs]
        Collapse[bin/collapse-duplicate-notes]
    end

    subgraph Agents[".opencode/agents/"]
        ATriage[triage.md]
        AWorker[worker.md]
        AReviewer[reviewer.md]
        AE2E[e2e.md]
    end

    Pi[.pi/ — pi coding agent]

    subgraph Deploy["Cloudflare Pages"]
        Preview[Preview URL<br/>sous-domaine.pages.dev]
        Prod[Production URL]
    end

    subgraph Memory["codebase-memory-mcp"]
        KG[Knowledge Graph<br/>AST + sémantique]
    end

    Issues -->|webhook| Webhook
    Webhook --> Dispatch
    Check --> Pipeline
    Dispatch --> Triage
    Triage --> Work
    Work --> Review
    Review --> Merge
    Merge --> Deploy
    Deploy --> Verify
    Verify --> Issues

    Triage --> ATriage
    Work --> AWorker
    Review --> AReviewer
    Verify --> AE2E

    Pipeline --> Oc
    Pipeline --> Update
    Setup -.->|jour 0| Pipeline
    Doctor -.->|scheduled| Pipeline
    Fetch -.-> Work
    Render -.-> Work
    Collapse -.-> Pipeline

    Work --> Pi
    Triage --> KG
    Worker --> KG
    Reviewer --> KG
    E2E --> KG

    Work --> Preview
    Merge --> Prod
    Verify --> Prod
```

---

## 3. Pipeline CI

Le pipeline CI est composé de **8 stages** qui s'enchaînent via déclencheurs GitLab (webhook, trigger API, schedule). Chaque stage est idempotent : un job ré-exécuté après échec reprend l'état courant des labels sans corrompre la machine à états.

```mermaid
flowchart TD
    Start([Webhook GitLab<br/>issue.label.updated]) --> Check[check<br/>shellcheck + shfmt + bats]
    Check --> Dispatch[dispatch<br/>webhook entry point]

    Dispatch -->|bin/update first| UpdateJob[Auto-update<br/>tarball + SYNC_PATHS]
    UpdateJob -->|fail-open| Dispatch

    Dispatch -->|event = issue| Triage[triage<br/>bin/oc triage]
    Dispatch -->|event = MR| Review[review<br/>bin/oc reviewer]

    Triage --> Disposition{Disposition?}
    Disposition -->|READY + Size L| Human[boucle:human<br/>terminal]
    Disposition -->|NEEDS-INFO| NeedsInfo[boucle:needs-info<br/>pause]
    Disposition -->|NEEDS-SPLIT| Split[boucle:split<br/>créer sous-issues]
    Disposition -->|READY + Size M| SpecGate[Spec gate<br/>product profile]
    Disposition -->|READY + Size S| Work

    SpecGate -->|user valide| SpecDone[boucle:todo]
    SpecGate -->|user rejette| SpecReject[boucle:needs-info]
    SpecDone --> Work
    SpecReject --> NeedsInfo

    NeedsInfo -->|user répond| Triage
    Split -->|sous-issues fermés| Triage

    Work --> PRWorker[bin/oc worker<br/>branche + build + preview + MR]
    PRWorker --> MRState{MR state?}

    MRState -->|MR opened| Review
    MRState -->|push sur MR| Review

    Review --> Verdict{Verdict?}
    Verdict -->|PASS| Approval[boucle:approval<br/>pause utilisateur]
    Verdict -->|FAIL + iter&lt;MAX| Retry[boucle:todo<br/>retry]
    Verdict -->|FAIL + iter≥MAX| Human
    Verdict -->|UNCERTAIN| Human

    Approval -->|user approuve| Merger{Trigger?}
    Merger -->|rebase+merge| MergeJob[merge<br/>merger]
    Merger -->|direct| CatchupJob[merge<br/>catchup]

    MergeJob --> Deploy[deploy<br/>build + wrangler deploy]
    CatchupJob --> Deploy

    Deploy --> E2eJob[verify<br/>bin/oc e2e sur prod]
    E2eJob --> E2eVerdict{E2E?}
    E2eVerdict -->|PASS| Done[boucle:done<br/>terminal]
    E2eVerdict -->|FAIL + iter&lt;MAX| Retry
    E2eVerdict -->|FAIL + iter≥MAX| Human
    E2eVerdict -->|UNCERTAIN| Human

    DoctorSched[doctor<br/>schedule: */10 min] -.->|re-trigger stuck| Triage
    DoctorSched -.->|re-trigger stuck| Work
    DoctorSched -.->|re-trigger stuck| Review
```

**Notes sur le pipeline**
- `check` est exécuté sur les branches et les tags — c'est un quality gate (shellcheck, shfmt, bats) qui ne dépend pas de l'état de boucle.
- `dispatch` est le **seul** point d'entrée webhook. Il applique systématiquement `bin/update` en premier pour rester à jour.
- `merge` a deux sous-flows : **merger** (rebase interactif + merge après approbation) et **catchup** (merge direct quand la MR est déjà approved mais le pipeline merge a échoué).
- `doctor` est **schedulé** (cron `*/10 min`) et **observe** les issues bloquées (seuil `BOUCLE_STALENESS_THRESHOLD`) pour les re-déclencher.

---

## 4. Machine à états des labels

```mermaid
stateDiagram-v2
    [*] --> triage : issue ouverte<br/>webhook issue.label

    triage --> needs_info : triage verdict NEEDS-INFO
    triage --> spec_review : READY + Size M
    triage --> todo : READY + Size S
    triage --> human : READY + Size L
    triage --> split : NEEDS-SPLIT

    needs_info --> triage : auteur répond<br/>(commentaire)

    split --> triage : tous sous-issues fermés

    spec_review --> todo : auteur valide spec
    spec_review --> needs_info : auteur rejette spec

    todo --> working : worker démarre<br/>(trigger pipeline)
    working --> review : MR ouverte / push
    working --> human : échec technique<br/>non-récupérable

    review --> approval : reviewer PASS
    review --> todo : reviewer FAIL<br/>iter < BOUCLE_MAX_ITERATIONS
    review --> human : reviewer FAIL<br/>iter ≥ MAX
    review --> human : reviewer UNCERTAIN

    approval --> merging : auteur approuve MR
    approval --> working : auteur demande changes

    merging --> deploy : merge commit créé
    deploy --> verify : déploiement CF Pages OK

    verify --> done : e2e PASS
    verify --> todo : e2e FAIL + iter < MAX
    verify --> human : e2e FAIL + iter ≥ MAX
    verify --> human : e2e UNCERTAIN

    done --> [*]
    human --> [*]
```

**Conventions**
- Les labels sont **toujours** au singulier dans la machine à états et au pluriel dans les commentaires (lisibilité).
- Un issue **ne doit jamais** avoir deux labels `boucle:*` actifs simultanément (le runner applique `replace_labels`).
- Les transitions vers `human` ou `done` sont **terminales** : aucun agent ne retire ces labels.
- Une ré-ouverture d'issue (reopen) remet l'état à `triage` après nettoyage des autres labels `boucle:*`.

---

## 5. Architecture des agents

### Tableau des agents

| Agent | Modèle | Steps | Rôle |
| --- | --- | --- | --- |
| **triage** | `ollama-cloud/minimax-m3` | 200 | Analyse l'issue, poste un commentaire structuré (TL;DR + Analyse + Critères d'acceptation + Classification S/M/L + Questions + Disposition `READY`/`NEEDS-INFO`/`NEEDS-SPLIT`) |
| **worker** | `ollama-cloud/minimax-m3` | 50 | Implémente sur une branche `boucle/<iid>`, build, déploie la preview Cloudflare, crée la MR |
| **reviewer** | `ollama-cloud/glm-5.2` | 35 | Revue adversaire contre URL preview, verdict `PASS`/`FAIL`/`UNCERTAIN` ancré par SHA de commit |
| **e2e** | `ollama-cloud/kimi-k2.7-code` | 20 | Vérifie sur URL de production, verdict `PASS`/`FAIL`/`UNCERTAIN` |

### Séquence d'interaction

```mermaid
sequenceDiagram
    participant U as Auteur (humain)
    participant G as GitLab (issue + MR)
    participant CI as CI Pipeline
    participant T as triage
    participant W as worker
    participant R as reviewer
    participant CF as Cloudflare Pages
    participant E as e2e

    U->>G: Ouvre issue
    G->>CI: webhook (boucle:triage)
    CI->>T: bin/oc triage
    T->>G: commentaire structuré + boucle:todo

    Note over U,G: spec-review si Size M<br/>validation humaine

    CI->>W: bin/oc worker (trigger)
    W->>G: branche boucle/<iid> + commits
    W->>CF: wrangler pages deploy (preview)
    CF-->>W: URL preview
    W->>G: MR ouverte → boucle:review

    CI->>R: bin/oc reviewer
    R->>CF: GET preview URL (par SHA)
    CF-->>R: HTML + assets
    R->>G: commentaire + verdict

    alt verdict PASS
        R->>G: boucle:approval
        U->>G: approuve MR
        G->>CI: MR merge event
        CI->>CF: deploy production
        CF-->>CI: URL prod
        CI->>E: bin/oc e2e
        E->>CF: navigue + screenshots
        E->>G: verdict
        alt e2e PASS
            E->>G: boucle:done
        else e2e FAIL
            E->>G: boucle:todo (retry) ou boucle:human
        end
    else verdict FAIL
        R->>G: boucle:todo (retry si iter<MAX)
    else verdict UNCERTAIN
        R->>G: boucle:human
    end
```

**Notes sur les agents**
- Chaque agent est défini dans `.opencode/agents/<role>.md` et invoqué via `bin/oc <role>`.
- Le **harness** (`bin/oc`) wrappe `opencode run`, applique le mapping de modèle, gère le retry (3x backoff exponentiel), capture les logs et applique un **empty-output guard** (sortie vide → exit 3 → retry).
- Le **reviewer** et **e2e** sont **adversariaux** : ils doivent chercher activement des défauts, pas valider.
- Le **triage** ne doit **jamais** modifier le code — il produit uniquement un commentaire structuré sur l'issue.

---

## 6. Scripts bin/

| Script | Rôle |
| --- | --- |
| `bin/oc` | Harness entrypoint : wrap `opencode run`, role mapping (triage→m3, worker→m3, reviewer→glm-5.2, e2e→kimi-k2.7), retry 3x avec backoff exponentiel, **empty-output guard** (sortie vide → exit 3 → retry), capture des logs vers `.boucle/<issue>/`, métriques Prometheus, timeout configurable |
| `bin/setup` | Setup infrastructure jour 0 (**idempotent**) : crée le runner tag, les variables CI, les labels `boucle:*`, le board, la branche protégée `main`, ajoute le bot comme member, génère le trigger token, configure le webhook, crée le projet Cloudflare Pages |
| `bin/update` | Auto-update depuis upstream : fetch latest tag/commit, tarball download, extraction des `SYNC_PATHS`, **fail-open** (toute erreur → warning + exit 0), tracking via `.boucle-version`, modes `release` (latest tag) ou `dev` (latest commit on main), anti-feedback-loop guard (skip sur `push-source`) |
| `bin/doctor` | Vérification jour 0 et diagnostique : ~20 checks (labels présents, CI variables, branch protection, runner disponible, agents résolvables, CF Pages joignable, version `.boucle-version` à jour) |
| `bin/fetch-issue-attachments` | Télécharge les pièces jointes d'une issue vers `.boucle/<issue>/attachments/` avec quotas `BOUCLE_IMAGE_MAX_BYTES` et `BOUCLE_IMAGE_TOTAL_MAX_BYTES` |
| `bin/render-preview.cjs` | Render `preview.html` → `preview.png` via `@sparticuz/chromium` + `puppeteer-core` (Layer de preview visuelle attaché aux MRs) |
| `bin/collapse-duplicate-notes` | Collapser les commentaires dupliqués : si un agent poste v2, le CI remplace le premier (Note ID stable) |

---

## 7. Mécanisme d'auto-update

Boucle s'auto-met à jour depuis son propre upstream. Cela permet aux consommateurs de bénéficier des correctifs sans intervention manuelle.

**Configuration**
- `SYNC_PATHS` (constante dans `bin/update`) :
  - `bin`
  - `.pi`
  - `.gitlab-ci.yml`
  - `.opencode/opencode.json`
  - `.opencode/agents`
- `.boucle-version` (fichier à la racine du consommateur) : SHA court du dernier sync.

**Modes**
- `release` (défaut) : télécharge le dernier **tag** GitHub/GitLab. Stable, sans surprise.
- `dev` : télécharge le dernier **commit sur main**. Pour testeurs, peut casser.

**Garde-fous**
- **Fail-open** : toute erreur réseau, HTTP, ou d'extraction est convertie en warning + exit 0. Le pipeline continue avec l'ancienne version. Une boucle qui ne se met plus à jour est moins grave qu'une boucle qui plante les déploiements.
- **Anti-feedback-loop** : sur les pipelines où la source du push est le job `update` lui-même (`$CI_PIPELINE_SOURCE == "push"`), `bin/update` est skippé. Sinon, le push de `.boucle-version` redéclencherait immédiatement un autre update.
- **Premier run** : si `.boucle-version` n'existe pas, `bin/update` le crée avec le SHA actuel, commit, et push. Cela évite qu'un consommateur neuf déclenche un diff parasite au premier pipeline.

**Workflow**
1. `dispatch` démarre → `bin/update` s'exécute en premier.
2. Compare le tag/commit upstream avec `.boucle-version` local.
3. Si différent, télécharge le tarball, extrait `SYNC_PATHS`, écrit `.boucle-version`, commit, push.
4. Le push déclenche un nouveau `dispatch` (mais skip update grâce au feedback-loop guard).

---

## 8. Points d'extension

Boucle expose **5 seams** (coutures) — des points d'extension documentés et stables. Pour étendre boucle, vous modifiez l'un de ces seams :

### 1. Machine à états (labels)
Le contrat est : **un label `boucle:<state>` par issue, exactement un**. Pour ajouter un état, il faut :
1. Ajouter le label via `bin/setup` (idempotent — tolérance aux doublons).
2. Ajouter la transition dans le YAML CI (un job supplémentaire ou une branche dans un job existant).
3. Documenter la transition dans ce fichier (section 4).

### 2. Rôles des agents
Chaque agent est un fichier `.opencode/agents/<role>.md` invoqué par `bin/oc <role>`. Pour ajouter un rôle (ex. `security-reviewer`) :
1. Créer `.opencode/agents/security-reviewer.md` avec frontmatter `{model, steps}`.
2. Ajouter le mapping modèle dans `bin/oc`.
3. Ajouter un stage CI qui l'invoque après un label déclencheur.

### 3. Harness (bin/oc)
Le harness est volontairement mince : il wrap `opencode run`. Pour ajouter une fonctionnalité (ex. cache de modèles, télémétrie custom), patcher `bin/oc` en gardant l'API stable : `bin/oc <role> <issue-iid>`.

### 4. Forge (GitLab API)
Tous les appels GitLab passent par `glab` (CLI officiel). Pour supporter une autre forge (GitHub, Gitea), remplacer l'implémentation derrière les helpers dans `bin/oc` sans toucher aux agents.

### 5. Work state (.boucle/<issue>/state.md)
Chaque issue a un fichier d'état dans `.boucle/<issue>/state.md`, **seedé depuis le triage**. Les agents y lisent/écrivent leur progression, leurs hypothèses, leurs découvertes. Pour ajouter un champ (ex. `## Stratégie de tests`), documenter le schéma dans ce fichier (section 5) et mettre à jour le prompt du triage.

---

## 9. Variables CI

Toutes les variables de configuration de boucle sont préfixées `BOUCLE_`. Aucune autre variable ne doit être lue par `bin/oc`.

| Variable | Description | Défaut |
| --- | --- | --- |
| `BOUCLE_ENABLED` | Active/désactive la boucle entière. Mettre `false` pour geler le pipeline sans désactiver le projet. | **requis**, `true` recommandé |
| `BOUCLE_TOKEN` | Personal Access Token du bot (issues, MRs, comments). | masked+protected, **requis** |
| `BOUCLE_TRIGGER_TOKEN` | Token de trigger pipeline pour les jobs enfants. | masked+protected, **requis** |
| `BOUCLE_FORGE_HOST` | Hôte GitLab. | `framagit.org` |
| `BOUCLE_BUILD_CMD` | Commande de build. | `npm ci && npm run build` |
| `BOUCLE_BUILD_OUTPUT` | Dossier de sortie produit par `BUILD_CMD`. | `public` |
| `BOUCLE_DEPLOY_CMD` | Commande de déploiement wrangler, doit contenir `$$BRANCH` (échappé pour YAML CI). | template |
| `BOUCLE_DEPLOY_PROJECT` | Nom du projet Cloudflare Pages. | — |
| `BOUCLE_DEPLOY_URL_REGEX` | Regex pour extraire l'URL preview du stdout de wrangler. | `https://[a-z0-9.-]+\.pages\.dev` |
| `BOUCLE_PRODUCTION_URL` | URL de production (fallback pour e2e). | — |
| `BOUCLE_IMAGE_MAX_BYTES` | Taille max par pièce jointe. | `10485760` (10 MiB) |
| `BOUCLE_IMAGE_TOTAL_MAX_BYTES` | Taille max totale des pièces jointes d'une issue. | `52428800` (50 MiB) |
| `BOUCLE_MAX_PARALLEL_ISSUES` | Cap de concurrence (issues traités en parallèle). | `0` (illimité) |
| `BOUCLE_MAX_ITERATIONS` | Nombre max de re-runs worker (puis escalade `boucle:human`). | `3` |
| `BOUCLE_STALENESS_THRESHOLD` | Seuil en secondes avant qu'une issue soit considérée bloquée par `doctor`. | `300` |
| `BOUCLE_PREVIEW_DISABLE` | Désactive la génération de la preview PNG (`bin/render-preview`). | `false` |
| `BOUCLE_SPEC_PROFILE` | Profil du spec gate (détermine quand la validation humaine est requise). | `product` (gate pour Size M) |
| `BOUCLE_UPDATE_MODE` | Mode d'auto-update depuis upstream. | `release` |
| `BOUCLE_BOT_ID` | ID GitLab du compte bot (pour distinguer les commentaires bot des humains). | — |
| `BOUCLE_RUNNER_TAG` | Tag du runner GitLab qui exécute les jobs boucle. | — |
| `PI_AUTH` | Authentification pour l'agent pi (coding agent secondaire). | file-type → `auth.json` |

**Notes sur les variables**
- `BOUCLE_TOKEN` et `BOUCLE_TRIGGER_TOKEN` doivent **toujours** être en `masked+protected`. Aucun job boucle ne doit jamais logger leur valeur.
- `BOUCLE_DEPLOY_CMD` doit **toujours** contenir `$$BRANCH` (le double `$` est l'échappement YAML CI GitLab).
- `BOUCLE_MAX_ITERATIONS` à `0` signifie **pas de retry** (premier échec → humain).
- `BOUCLE_STALENESS_THRESHOLD` doit être **strictement supérieur** au timeout du job le plus long (~120s pour le worker).

---

## Voir aussi

- [AGENTS.md](AGENTS.md) — Guide des agents, leçons apprises, anti-patternes
- [CONTEXT.md](CONTEXT.md) — Contexte du projet, stack technique, contraintes
- [README.md](README.md) — Vue d'ensemble, démarrage, usage
- [DESIGN.md](DESIGN.md) — Charte visuelle du site consommateur
- [LOOP.md](LOOP.md) — Configuration par consommateur
- [.opencode/UPSTREAM-FIX-WORKFLOW.md](.opencode/UPSTREAM-FIX-WORKFLOW.md) — Workflow de fix upstream
