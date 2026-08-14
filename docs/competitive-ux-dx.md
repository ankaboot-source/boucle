# Analyse UX/DX — boucle face à ses compétiteurs

> Analyse comparative de l'expérience utilisateur (Product Builder) et de
> l'expérience développeur (contributeur/intégrateur), avec un plan
> d'amélioration priorisé. Établie le 2026-08-12 sur la base du code
> (`.gitlab-ci.yml`, `lib/`, `bin/`, docs charte) et d'un relevé de l'état
> des produits concurrents.

## 1. Positionnement

boucle n'a pas un seul marché concurrent, il en a trois — et il est le seul
à se tenir à leur intersection.

| Axe | Concurrents | Ce qu'ils font | Ce que boucle fait différemment |
| --- | --- | --- | --- |
| **Agents async dans la forge** | GitHub Copilot coding agent, Google Jules, OpenAI Codex cloud, Devin, Cursor background agents | Ticket/prompt → branche → PR. La livraison s'arrête à la PR. | Va jusqu'à **merge + deploy + vérification e2e en production** |
| **Agents auto-hébergeables** | OpenHands (MIT, ~70k ★), Aider, SWE-agent | Sandbox Docker, résolveur d'issue, BYOK | Pas de serveur ni de démon : **le CI de la forge est le runtime** |
| **Builders no-code** | Lovable, Bolt, Replit Agent, v0 | Chat → app déployée, pour non-développeurs | Même persona cible, mais **le code, les données et les tokens restent chez l'utilisateur** (AGPL, poids ouverts) |

La thèse de `CONTEXT.md` §7 — *« boucle vit dans la forge ; jamais de nouveau
frontend, de serveur, ni de machine à garder allumée »* — est une véritable
différenciation, pas un compromis. Elle doit être défendue, pas diluée.

## 2. Comparatif UX (persona : Product Builder)

| Critère | boucle | Copilot coding agent | Jules / Codex cloud | Devin | Lovable / Replit |
| --- | --- | --- | --- | --- | --- |
| Temps avant la 1ʳᵉ tâche | **~30–60 min** (runner, bot PAT, clé masquée, token CF) | ~1 min (assigner une issue) | ~2 min (connecter le repo) | ~5 min (Slack/Linear) | ~0 (prompt) |
| Point d'entrée | Issue de la forge | Issue GitHub | Web / CLI / app | Slack, Linear, Jira | Chat |
| Validation du **spec avant code** | ✅ gate explicite (👍 ou commentaire) | ❌ | Plan affiché, non bloquant | Interactive Planning + score de confiance | ❌ |
| Vérification du **comportement** | ✅ preview URL + captures + **e2e post-merge ancré sur le SHA** | Checks CI + review agentique | Tests dans la VM | Tests + navigateur | Preview live |
| Livre en **production** | ✅ merge + deploy + vérif | ❌ s'arrête à la PR | ❌ | ❌ | ✅ (plateforme propriétaire) |
| Reprise de contrôle du **timing** | ✅ async par conception + DND | Async | Async « fire-and-forget » | Async | Synchrone (chat) |
| Visibilité du coût | ❌ *(roadmap)* | Inclus au siège | Inclus au plan | ACU facturés, visibles | Crédits visibles |
| Progression en cours de route | ❌ notes ponctuelles | Timeline de session | Plan + journal | Plan live + score | Streaming live |
| Souveraineté (code/données/clés) | ✅ **totale** | ❌ | ❌ | ❌ (VPC en Enterprise) | ❌ |

### Ce que boucle fait mieux que tout le monde

1. **Le gate de spec.** Devin propose un plan, Jules affiche le sien — boucle
   est le seul à *bloquer* sur une validation humaine explicite en amont du
   code, réversible par simple commentaire (`.gitlab-ci.yml:1425`). C'est la
   réponse au mode d'échec le plus coûteux : trois itérations d'agent sur la
   mauvaise spec.
2. **La vérification du comportement, pas du diff.** Le verdict ancré sur le
   SHA (`CONTEXT.md` §7) plus le gate e2e *après* le merge est un niveau
   d'assurance qu'aucun agent de forge ne fournit. Les concurrents s'arrêtent
   à « la CI est verte sur la PR ».
3. **Le tableau de bord dans la forge.** `➰ boucle — status board`, édité en
   place, quatre sections dont « Waiting on you » (`LOOP.md` §Status board).
   Répond à la seule question qui compte en parallèle sur 5 issues, sans
   introduire d'interface.
4. **`bin/doctor --audit` avec score de lisibilité.** Un audit de
   configuration read-only, noté sur 100, pondéré (blocker −40 / degraded −15
   / advisory −3), exécuté en fin de `bin/setup`. Aucun concurrent ne dit à
   l'utilisateur *avant* la première tâche ce qui va casser.
5. **Les diagnostics d'escalade structurés.** Classification de la panne
   (provider/quota, build-fail, no-changes, rebase-conflict, not-mergeable)
   avec preuve et action recommandée, adossée à `health.jsonl`
   (`LOOP.md` §Loop-health). Bien au-dessus du « the agent failed » habituel.

### Les frictions UX réelles

**F1 — Le temps avant la première valeur reste le principal frein à l'adoption.**
Le parcours GitLab exige d'enregistrer un runner auto-hébergé portant le tag
`boucle` (`README.md:129-132`), d'ajouter manuellement une variable masquée,
de provisionner un compte bot et un PAT, et un token Cloudflare. Le parcours
GitHub est nettement plus léger (`ubuntu-latest`, pas de runner à gérer) mais
`CONTEXT.md` §8 le déclare lui-même « moins éprouvé ».

Ce coût est **cohérent avec le persona** (voir §6 : des utilisateurs ayant des
bases techniques) — ce n'est pas une contradiction, c'est un frein
d'installation ordinaire, et il se lève à peu de frais (P0.2). En revanche,
il concentre toute la charge technique sur **une seule personne de l'équipe**,
ce qui rend d'autant plus critique la qualité de l'interface vue par les
autres (F3, F7).

**F2 — Rien ne prouve que l'installation fonctionne.** `bin/setup` se termine
sur « Create your first issue » (`bin/setup:1231`). La première issue réelle
de l'utilisateur devient donc son premier test d'intégration : webhook,
runner, clé LLM, build, deploy, e2e — tout est validé d'un coup, et le
premier échec arrive sur du travail auquel il tient.

**F3 — ~~Prolifération des labels et fuite d'internes~~ — RETIRÉ, l'analyse
était fausse.**

Une première version de ce document dénombrait « ~25 labels dont des internes
moteur exposés à l'utilisateur » (`boucle:verdict`, `boucle:split-parent`,
`boucle:e2e-origin`, `boucle:commit`, `boucle:obligations`…). Vérification
faite, c'était une erreur de méthode : un `grep boucle:[a-z-]+` qui confondait
**trois espaces de noms distincts**.

| Chaîne | Nature réelle | Visible dans la forge ? |
| --- | --- | --- |
| `<!-- boucle:verdict -->`, `<!-- boucle:split-parent -->`, `<!-- boucle:obligations -->`, … | Marqueurs HTML en corps de commentaire | **Non** |
| `[boucle:metrics]`, `[boucle:prompt]`, `[boucle:notify]`, `[boucle:guard]` | Préfixes de log CI | **Non** |
| `boucle:triage/todo/working/review/approval/merging/done/blocked/human/needs-info/spec-review/split` | Labels d'état (12), posés par `set_boucle_label` | Oui |
| `boucle::status::bot/human/done` | Labels scopés GitLab — la colonne de board | Oui |

Aucun interne moteur n'atteint donc le board, et les 12 labels d'état sont
auto-descriptifs (`needs-info`, `blocked`, `human` se lisent sans
documentation). La seule redondance résiduelle est voulue : chaque issue
porte l'état fin **et** la colonne de board, `set_boucle_label` prenant les
deux en arguments.

**Il n'y a pas de dette de lisibilité des labels.** Le modèle label-driven de
`CONTEXT.md` §7 tient ce qu'il promet.

**F4 — 67 variables `BOUCLE_*` éditées une par une dans une UI web.** Aucune
configuration versionnée côté consommateur, aucune validation au moment de
la saisie — la seule vérification est `bin/doctor --audit`, *a posteriori*.
Une faute de frappe sur `BOUCLE_DEPLOY_URL_REGEX` se découvre en fin de
boucle.

**F5 — Le coût est l'argument de vente numéro un, et il est invisible dans
le produit.** Le README consacre une section entière à « $0.80 par feature »
face à « $15.00 », mais « cost estimate » est encore une case non cochée de
la roadmap. Les données existent pourtant déjà (`cost.json`,
`health.jsonl` : tokens, coût, modèle, provider par run). L'écart entre la
promesse marketing et l'expérience vécue est un cadeau fait aux concurrents,
dont Devin, qui affiche ses ACU.

**F6 — Aucun signal de progression entre les gates.** Entre l'approbation du
spec et la MR, l'utilisateur ne sait pas s'il en a pour dix minutes ou pour
une heure, ni à quelle itération le worker en est. Le mode async est un
choix de conception juste, mais async ≠ opaque.

**F7 — Le vocabulaire d'interaction n'est pas auto-documenté.** Savoir qu'on
approuve avec 👍 ❤️ 🎉 🚀 ou par n'importe quel commentaire, que
`boucle:autonomous` saute le gate de spec, que `boucle:needs-info` attend une
réponse — tout cela vit dans le README et `LOOP.md`, jamais dans l'issue
elle-même, là où la décision se prend.

## 3. Comparatif DX (persona : contributeur / intégrateur)

| Critère | boucle | OpenHands | Copilot / Jules / Devin |
| --- | --- | --- | --- |
| Licence | AGPL-3.0 | MIT | Propriétaire |
| Contribution externe | Ouverte (`CONTEXT.md` §6) | Ouverte, 490+ contributeurs | Fermée |
| `CONTRIBUTING.md` | ❌ **absent** | ✅ | — |
| `CHANGELOG.md` | ❌ **absent** (auto-update inclus) | ✅ | Release notes |
| Versionnement | SHA (`.boucle-version` = `7575504`) | semver | semver |
| Templates issue/PR | ❌ absents | ✅ | — |
| Bootstrap dev | `make check` — outils à installer à la main | Docker | — |
| Tests | ✅ 22 fichiers bats, couverture sérieuse de `lib/` | pytest + SWE-bench | — |
| Exécution locale de la boucle | ❌ CI uniquement | ✅ headless local | Cloud only |

### D1 — La dette structurelle majeure : deux implémentations de la même boucle

C'est le point le plus lourd du dépôt, et il est mesurable.

```
lib/boucle-ci/*.sh            4 370 lignes   ← implémentation partagée, testée
.github/workflows/boucle.yml    493 lignes   ← 10 appels à `bin/boucle-ci <stage>`
.gitlab-ci.yml                5 243 lignes   ← 0 appel à `bin/boucle-ci`
                                                ~4 476 lignes de bash inline
```

L'en-tête de `lib/boucle-ci.sh` annonce l'intention : *« Both .gitlab-ci.yml
and .github/workflows/boucle.yml are thin wrappers that call
`bin/boucle-ci <stage>` »*. GitHub l'est. **GitLab ne l'est pas** : la
migration a été faite pour un seul forge. Le job `worker` seul pèse
829 lignes de bash embarqué dans du YAML (`.gitlab-ci.yml:1920-2748`), et le
fichier contient des aveux explicites de duplication :

- `.gitlab-ci.yml:579` — *« Kept in sync with lib/boucle-ci/dispatch.sh (same guard, two copies). »*
- `.gitlab-ci.yml:2904` — *« Mirrors lib/boucle-ci/reviewer.sh. »*

Conséquences concrètes :

1. **Chaque correctif doit être écrit deux fois**, sur l'implémentation de
   référence *et* sur la partagée — avec synchronisation manuelle.
2. **La suite bats ne couvre pas le chemin de référence.** Les tests portent
   sur `lib/` ; le bash inline de GitLab n'est exécuté que par un vrai
   pipeline.
3. **`shellcheck` ne voit pas le bash embarqué dans le YAML.** `make lint`
   analyse `git ls-files '*.sh'` et `bin/*` — 4 476 lignes de shell échappent
   au filet.
4. **Un contributeur ne peut rien exécuter localement** sur le chemin
   GitLab, ce qui allonge la boucle de feedback à un pipeline complet.
5. Le paradoxe est net : GitLab est « l'implémentation de référence »
   (`CONTEXT.md` §8) alors que GitHub est celle qui bénéficie de
   l'architecture propre.

### D2 — Hygiène projet open source absente

Ni `CONTRIBUTING.md`, ni `CHANGELOG.md`, ni `SECURITY.md`, ni code de
conduite, ni templates d'issue/PR. `.github/` ne contient que le workflow
moteur. Pour un projet AGPL qui déclare explicitement accueillir les
contributions externes (`CONTEXT.md` §6), c'est le premier obstacle rencontré
par un contributeur potentiel.

Le manque de CHANGELOG est aggravé par l'auto-update : en mode `release`
(défaut), `bin/update` tire le dernier tag amont (`bin/update:59-61`) et met
à jour le moteur du consommateur — **sans aucune note de version à lire**.
Le consommateur change de moteur sans savoir ce qui a changé. C'est doublement
gênant sur un projet dont la contrainte n°1 est le *fail-open*.

### D3 — `AGENTS.md` porte trois rôles incompatibles

1 580 lignes / 97 Ko qui servent simultanément de contexte de prompt pour les
agents, de guide du contributeur humain et de journal des leçons apprises
(la section « Lessons learned » couvre à elle seule les lignes 89 à 1455).
Or `LOOP.md` §Prompt budget documente précisément le risque de *context rot* :
le document le plus volumineux du dépôt alimente le contexte des agents.
Et un humain qui arrive n'a aucun point d'entrée navigable.

### D4 — Pas de harnais d'intégration local

`BOUCLE_DRY_RUN` n'existe que dans `bin/jc` (l'invocation d'agent). Il n'y a
aucun moyen de dérouler `dispatch → triage → worker` en local contre une
forge simulée. La couverture unitaire bats est bonne ; le chemin
d'intégration, lui, n'est testable qu'en CI réel — précisément là où les
bugs les plus coûteux se logent (webhooks, transitions de labels, rebase).

### D5 — Identité de version inexploitable

`.boucle-version` contient `7575504`. En mode `release`, l'update saute au
dernier tag. Un consommateur ne peut donc ni dire sur quoi il tourne en
termes lisibles, ni épingler une plage de versions, ni évaluer si une mise à
jour est mineure ou cassante.

## 4. Plan d'amélioration priorisé

Classé par **(impact ÷ effort)**. P0 = à faire avant toute nouvelle feature.

### P0 — Débloquer l'adoption et arrêter l'hémorragie

**P0.1 — Terminer l'extraction `boucle-ci` côté GitLab.** *(effort : L,
mécanique ; impact : maximal)*
Migrer les jobs un par un vers `bin/boucle-ci <stage>`, en prenant
`.github/workflows/boucle.yml` comme patron déjà éprouvé. Cible :
`.gitlab-ci.yml` autour de 400–600 lignes. Ordre suggéré, du moins risqué au
plus risqué : `check` → `deploy` → `post-merge` → `merger` → `catchup` →
`e2e` → `dispatch` → `reviewer` → `triage` → `worker`. Gains immédiats :
un seul correctif par bug, `shellcheck` sur 100 % du shell, la couverture
bats devient réelle sur les deux forges, et le delta GitLab/GitHub de
`CONTEXT.md` §8 disparaît. **Ajouter un garde-fou CI** qui échoue si
`.gitlab-ci.yml` réintroduit un bloc `script:` de plus de N lignes.

**P0.2 — Installation sans runner auto-hébergé par défaut.** *(effort : S ;
impact : élevé)*
Le socle existe déjà : 8 jobs tournent en `tags: []`, et l'image
`docker.io/ankabootops/boucle-agents:latest` — node 22, glab, jcode,
codebase-memory-mcp pré-cuits — est publiée et déjà utilisée par `merger`,
`post-merge` et `catchup`. Le `before_script` teste `command -v` avant chaque
installation, donc il fonctionne sur les deux exécuteurs.

Le seul verrou est `default: tags: [$BOUCLE_RUNNER_TAG]` (`.gitlab-ci.yml:151`)
avec le défaut `boucle`, qui laisse 5 jobs — `triage`, `worker`, `reviewer`,
`deploy`, `e2e` — exiger un runner taggé. Le fichier l'admet lui-même
(`.gitlab-ci.yml:145`) : *« a shared docker runner without a matching tag
cannot pick up these jobs »*.

Correctif : `BOUCLE_RUNNER_TAG` vide par défaut, `image:
docker.io/ankabootops/boucle-agents:latest` sur le bloc `default:`, et
`bin/setup` n'écrit un tag que si `--runner-tag` est passé explicitement.

**Contrepartie à documenter honnêtement — elle touche l'argumentaire coût.**
GitLab.com Free plafonne à **400 minutes de calcul/mois** (puis $10/1 000 min) ;
les runners auto-hébergés sont illimités. Les jobs d'agent sont longs (latence
LLM) et une feature consomme triage + jusqu'à 3 worker + 3 reviewer + e2e —
soit 30 à 60 min de calcul, donc **7 à 13 features/mois** avant facturation.
Les « ~125 features/mois » du README supposent donc implicitement un runner à
minutes illimitées. Le tableau de capacité doit porter **deux lignes** :
runner auto-hébergé (minutes gratuites, coût = la machine) et shared runner
(installation nulle, minutes facturées). Sans cela, la promesse de coût et la
promesse d'installation se contredisent.

À noter : rien ne persiste entre runs sur docker — c'est la raison d'être de
`Dockerfile.agents` — et Chromium reste installé à la demande via npm
(`puppeteer-core` + `@sparticuz/chromium`, `lib/boucle-ci/triage.sh:395`),
soit ~30–60 s par job de preview, à imputer aux minutes.

**P0.3 — Issue de fumée en fin d'installation.** *(effort : M ; impact : élevé)*
`bin/setup --smoke` crée une issue triviale et auto-refermante qui traverse
toute la chaîne (dispatch → triage → worker → preview → e2e). L'utilisateur
obtient une validation verte de bout en bout avant d'y engager du travail
réel. Transforme F2 en argument de confiance.

**P0.4 — Note d'instruction au gate MR.** *(effort : S ; impact : moyen)*
*Réduit : la version initiale demandait une antisèche permanente sur chaque
issue. Vérification faite, elle existe déjà au gate de spec —
`lib/boucle-ci/triage.sh:318` poste « React with 👍 ❤️ 🎉 or 🚀 on this
comment to approve, OR Reply to this issue with any comment ».*

Il reste une **asymétrie** : au gate MR, le reviewer pose `boucle:approval` +
`boucle::status::human` et s'en remet à l'approbation native de la forge, sans
rien expliquer. Pour un profil produit, « approuver nativement une MR » est
nettement moins évident que « réagir 👍 ». Correctif : une note calquée sur
`SPEC_MSG`, postée une fois à l'entrée du gate. En anglais, comme tout le
moteur.

**P0.5 — ~~Hygiène des labels~~ — RETIRÉ.** Fondé sur F3, dont l'analyse était
fausse (voir §2). Il n'y a pas d'internes moteur sur le board.

### P1 — L'UX de la boucle elle-même

**P1.1 — ~~Commentaire « Loop status » édité en place~~ — ABANDONNÉ.**

Proposé pour traiter F5 (coût invisible) et F6 (pas de progression). Trois
vérifications l'ont invalidé :

1. **Le coût en dollars n'existe pas, et c'est délibéré.** `LOOP.md` §Cost
   accounting : *« No dollars without `BOUCLE_PRICING_JSON`. Prices drift and
   boucle is provider-agnostic; hardcoding them would produce confident wrong
   numbers. Unset, you get token counts. »* Les tokens eux-mêmes peuvent valoir
   `n/a`. Et la description de la MR **porte déjà** un `### Cost` par rôle.
2. **La fréquence de rafraîchissement est inatteignable.** boucle est
   événementiel : la note ne s'écrit que quand un job tourne, soit aux
   transitions d'étape (~6–10 par issue). Un « depuis 18 min » serait figé au
   dernier job. Rafraîchir plus souvent supposerait de mobiliser le doctor —
   exactement ce que sa cadence adaptative vient d'éliminer (*« on an idle
   repository, a runner provisioned to confirm nothing changed »*).
3. **À cette fréquence, un label fait déjà le travail** — sans écriture
   supplémentaire et avec le rendu kanban en prime.

F5 et F6 restent donc ouverts, mais aucun des deux ne justifie une nouvelle
surface. Le seul élément qu'aucun label ne porte est **l'itération n/max** :
ce n'est pas une colonne de board mais un signal de dégradation à l'intérieur
d'un état (à `boucle:working`, l'humain ne distingue pas « ça avance » de
« dernière tentative avant escalade »). Si on le traite, c'est un suffixe sur
le label existant, pas une note.

**P1.2 — Configuration versionnée.** *(effort : M ; impact : moyen)*
Un `.boucle/config.yml` côté consommateur pour tout le non-secret, avec les
variables CI/CD conservées pour les seuls secrets et gardant la priorité.
Validation par `bin/doctor --audit` exécuté en CI sur chaque push : les
erreurs de configuration deviennent des échecs de PR au lieu de pannes en
milieu de boucle. Répond à F4.

### P2 — Hygiène projet et fondations contributeur

**P2.1 — `CHANGELOG.md`.** *(effort : S ; impact : moyen — le plus urgent du
lot)* En mode `release` (le défaut), `bin/update` tire le dernier tag amont
(`bin/update:59-61`) et remplace le moteur du consommateur. Aujourd'hui
personne ne peut lire ce qui a changé. C'est une asymétrie gênante sur un
projet dont la contrainte n°1 est le *fail-open* : le pipeline est protégé
contre les erreurs, mais l'utilisateur ne l'est pas contre les changements de
comportement. Concrètement : un CHANGELOG au format Keep a Changelog, et
`bin/update` qui inscrit l'URL des notes de version dans le message de son
commit de bump.

**P2.2 — `CONTRIBUTING.md`.** *(effort : S)* Aujourd'hui, contribuer suppose
de lire 1 580 lignes d'`AGENTS.md`. Une page suffit : prérequis (shellcheck,
shfmt, bats), `make check`, où vit la logique (`lib/boucle-ci/`), conventions
de commit (déjà rédigées dans `AGENTS.md` §Commit conventions) et workflow
upstream-first.

**P2.3 — `SECURITY.md`.** *(effort : S)* Le produit manipule un PAT bot, une
clé LLM et un token Cloudflare, et pratique la rédaction de secrets dans les
logs (`bin/jc`). Gérer tout cela sans politique de divulgation est incohérent
avec le soin déjà mis dans le code.

**P2.4 — Templates d'issue côté consommateur.** *(effort : S ; impact : moyen)*
Ce point n'est pas de l'hygiène mais du produit : boucle est *piloté par les
issues*. Un template améliore directement la qualité de l'entrée du triage —
et donne à un coéquipier non technique (§6) un formulaire plutôt qu'une page
blanche.

**P2.5 — Tags semver + `.boucle-version` lisible.** *(effort : S)*
`.boucle-version` contient `7575504`, un SHA, et le mode release saute au
dernier tag. Impossible d'épingler une plage, de dire sur quoi on tourne, ni
de distinguer une mise à jour mineure d'une cassante.

**P2.6 — Éclater `AGENTS.md`.** *(effort : M)* Un fichier porte trois rôles
incompatibles : contexte de prompt des agents, guide du contributeur humain,
journal des leçons (lignes 89–1455 à lui seul). Or `LOOP.md` §Prompt budget
documente précisément le risque de *context rot* — le plus gros fichier du
dépôt alimente le contexte des agents. Découpage : un noyau court et impératif
(les 11 principes opérationnels) pour les agents, `docs/lessons/` pour
l'historique, `CONTRIBUTING.md` pour les humains.

**P2.7 — Bootstrap dev + harnais d'intégration local.** *(effort : M)*
`mise`/devcontainer plus une cible `make dev` qui installe shellcheck, shfmt
et bats ; fixture de forge simulée permettant d'exécuter `bin/boucle-ci
<stage>` hors-ligne. N'est réalisable qu'**après** P0.1 — et c'est précisément
ce qui rend P0.1 rentable au-delà de la seule déduplication : aujourd'hui, les
bugs les plus coûteux (webhooks, transitions de labels, rebase) ne sont
testables qu'en CI réel.

## 5. Ce qu'il ne faut surtout pas copier

- **Pas de dashboard web, pas de TUI, pas de SaaS.** L'absence d'interface
  est le fossé défensif face à Devin et Lovable, pas une lacune à combler.
  `CONTEXT.md` §7 l'interdit — c'est une bonne interdiction.
- **Ne pas courir après SWE-bench.** Codex annonce 88,7 % ; boucle ne gagnera
  pas cette course et n'en a pas besoin. L'argument est explicitement posé
  dans le README : *« le modèle décide de ce qu'il tente ; les gates et les
  skills décident de ce qui ship »*. Investir dans les gates, pas dans les
  modèles.
- **Ne pas rendre la boucle synchrone.** Le contrôle du timing (async + DND)
  est un choix produit fort, à contre-courant des chats qui exigent une
  présence permanente.

## 6. Le persona, et ce qu'il implique pour les priorités

Le persona visé (précision du mainteneur, 2026-08) : des gens qui **ne sont
plus nécessairement développeurs mais ont des bases techniques**, ou qui
**veulent collaborer avec des utilisateurs non techniques au sein d'une
équipe**.

Cela lève la tension supposée entre le persona et le coût d'installation :
demander une forge, un PAT et des variables CI/CD à quelqu'un qui a des bases
techniques est parfaitement cohérent. P0.2 reste souhaitable, mais comme
confort d'adoption — pas comme enjeu existentiel.

En revanche, le second volet — **l'équipe mixte** — impose une exigence qui
change le classement des priorités. Les rôles s'y séparent nettement :

| Rôle | Ce qu'il touche | Ce dont il a besoin |
| --- | --- | --- |
| **L'installateur technique** | setup, runner, PAT, 67 variables | Une fois, au départ. Sert P0.2, P1.2, P2.x |
| **Le coéquipier non technique** | l'issue, et rien d'autre | Créer, lire un TL;DR, réagir 👍, commenter |

Pour le second, **l'issue *est* le produit** — il n'y a pas d'autre surface.

J'en avais déduit deux chantiers prioritaires. La vérification dans le code
les a réduits à presque rien, et c'est une bonne nouvelle pour boucle :

- **L'antisèche existe déjà** au gate de spec (`lib/boucle-ci/triage.sh:318`).
  Seul le gate MR n'a pas d'équivalent — c'est tout ce qui reste de P0.4.
- **Les labels sont déjà lisibles** : les internes moteur sont des marqueurs
  HTML et des préfixes de log, jamais des labels (§2, F3). P0.5 est retiré.

Autrement dit, la surface vue par le coéquipier non technique est **déjà
correcte**. L'écart face à Lovable ou Replit ne se joue pas sur la lisibilité
de l'issue, mais en amont : le fait qu'il faille une forge, un compte et une
issue pour entrer dans le produit. C'est un choix d'architecture assumé
(`CONTEXT.md` §7), pas un défaut à corriger.

**Recommandation** : inscrire cette formulation du persona dans
`CONTEXT.md` §3, qui dit aujourd'hui seulement « pas nécessairement
développeurs à plein temps ». Le volet « équipe mixte » n'y figure pas, alors
qu'il est ce qui justifie de traiter la lisibilité de l'issue comme une
fonctionnalité de premier plan.

## 7. Références

- `README.md`, `CONTEXT.md`, `LOOP.md`, `AGENTS.md` — documents de charte
- `.gitlab-ci.yml`, `.github/workflows/boucle.yml`, `lib/boucle-ci/` — implémentations
- [GitHub Copilot coding agent](https://docs.github.com/copilot/concepts/agents/coding-agent/about-coding-agent)
- [Assigning and completing issues with coding agent](https://github.blog/ai-and-ml/github-copilot/assigning-and-completing-issues-with-coding-agent-in-github-copilot/)
- [OpenHands — coding agents fixing your issues](https://www.openhands.dev/blog/open-source-coding-agents-in-your-github-fixing-your-issues)
- [Jules vs Codex — async VM vs sandbox](https://weavai.app/blog/en/2026/05/21/2026-google-jules-vs-openai-codex-async-vm-vs-sandbox/)
- [Devin pricing & ACU](https://www.lindy.ai/blog/devin-pricing)
- [Lovable vs Bolt vs Replit (2026)](https://lovable.dev/guides/bolt-vs-replit-vs-lovable)
