# Human-Readable Spec Validation — Design Spec

**Date:** 2026-07-31
**Status:** Amended (2026-08-03 — visual preview flipped from opt-in to systematic for UI/UX)
**Topic:** Rendre la validation des specs par l'humain lisible et non-technique, via un TL;DR en langage courant en tête du commentaire de triage, plus un aperçu visuel systématique (PNG via Chromium) pour toute issue UI/UX.

## 1. Problème

boucle est une boucle de dev autonome. L'agent de triage analyse une issue GitLab et poste un commentaire structuré (analyse, critères d'acceptation, classification, questions, disposition). Pour les issues de taille M (et en mode `strict`, aussi S), la boucle se met en pause au label `boucle:spec-review` et attend que l'auteur humain valide les critères d'acceptation avant que le worker ne commence.

Aujourd'hui :

- **Les critères d'acceptation sont trop techniques** pour un humain non-développeur. Ils décrivent le mécanisme (sélecteurs CSS, structure de données, noms de fichiers) plutôt que le résultat visible.
- **L'auteur humain doit valider un contrat qu'il peine à lire.** Le message CI actuel dit « Review the acceptance criteria above » — mais ces critères sont écrits pour le worker, pas pour l'humain.
- **Aucun visuel n'accompagne la spec.** Pour une issue UI/UX, un mockup vaut mieux qu'une description textuelle, mais l'agent n'en produit aucun.

L'auteur humain (soupsçonné non-technique sur les issues UI/UX) se retrouve à valider à l'aveugle un contrat technique, ou à demander des éclaircissements qui ralentissent la boucle.

## 2. Objectif

L'auteur humain doit pouvoir valider la spec en lisant un **TL;DR en langage courant** (2-4 phrases, résultat visible, pas de mécanisme), placé en tête du commentaire de triage. Pour les issues UI/UX, un **aperçu visuel (PNG)** est produit de façon systématique — l'agent produit un mockup pour toute issue dont le résultat visible implique le rendu frontend.

Principes directeurs :

- **Le TL;DR est obligatoire et toujours présent**, quelle que soit la taille ou le domaine de l'issue.
- **Le visuel est systématique pour les issues UI/UX.** L'agent produit un mockup pour toute issue dont le résultat visible implique le rendu frontend. Les issues non-UI/UX (backend, config, CI, tooling) n'ont que le TL;DR.
- **Chromium n'est installé que pour les issues UI/UX** — le coût (~120MB) n'est payé que quand l'agent a écrit `RENDER_REQUEST` + `preview.html`. Les issues non-UI/UX n'écrivent pas ces fichiers → zéro coût Chromium.
- **La séparation des responsabilités est stricte** : l'agent produit le contenu (TL;DR + fichiers mockup), la CI gère l'infrastructure (rendu, upload, édition du commentaire).

## 3. Décisions de design

| Aspect | Décision |
|---|---|
| Format du TL;DR | Section `## TL;DR` en tête du commentaire de triage, avant `## Analysis` |
| Langue du TL;DR | Langage courant, non-technique, 2-4 phrases, résultat visible (pas le mécanisme) |
| Présence du TL;DR | Obligatoire pour toute issue, toute taille, tout domaine |
| Format visuel | PNG uniquement (pas de SVG, jamais) |
| Déclencheur visuel | Fichier `RENDER_REQUEST` non-vide + `preview.html` présents dans `.boucle/<issue>/` |
| Rendu visuel | `@sparticuz/chromium` (~120MB) + puppeteer-core, installé à la volée dans `/tmp` |
| Moment du rendu | Inline dans le job triage existant, après le routage READY (hors de la branche `SHOULD_GATE`), fires for all READY dispositions |
| Échec du rendu | Isolé : note de fallback postée, boucle non bloquée, exit code du job inchangé |
| Idempotence | `RENDER_REQUEST` supprimé après succès → pas de re-render au retry |
| Édition du commentaire | `PUT /projects/:id/issues/:iid/notes/:note_id` (édite le commentaire de triage existant, pas un nouveau commentaire) |
| Message CI (`SPEC_MSG`) | Repointé vers le TL;DR, avec instructions de validation par réaction ou réponse |
| Critères d'acceptation | Conservés tels quels pour le worker — le TL;DR ne les remplace pas |

### Justification des choix

- **TL;DR obligatoire et en premier** : c'est ce que l'humain lit en premier. Si l'agent ne peut pas résumer l'issue en 2-4 phrases courantes, c'est probablement que l'issue est mal scoppée (NEEDS-SPLIT) ou manque d'info (NEEDS-INFO) — le TL;DR devient un signal de qualité.
- **Visuel systématique pour UI/UX** : l'utilisateur a été clair — toute issue UI/UX doit avoir un mockup. Le coût Chromium (~120MB) n'est payé que pour les issues UI/UX (l'agent écrit `RENDER_REQUEST` uniquement pour celles-ci). Les issues non-UI/UX n'écrivent pas ces fichiers → zéro coût.
- **PNG via Chromium, pas de SVG** : décision utilisateur ferme. SVG exclu dans tous les chemins. Chromium reste le seul moteur de rendu réel validé (les alternatives légères — Obscura, Lightpanda — ne produisent pas de vraies screenshots, confirmé par recherche).
- **`@sparticuz/chromium` plutôt que Chromium complet** : ~120MB vs ~400MB+, même moteur Blink, suffisant pour un mockup statique. Pas persisté — installé dans `/tmp` seulement quand le bloc rendu s'exécute.
- **Rendu inline dans le job triage, pas de job séparé** : la décision de gate (`SHOULD_GATE`) et l'IID sont déjà en scope ; un job séparé devrait passer des artifacts et ne peut pas utiliser `rules:` (l'existence du `RENDER_REQUEST` n'est connue qu'au runtime). Inline = zéro overhead sur le chemin par défaut.
- **Édition du commentaire existant, pas nouveau commentaire** : le visuel atterrit dans le commentaire de triage existant, sous le TL;DR, via `PUT notes/:note_id`. Évite de fragmenter l'info et garde le marqueur `<!-- boucle:triage -->` unique.
- **Séparation agent=contenu / CI=infrastructure** : l'agent ne fait pas d'upload, ne touche pas au commentaire image, ne sait pas si Chromium est disponible. Il écrit du texte et des fichiers. La CI lit, rend, uploade, édite. Cela garde l'agent simple et testable, et centralise la fragilité (Chromium) côté CI.

## 4. Architecture

### 4.1 Vue d'ensemble du flux

```
Issue GitLab → webhook → pipeline → job triage:
  1. bin/oc triage (agent)
     - analyse l'issue
     - poste le commentaire de triage AVEC ## TL;DR en tête
       (commentaire reste text-only à ce stade)
      - SI issue UI/UX (obligatoire):
          écrit .boucle/<issue>/preview.html
          écrit .boucle/<issue>/RENDER_REQUEST (1 ligne de justification)
  2. CI parse le commentaire (Disposition, Size) — inchangé
   3. CI: routage par disposition (case READY):
      a. if Size L → boucle:human,size:l
      b. else: spec gate logic (SHOULD_GATE)
         - if SHOULD_GATE=true: set label boucle:spec-review, assigne à l'auteur, post SPEC_MSG
         - else: set label boucle:todo, chain to worker
      c. APRES le if/else SHOULD_GATE (fires for ALL READY dispositions):
         - bloc rendu visuel:
           - si RENDER_REQUEST + preview.html présents et non-vides:
               - résout note_id du commentaire de triage
               - npm install puppeteer-core @sparticuz/chromium dans /tmp
               - rend preview.html → preview.png (1280x800, fullPage)
               - upload PNG via POST /projects/:id/uploads
                - fetch commentaire, insert "## Aperçu\n![...](url)" après TL;DR
               - PUT /projects/:id/issues/:iid/notes/:note_id
               - rm RENDER_REQUEST (idempotence)
           - sinon: skip (non-UI/UX, zéro coût Chromium)
           - sur échec: post note fallback, ne bloque pas
   4. Boucle en pause à boucle:spec-review (si SHOULD_GATE=true), attend validation humaine
```

### 4.2 Côté agent — `.opencode/agents/triage.md`

Le format de sortie gagne une nouvelle section **obligatoire** en première position :

```
<!-- boucle:triage v=1 -->
## TL;DR
<2-4 phrases en langage courant, résultat visible, pas de mécanisme>

## Analysis
<ce que l'issue demande vraiment, en vos propres mots>

## Draft acceptance criteria
- [ ] <critère vérifiable>

## Classification
Size: S | M | L

## Questions
1. <question bloquante>
...

## Disposition
READY | NEEDS-INFO | NEEDS-SPLIT
```

Règles du TL;DR (ajoutées aux "Rules" de l'agent) :

- Toujours présent, quelle que soit la taille ou le domaine.
- 2-4 phrases, langage courant, non-technique.
- Décrit le **résultat visible pour l'utilisateur**, pas le mécanisme d'implémentation.
- Si l'agent ne peut pas résumer en 4 phrases → l'issue est probablement NEEDS-SPLIT ou NEEDS-INFO.

Règles du visuel (ajoutées aux "Rules" de l'agent) :

- **Pour toute issue UI/UX, produire un mockup est obligatoire.** Une issue UI/UX est une issue dont le résultat visible implique le rendu frontend (layout, design, interaction). En cas de doute, produire le mockup.
- Pour les issues non-UI/UX (backend, config, CI, tooling), le mockup n'est pas nécessaire — le TL;DR suffit.
- Écrire deux fichiers dans `.boucle/<issue>/` :
  - `preview.html` — mockup HTML self-contained (CSS inline, pas de dépendance externe, mobile+desktop dans un seul fichier).
  - `RENDER_REQUEST` — une ligne de justification (pourquoi ce mockup aide pour cette issue).
- `RENDER_REQUEST` vide ou générique → la CI ignore la demande.
- Un seul mockup par issue, montrant le résultat proposé.
- L'agent ne rend pas, n'uploade pas, ne touche pas au commentaire image.

### 4.3 Côté CI — `.gitlab-ci.yml`

#### 4.3.1 Changement du `SPEC_MSG`

Dans la branche `SHOULD_GATE=true` (lignes ~604-618), le `SPEC_MSG` passe de :

```
Review the acceptance criteria above. If they match what you want, reply to this issue to start implementation. If not, reply with corrections.
```

à :

```
Review the **TL;DR** above. If it matches what you want: react with 👍 ✅ ☑️ ✔️ 🆗 or 👌 on this comment to approve, OR reply to this issue with any comment. If not, reply with corrections.
```

Le critères d'acceptation restent pour le worker — le TL;DR ne les remplace pas.

> **Évolution (2026-08)** : le `SPEC_MSG` est désormais **ajouté au commentaire
> de triage** (PUT sur la note existante, section `## Validation`) plutôt que
> posté comme note séparée — l'humain n'a qu'un seul message à lire/approuver.
> Fallback : note séparée si la note de triage est introuvable ou le PUT échoue.
> Garde d'idempotence : skip si `## Validation` déjà présent (re-runs triage).

#### 4.3.2 Bloc rendu visuel (inline, après le routage READY)

Inséré après le routage READY (hors de la branche `SHOULD_GATE`), fires for all READY dispositions. Structure :

```bash
# ── Aperçu visuel (systematic for UI/UX issues) ───────────────────
# Fires for ALL READY dispositions if RENDER_REQUEST + preview.html present.
# Non-UI/UX: no RENDER_REQUEST → skip (zéro coût Chromium).
PREVIEW_HTML="$CI_PROJECT_DIR/.boucle/$IID/preview.html"
RENDER_REQUEST_FILE="$CI_PROJECT_DIR/.boucle/$IID/RENDER_REQUEST"

if [ -s "$RENDER_REQUEST_FILE" ] && [ -s "$PREVIEW_HTML" ]; then
  echo "[boucle] RENDER_REQUEST found — attempting visual preview"

  # 1. Résoudre le note_id du commentaire de triage (fetch séparé pour
  #    ne pas perturber le parse existant du commentaire).
  TRIAGE_NOTE_ID=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$CI_PROJECT_ID/issues/$IID/notes" 2>/dev/null \
    | jq -r '[.[] | select(.body | contains("<!-- boucle:triage") and contains("## Disposition"))]
        | sort_by(.created_at) | last | .id' 2>/dev/null || echo "")

  if [ -z "$TRIAGE_NOTE_ID" ]; then
    echo "[boucle] WARN: triage comment not found — cannot embed preview"
  else
    # 2. Installer Chromium + puppeteer-core (uniquement maintenant, dans /tmp).
    if npm install --prefix /tmp puppeteer-core @sparticuz/chromium >/dev/null 2>&1; then
      # 3. Rendre preview.html → preview.png (1280x800, fullPage).
      #    NODE_PATH=/tmp/node_modules pour que le script (dans bin/) résolve
      #    les modules installés dans /tmp.
      PREVIEW_PNG="$CI_PROJECT_DIR/.boucle/$IID/preview.png"
      if NODE_PATH=/tmp/node_modules node "$CI_PROJECT_DIR/bin/render-preview.cjs" "$PREVIEW_HTML" "$PREVIEW_PNG" 2>/dev/null; then
        # 4. Uploader le PNG via l'API uploads GitLab.
        UPLOAD_RESP=$(curl -s --request POST \
          --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
          --form "file=@$PREVIEW_PNG" \
          "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/uploads" 2>/dev/null)
        IMG_URL=$(echo "$UPLOAD_RESP" | jq -r '.markdown // empty' 2>/dev/null)

        if [ -n "$IMG_URL" ]; then
          # 5. Fetch du commentaire existant, insert de la section Aperçu
          #    juste après le TL;DR (première chose que l'humain voit), PUT.
          EXISTING_BODY=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
            "/projects/$CI_PROJECT_ID/issues/$IID/notes/$TRIAGE_NOTE_ID" 2>/dev/null \
            | jq -r '.body' 2>/dev/null)
          NEW_BODY=$(printf '%s\n\n## Aperçu\n%s\n' "$EXISTING_BODY" "$IMG_URL")
          glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT \
            "/projects/$CI_PROJECT_ID/issues/$IID/notes/$TRIAGE_NOTE_ID" \
            -f body="$NEW_BODY" >/dev/null 2>&1
          # 6. Idempotence: supprimer RENDER_REQUEST pour ne pas re-render au retry.
          rm -f "$RENDER_REQUEST_FILE"
          echo "[boucle] Visual preview embedded in triage comment #$TRIAGE_NOTE_ID"
        else
          echo "[boucle] WARN: PNG upload failed — posting fallback note"
          glab api --hostname "$BOUCLE_FORGE_HOST" -X POST \
            "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
            -f body="Aperçu indisponible (échec upload) — validez sur le TL;DR." >/dev/null 2>&1
        fi
      else
        echo "[boucle] WARN: Chromium render failed — posting fallback note"
        glab api --hostname "$BOUCLE_FORGE_HOST" -X POST \
          "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
          -f body="Aperçu indisponible (échec rendu) — validez sur le TL;DR." >/dev/null 2>&1
      fi
    else
      echo "[boucle] WARN: Chromium install failed — posting fallback note"
      glab api --hostname "$BOUCLE_FORGE_HOST" -X POST \
        "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
        -f body="Aperçu indisponible (Chromium indisponible) — validez sur le TL;DR." >/dev/null 2>&1
    fi
  fi
fi
```

#### 4.3.3 Script de rendu — `bin/render-preview.cjs`

Nouveau fichier, appelé par le bloc CI. Self-contained, pas de dépendance projet.

```js
#!/usr/bin/env node
// bin/render-preview.cjs — rend preview.html → preview.png via @sparticuz/chromium
// Usage: node bin/render-preview.cjs <input.html> <output.png>
const puppeteer = require('puppeteer-core');
const chromium = require('@sparticuz/chromium');
const [,, input, output] = process.argv;

(async () => {
  const browser = await puppeteer.launch({
    args: chromium.args,
    executablePath: await chromium.executablePath(),
    headless: chromium.headless,
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 800 });
  await page.goto('file://' + require('path').resolve(input), { waitUntil: 'networkidle0' });
  await page.screenshot({ path: output, fullPage: true });
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
```

### 4.4 Chemin par défaut (non-UI/UX)

Aucun changement. L'agent poste le commentaire avec `## TL;DR` en tête. La CI parse, applique le gate, poste le `SPEC_MSG` repointé vers le TL;DR. Le bloc rendu est entièrement skippé (pas de `RENDER_REQUEST` → la condition `[ -s "$RENDER_REQUEST_FILE" ]` échoue immédiatement). Zéro coût Chromium, zéro install, zéro overhead.

## 5. Gestion des erreurs

| Cas | Comportement |
|---|---|
| `RENDER_REQUEST` absent ou vide | Bloc rendu skippé (défaut) |
| `preview.html` absent ou vide | Bloc rendu skippé |
| Commentaire de triage introuvable (note_id vide) | Log WARN, bloc skippé, pas de fallback note (rien à éditer) |
| `npm install` Chromium échoue | Note fallback postée, boucle continue |
| Rendu Chromium échoue | Note fallback postée, boucle continue |
| Upload PNG échoue | Note fallback postée, boucle continue |
| `PUT notes/:note_id` échoue | Log WARN, `RENDER_REQUEST` non supprimé (retry possible), boucle continue |
| Retry du job triage après succès rendu | `RENDER_REQUEST` déjà supprimé → bloc skippé (idempotence) |

**Principe** : aucune erreur de rendu ne bloque la boucle. L'humain peut toujours valider sur le TL;DR seul.

## 6. Test

Vérification minimale, ciblée :

- **TL;DR présent** : toute issue triée doit avoir `## TL;DR` en tête du commentaire, avant `## Analysis`. Vérifiable par grep sur le commentaire posté.
- **SPEC_MSG repointé** : le message posté par la CI mentionne « TL;DR » et les réactions d'approbation.
- **Chemin par défaut (non-UI/UX)** : une issue non-UI/UX ne déclenche ni `RENDER_REQUEST` ni install Chromium (vérifier l'absence de log `[boucle] RENDER_REQUEST found`).
- **Chemin visuel (UI/UX, Size S non-gated)** : une issue UI/UX Size S avec `RENDER_REQUEST` + `preview.html` produit un commentaire édité avec `## Aperçu` contenant une image markdown — même sans spec gate (SHOULD_GATE=false).
- **Chemin visuel (UI/UX, Size M gated)** : une issue UI/UX Size M avec `RENDER_REQUEST` + `preview.html` produit un commentaire édité avec `## Aperçu` après le `SPEC_MSG` de validation.
- **Idempotence** : un retry du job triage après succès rendu ne re-render pas (RENDER_REQUEST supprimé).
- **Échec isolé** : si Chromium indisponible, note fallback postée, exit code du job triage inchangé.

## 7. Hors scope

- **Génération de visuels pour les issues non-UI/UX** : le TL;DR suffit.
- **Plusieurs mockups par issue** : un seul, montrant le résultat proposé.
- **Visuels animés/interactifs** : PNG statique uniquement.
- **SVG** : exclu par décision utilisateur, dans tous les chemins.
- **Alternatives légères à Chromium** (Obscura, Lightpanda) : recherchées, non viables pour le rendu pixel.
- **Modification des critères d'acceptation** : ils restent tels quels pour le worker. Le TL;DR est une couche supplémentaire pour l'humain, pas un remplacement.
- **Nouveau job/stage CI** : le rendu est inline dans le job triage existant.