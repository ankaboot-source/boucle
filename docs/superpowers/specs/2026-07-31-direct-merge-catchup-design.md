# Direct Merge Catchup — Design Spec

**Date:** 2026-07-31
**Status:** Approved
**Topic:** Rattrapage automatique quand un humain fusionne une MR boucle directement sans passer par le circuit d'approbation.

## 1. Problème

Boucle suppose que les fusions passent par le job `merger`, qui est le seul chemin qui (a) met à jour le label de l'issue (`boucle:merging → boucle:done` via le job `e2e`) et (b) ferme l'issue + déclenche la cascade parent (`maybe_close_parent`).

Le handler `dispatch` (`.gitlab-ci.yml:232-237`) **ignore explicitement** l'événement webhook `action=merge` en partant du principe que `merger` est l'unique exécuteur de la fusion.

Quand un humain fusionne directement une MR via l'UI GitLab (sans passer par le bouton Approve → job `merger`):

1. Le webhook `merge_request` avec `action=merge` arrive dans `dispatch` → **skip**.
2. Le push sur `master` déclenche `deploy` → smoke e2e **sans `BOUCLE_ISSUE`**.
3. L'issue reste bloquée à son dernier état actif (typiquement `boucle:approval`), reste ouverte, et `maybe_close_parent` ne se déclenche jamais.
4. Le `doctor` (job programmé toutes les 10 min) n'a pas de recovery pour ce cas.

Résultat: l'issue reste coincée pour toujours, et les parents `boucle:split` ne se ferment jamais en cascade.

## 2. Objectif

Quand un humain fusionne directement une MR `boucle/<iid>`, boucle doit rattraper la situation en fermant l'issue et en déclenchant la cascade parent, sans lancer l'agent e2e (confiance au jugement humain).

## 3. Décisions de design

| Aspect | Décision |
|---|---|
| Portée du rattrapage | Fermer l'issue + cascade parent (pas de e2e) |
| Mécanisme de détection | Événementiel dans `dispatch` (immédiat, pas de polling) |
| Périmètre des MRs | Uniquement les MRs dont la branche source est `boucle/<iid>` |
| Issue à `boucle:approval` | → `boucle:done` + close + cascade + commentaire d'audit |
| Issue à état antérieur (« trop tôt ») | → `boucle:human` + close + cascade + commentaire d'audit |
| Traçabilité | Commentaire d'audit sur l'issue (avec tag caché pour idempotence) |
| Approche d'implémentation | Nouveau job dédié `catchup` déclenché par `dispatch` via trigger token |

### Justification des choix

- **Pas de e2e**: l'humain a pris la responsabilité de la fusion; on fait confiance à son jugement. Lancer e2e sur une MR déjà fusionnée surchargerait la sémantique du loop.
- **Événementiel uniquement (pas de doctor)**: détection immédiate, zéro délai. Les issues déjà bloquées avant le déploiement de cette feature nécessiteront un nettoyage manuel (hors scope).
- **Seulement `boucle/<iid>`**: cohérent avec le contrat existant — `dispatch` rejette déjà les branches non-`boucle/` (ligne 160). On n'interfère pas avec les MRs humaines normales.
- **`boucle:human` pour les fusions anticipées**: signal honnête que le bot n'a pas validé la complétion, tout en rattrapant la situation (issue fermée, cascade déclenchée).
- **Job dédié `catchup`**: suit le pattern existant de boucle (dispatch route → job exécute). Dispatch reste un routeur pur. Le coût d'un job/stage supplémentaire est négligeable.

## 4. Architecture

### 4.1 Pipeline flow

```
Webhook merge_request action=merge
        │
        ▼
   dispatch (case "merge")
        │  valide branche ^boucle/<iid>$
        │  extrait IID
        │  déclenche catchup via trigger token
        ▼
   catchup job (stage: merge)
        │  récupère l'état de l'issue
        │  branche selon le label boucle:* actuel
        │  ├─ boucle:approval → boucle:done + audit
        │  └─ autre état actif → boucle:human + audit
        │  close_issue
        │  maybe_close_parent (cascade split)
        ▼
   (terminé)
```

### 4.2 Changements dans `dispatch` (`.gitlab-ci.yml:232-237`)

Aujourd'hui:

```bash
open|merge)
  echo "… — handled by worker/merger, skipping"
  exit 0
  ;;
```

Après:

```bash
merge)
  # Rattrapage des fusions directes (humain court-circuite le circuit d'approbation)
  if echo "$MR_SRC_BRANCH" | grep -qE '^boucle/[0-9]+$'; then
    BOUCLE_ISSUE=$(echo "$MR_SRC_BRANCH" | sed -E 's/^boucle\///')
    echo "Direct merge detected on boucle/$BOUCLE_ISSUE — triggering catchup"
    curl -fsSL -X POST ".../trigger/pipeline?token=$BOUCLE_TRIGGER_TOKEN&ref=master" \
      --form "variables[BOUCLE_ROLE]=catchup" \
      --form "variables[BOUCLE_ISSUE]=$BOUCLE_ISSUE"
  else
    echo "Non-boucle branch merged — skipping"
  fi
  exit 0
  ;;
open)
  echo "open — handled by worker, skipping"
  exit 0
  ;;
```

Note: `open` reste skip (inchangé). Seul `merge` est séparé du bloc `open|merge`.

### 4.3 Nouveau job `catchup`

Stage `merge` (même stage que `merger`), `needs: ["dispatch"]`, déclenché uniquement via trigger token avec `BOUCLE_ROLE=catchup`.

```yaml
catchup:
  stage: merge
  needs: ["dispatch"]
  rules:
    - if: '$BOUCLE_TRIGGER_TOKEN && $BOUCLE_ROLE == "catchup"'
      when: on_success
    - when: never
  script:
    - # before_script standard (glab install, auth)
    - # Helpers: set_boucle_label, close_issue, maybe_close_parent (copies locales)
    - # Récupère l'issue
    - # Détermine le label boucle:* actuel
    - # Branche: boucle:approval → done ; autre actif → human ; terminal → skip
    - # Poste le commentaire d'audit
    - # close_issue
    - # maybe_close_parent
```

### 4.4 Helpers (copies locales dans `catchup`)

Cohérent avec le pattern existant: chaque job (merger, e2e, doctor) duplique `set_boucle_label`, `close_issue`, `maybe_close_parent` dans son script block. Pas de refactoring cross-job (hors scope, risqué dans un fichier de ~1936 lignes de bash inline).

- `set_boucle_label <iid> <detail>`: strip tous les `boucle:*` (hors `boucle::status::*`), pose `<detail>` + le gross-axis label approprié. Référence: `.gitlab-ci.yml:294-310`.
- `close_issue <iid>`: `glab api --method PUT projects/:id/issues/<iid> --raw-field state_event=close`. Référence: `.gitlab-ci.yml:1447-1451`.
- `maybe_close_parent <iid>`: cascade close du parent `boucle:split` si tous les sub-issues sont fermés. Référence: `.gitlab-ci.yml:1467-1562`.

### 4.5 Commentaire d'audit

Posté via `glab api --method POST projects/:id/issues/<iid>/notes --raw-field body="..."`.

Format:

```
<!-- boucle:catchup v=1 mr=!{MR_IID} iid={ISSUE_IID} state={ORIGINAL_STATE} -->
🤖 Rattrapage automatique — la MR !{MR_IID} a été fusionnée directement sans passer par le circuit d'approbation.

État de l'issue au moment de la fusion : `boucle:{ORIGINAL_STATE}`.
Issue marquée `boucle:{DONE_OR_HUMAN}` et fermée.
```

Le tag caché `<!-- boucle:catchup ... -->` sert à l'audit et à l'idempotence (vérifier qu'un commentaire `boucle:catchup` n'existe pas déjà avant de poster).

### 4.6 Logique de branchement (pseudocode)

```bash
ISSUE_LABELS=$(glab api projects/:id/issues/$BOUCLE_ISSUE | jq -r '.labels[]')
CURRENT_BOUCLE=$(echo "$ISSUE_LABELS" | grep -E '^boucle:(triage|needs-info|spec-review|todo|working|review|approval|merging|done|human|split|blocked)$' | head -1)

case "$CURRENT_BOUCLE" in
  approval)
    set_boucle_label "$BOUCLE_ISSUE" "done"
    TARGET="done"
    ;;
  triage|needs-info|spec-review|todo|working|review|merging)
    set_boucle_label "$BOUCLE_ISSUE" "human"
    TARGET="human"
    ;;
  done|human|split|blocked)
    # État terminal — issue déjà traitée, ne rien faire
    echo "Issue already at terminal state $CURRENT_BOUCLE — skipping"
    exit 0
    ;;
  "")
    # Pas de label boucle — hors loop
    echo "Issue has no boucle label — skipping"
    exit 0
    ;;
esac

# Idempotence: vérifier qu'un commentaire boucle:catchup n'existe pas déjà
# (optionnel — la vérification de l'état terminal ci-dessus couvre le cas rejoué)

post_audit_comment "$BOUCLE_ISSUE" "$MR_IID" "$CURRENT_BOUCLE" "$TARGET"
close_issue "$BOUCLE_ISSUE"
maybe_close_parent "$BOUCLE_ISSUE"
```

## 5. Ce qui ne change pas

- `merger` job: inchangé (happy path approval → merge → e2e).
- `e2e` job: inchangé.
- `doctor` job: inchangé (pas de recovery ajouté — choix événementiel uniquement).
- `deploy` job: inchangé (la fusion directe déclenche toujours deploy → smoke e2e sans `BOUCLE_ISSUE`, c'est orthogonal au rattrapage).
- Branch protection: inchangé (Maintainer-only merge, `access_level=40`).
- `bin/setup`: inchangé (pas de nouveau label à créer — `boucle:done` et `boucle:human` existent déjà).
- `bin/doctor`: inchangé.

## 6. Edge cases

| Cas | Comportement |
|---|---|
| MR non-boucle fusionnée | Skip (validation branche `^boucle/[0-9]+$`) |
| Issue déjà fermée | `close_issue` est un no-op GitLab; le label est quand même mis à jour si l'état était actif |
| Événement `merge` rejoué (GitLab renotifie) | Idempotence: si l'issue est déjà à un état terminal (`done`/`human`), skip |
| Issue sans label boucle | Skip (hors loop) |
| Issue à état terminal au moment de la fusion | Skip (déjà traitée) |
| Issue à `boucle:merging` (merger job en cours) | → `boucle:human` (considéré comme fusion anticipée — le merger job n'a pas terminé) |

## 7. Tests

Pas de framework de test existant pour le bash inline dans `.gitlab-ci.yml`. Vérification via:

- **Smoke test manuel** (obligatoire avant merge):
  1. Créer une issue boucle, la pousser jusqu'à `boucle:approval` via le loop normal.
  2. Créer une MR `boucle/<iid>`, la fusionner directement via l'UI GitLab.
  3. Vérifier: issue passe à `boucle:done`, se ferme, commentaire d'audit posté, cascade parent déclenchée si applicable.
  4. Répéter avec une issue à `boucle:working` → vérifier `boucle:human` + close + audit.
- **`bin/doctor`** (existant): pas de modification.

## 8. Out of scope

- Recovery des issues déjà bloquées avant le déploiement de cette feature (nettoyage manuel).
- Ajout d'un recovery dans `doctor` (choix événementiel uniquement).
- Lancement de l'agent e2e sur les fusions directes.
- Support des MRs non-boucle référençant une issue via `Closes #N`.
- Refactoring des helpers dupliqués cross-job.