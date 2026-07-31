# Boucle Self-Update — Design Spec

**Date:** 2026-07-31
**Status:** Approved
**Topic:** Mise à jour automatique de boucle au démarrage de chaque pipeline CI, avec deux modes : `release` (dernier tag) et `dev` (dernier commit sur main).

## 1. Problème

boucle est un template (pas un package) distribué par copie manuelle de fichiers (`cp -r bin/ .opencode/ .gitlab-ci.yml LOOP.md`) depuis le repo upstream (`github.com/ankaboot-source/boucle`) vers un repo consumer. Actuellement :

- **Aucun mécanisme de mise à jour** — l'opérateur doit re-copier manuellement les 4 chemins à chaque changement upstream.
- **Aucun mécanisme de release** — push direct sur main, pas de tags, pas de version.
- **Aucun suivi de version** — impossible de savoir "quelle version de boucle j'ai" dans un consumer.
- **Aucune infrastructure de self-update** — pas de fichier de version, pas de manifest, pas de job de sync.

L'opérateur est fatigué de devoir manuellement demander la mise à jour des consumers à chaque changement upstream.

## 2. Objectif

boucle doit se mettre à jour automatiquement au démarrage de chaque pipeline CI, sans intervention humaine. Deux modes de fonctionnement :

- **`release`** (défaut) : fetch le dernier tag Git sur le repo upstream.
- **`dev`** : fetch le dernier commit sur `main` du repo upstream (pour le développement actif sans release).

Le mode est contrôlé par la variable CI/CD `BOUCLE_UPDATE_MODE` dans le projet GitLab du consumer. Si absente → `release` par défaut.

## 3. Décisions de design

| Aspect | Décision |
|---|---|
| Moment du self-update | Première étape du job `dispatch` dans `.gitlab-ci.yml`, avant le parsing du webhook |
| Configuration du mode | Variable CI/CD GitLab `BOUCLE_UPDATE_MODE` (`release` par défaut si absente) |
| Application des mises à jour | Auto-commit sur main par le bot (pas de MR, pas de revue humaine) |
| Détection des mises à jour | Fichier `.boucle-version` à la racine (commité), comparé avec l'upstream |
| Mécanisme de fetch | Tarball download (Approche A) — pas de clone, pas de rebase, pas de remote ajouté |
| Fichiers syncés | `bin/`, `.opencode/`, `.gitlab-ci.yml` |
| Fichiers non syncés | `LOOP.md` (config per-consumer), `.boucle-version` (géré par le script), tout le reste |
| Comportement en cas d'erreur | Fail-open : warning + exit 0, le pipeline continue avec la version actuelle |
| Processus de release | Hors scope — le tagging upstream est manuel. Le mode `dev` fonctionne immédiatement. |

### Justification des choix

- **Auto-commit sur main** : aligné avec le choix utilisateur. Le bot a déjà un token ; on lui donne le scope `write_repository`. Zéro friction, pas de clic humain requis.
- **Tarball download vs git fetch/merge** : une seule requête HTTP, pas de pollution git (pas de remote ajouté au consumer), pas de merge conflicts, déterministe. C'est essentiellement automatiser les 4 `cp -r` existants.
- **`.boucle-version` à la racine** : `.boucle/` est gitignored (dossier de state transitoire par issue, pas persistant entre pipelines CI). Un fichier à la racine est commité, visible, et simple à parser en bash.
- **Fail-open** : un problème de mise à jour ne doit jamais bloquer la boucle. Le pipeline continue avec la version actuelle ; la mise à jour sera retentée au prochain pipeline.
- **`release` par défaut** : c'est le mode sûr. `dev` est un opt-in explicite pour le développement actif.
- **Release hors scope** : le mode `dev` fonctionne immédiatement (fetch main). Le mode `release` fonctionnera quand l'opérateur commencera à tagger manuellement. Pas de processus de release automatisé dans ce design.

## 4. Architecture

### 4.1 Vue d'ensemble du flux

```
Webhook GitLab → pipeline → job dispatch:
  1. bin/update (self-update — NOUVEAU)
     - lit BOUCLE_UPDATE_MODE (défaut: release)
     - lit .boucle-version
     - compare avec upstream (API GitHub)
     - si différent: télécharge tarball, remplace bin/ .opencode/ .gitlab-ci.yml,
       commit sur main, met à jour .boucle-version
     - fail-open si erreur
  2. bin/oc dispatch (existant, inchangé)
     - parse webhook, chaîne triage/worker/reviewer
```

### 4.2 Nouveau script `bin/update`

Script bash (même style que `bin/setup`, `bin/doctor`, `bin/oc`).

**Flux détaillé** :

```
1. Lire BOUCLE_UPDATE_MODE (défaut: release)
2. Lire .boucle-version (contient: hash|tag actuel)
3. Selon mode:
   - release: GET https://api.github.com/repos/ankaboot-source/boucle/tags
     → extraire le nom du dernier tag (premier de la liste, trié par date)
   - dev: GET https://api.github.com/repos/ankaboot-source/boucle/commits/main
     → extraire le hash SHA du HEAD
4. Comparer avec .boucle-version
   - Si identique → exit 0 (rien à faire, pipeline continue)
   - Si différent → étape 5
5. Télécharger tarball GitHub:
   - release: https://codeload.github.com/ankaboot-source/boucle/tarball/refs/tags/<tag>
   - dev: https://codeload.github.com/ankaboot-source/boucle/tarball/refs/heads/main
6. Vérifier l'intégrité du tarball (extraction valide : `tar tzf` réussit). L'intégrité transport est assurée par HTTPS.
7. Extraire uniquement: bin/, .opencode/, .gitlab-ci.yml
   (LOOP.md n'est PAS syncé — config per-consumer)
8. Remplacer les fichiers dans le working tree
9. Mettre à jour .boucle-version avec le nouveau hash|tag
10. git add bin/ .opencode/ .gitlab-ci.yml .boucle-version
11. git commit -m "chore(boucle): auto-update to <hash|tag>"
12. git push (via le bot token)
13. exit 0
```

**Gestion d'erreur (fail-open)** :
- API GitHub injoignable → warning + exit 0
- Tarball corrompu (hash mismatch) → warning + exit 0
- Push échoué (permissions, réseau) → warning + exit 0
- Dans tous les cas, le pipeline continue avec la version actuelle

**Authentification GitHub** :
- Le repo boucle est public → pas de token requis pour l'API et le tarball
- Rate limit anonyme : 60 req/h. À 1 check max par pipeline, c'est largement suffisant
- Optionnel : `GITHUB_TOKEN` CI var pour augmenter la limite (pas requis pour le MVP)

### 4.3 Fichier `.boucle-version`

Fichier texte simple à la racine du repo consumer, commité. Contient une seule ligne :

```
<hash-ou-tag>
```

- Mode `release` : nom du tag (ex: `v0.1.0`)
- Mode `dev` : hash SHA du commit (ex: `a1b2c3d4e5f6...`)

**Format** : juste la valeur, pas de clé, pas de JSON. `cat .boucle-version` donne directement la version. Simple à parser en bash (`read -r CURRENT < .boucle-version`).

**Première exécution** (fichier absent) :
- Le script crée `.boucle-version` avec la version actuelle détectée (hash du HEAD de main en dev, ou dernier tag en release)
- Commit + push
- exit 0 (le pipeline continue, pas de mise à jour appliquée cette fois — on vient juste d'enregistrer la version de référence)

**Migration des consumers existants** : aucune action manuelle. La première fois que `bin/update` tourne sur un consumer déjà installé, il crée `.boucle-version` avec la version actuelle. Le pipeline suivant fonctionnera normalement.

### 4.4 Intégration dans `.gitlab-ci.yml`

Le job `dispatch` actuel (lignes 120-437) parse le webhook et chaîne vers triage/worker/reviewer. On ajoute `bin/update` comme **toute première étape** du job `dispatch`, avant le parsing du webhook.

```yaml
dispatch:
  stage: dispatch
  script:
    - bin/update          # ← NOUVEAU : self-update avant tout
    - bin/oc dispatch      # ← existant : parse webhook, chaîne les rôles
```

**Pourquoi dans `dispatch` et pas un job séparé ?**
- `dispatch` est le point d'entrée unique de tous les pipelines (webhook-triggered)
- Un job séparé ajouterait de la complexité (stages, dependencies) pour un gain nul
- Si `bin/update` commit quelque chose, le reste du pipeline tourne avec les fichiers à jour dans le même checkout

### 4.5 Impact sur `bin/setup`

Modifications à apporter à `bin/setup` :

1. **Créer `.boucle-version` initial** lors de l'installation — avec le hash/tag actuel d'upstream (même logique que la première exécution de `bin/update`)
2. **Configurer la variable CI/CD `BOUCLE_UPDATE_MODE`** — vide par défaut (= release). L'opérateur peut la définir à `dev` dans l'UI GitLab s'il le souhaite.
3. **S'assurer que le bot token a le scope `write_repository`** — pour permettre les auto-commits sur main
4. **Autoriser le bot à push sur main** dans la branch protection (si main est protégé)

### 4.6 Impact sur `bin/doctor`

Ajouts à apporter à `bin/doctor` :

1. **Vérifier que `.boucle-version` existe** à la racine du repo
2. **Vérifier que `bin/update` est présent et exécutable**
3. **Vérifier que le bot a le droit de push sur main** (test de permission — tentative de push d'un commit vide ou vérification via l'API GitLab)
4. **Vérifier que `BOUCLE_UPDATE_MODE` est défini ou absent** (absent = release par défaut, c'est valide)

### 4.7 Impact sur `bin/oc`

**Aucune modification.** Le self-update est isolé dans `bin/update`. `bin/oc` continue de fonctionner inchangé.

## 5. Sécurité et edge cases

### 5.1 Push access du bot

Le bot a déjà un token (créé par `bin/setup`). Pour commit sur main, ce token doit avoir le scope `write_repository`. `bin/setup` doit s'assurer de ça, et `bin/doctor` doit le vérifier.

### 5.2 Branche protégée

Si main est protégé (recommandé), le bot doit être autorisé à push directement. Vu le choix "auto-commit sur main", on autorise le bot à push. `bin/setup` configure ça dans la branch protection GitLab.

### 5.3 Race condition

Si deux pipelines tournent en même temps et trouvent une mise à jour, les deux vont essayer de commit. Git gère ça : le second push sera rejeté. Comme `bin/update` est fail-open, il log un warning et continue. Le pipeline suivant récupérera la mise à jour.

### 5.4 Échec du push

Si le push échoue (permissions, réseau, conflit), fail-open : warning + exit 0. Le pipeline continue avec la version actuelle. La mise à jour sera retentée au prochain pipeline.

### 5.5 Tarball corrompu

Vérifier que le tarball téléchargé est une archive valide (`tar tzf` réussit). L'intégrité du transport est assurée par HTTPS. Si l'extraction échoue, abort + fail-open (warning + exit 0).

### 5.6 Modification locale des fichiers boucle

Si un consumer a modifié `bin/oc` ou `.opencode/agents/worker.md`, le self-update **écrasera** ces modifications. C'est intentionnel — upstream est autoritaire. Le `UPSTREAM-FIX-WORKFLOW.md` le dit déjà : "fix upstream first". Si un consumer veut personnaliser, il doit fork.

### 5.7 Mode `release` sans tags

Si `BOUCLE_UPDATE_MODE=release` (ou absent) mais qu'aucun tag n'existe sur le repo upstream, l'API renvoie une liste vide. Le script log un warning ("no releases found, staying on current version") et exit 0. Le pipeline continue. L'opérateur doit soit créer des tags, soit passer en mode `dev`.

## 6. Récapitulatif

### Nouveaux fichiers
- `bin/update` — script bash de self-update
- `.boucle-version` — fichier de version à la racine (commité)

### Fichiers modifiés
- `.gitlab-ci.yml` — ajouter `bin/update` en début du job `dispatch`
- `bin/setup` — créer `.boucle-version` initial, configurer `BOUCLE_UPDATE_MODE`, permissions bot
- `bin/doctor` — vérifier `.boucle-version`, `bin/update`, permissions push bot
- `LOOP-README.md` — documenter le self-update et `BOUCLE_UPDATE_MODE`

### Fichiers non touchés
- `bin/oc`, `bin/fetch-issue-images` — inchangés
- `LOOP.md` — config per-consumer, jamais syncé
- `.opencode/` — syncé mais pas modifié par le design (juste remplacé par upstream)

### Variables CI/CD
- `BOUCLE_UPDATE_MODE` (optionnel) : `release` (défaut) | `dev`

### Fichiers syncés par le self-update
| Chemin | Syncé | Raison |
|---|---|---|
| `bin/` | Oui | Code boucle |
| `.opencode/` | Oui | Agents + skills boucle |
| `.gitlab-ci.yml` | Oui | Pipeline boucle |
| `LOOP.md` | Non | Config per-consumer |
| `.boucle-version` | Non | Géré par `bin/update` |
| `src/`, `public/`, `static/`, etc. | Non | Appartient au consumer |