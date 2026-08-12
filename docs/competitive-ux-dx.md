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

**F1 — Le temps avant la première valeur est le principal frein à l'adoption.**
Le parcours GitLab exige d'enregistrer un runner auto-hébergé portant le tag
`boucle` (`README.md:129-132`), d'ajouter manuellement une variable masquée,
de provisionner un compte bot et un PAT, et un token Cloudflare. Le persona
visé — « ceux qui construisent des produits mais ne sont pas forcément
développeurs à plein temps » (`CONTEXT.md` §3) — décroche avant l'étape 2.
Le parcours GitHub est nettement plus léger (`ubuntu-latest`, pas de runner à
gérer) mais `CONTEXT.md` §8 le déclare lui-même « moins éprouvé ».
**Il y a une contradiction entre le persona affiché et le coût d'installation
réel.**

**F2 — Rien ne prouve que l'installation fonctionne.** `bin/setup` se termine
sur « Create your first issue » (`bin/setup:1231`). La première issue réelle
de l'utilisateur devient donc son premier test d'intégration : webhook,
runner, clé LLM, build, deploy, e2e — tout est validé d'un coup, et le
premier échec arrive sur du travail auquel il tient.

**F3 — Prolifération des labels et fuite d'internes.** Deux espaces de noms
coexistent (`boucle:*` et `boucle::status::*`) pour ~25 labels distincts, dont
des internes moteur exposés à l'utilisateur : `boucle:e2e-origin`,
`boucle:split-parent`, `boucle:commit`, `boucle:obligations`,
`boucle:verdict`. L'utilisateur n'en manipule réellement que 3 ou 4.

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
approuve avec 👍 ✅ ☑️ ✔️ 🆗 👌 ou par n'importe quel commentaire, que
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
Supporter et documenter les runners partagés gitlab.com (tag par défaut vide
ou `saas-linux-small-amd64` plutôt que `boucle` obligatoire), et promouvoir
le parcours GitHub comme chemin d'entrée officiel — il ne demande aucune
infrastructure. Faire tomber F1 de ~45 min à ~5 min est le levier d'adoption
le plus rentable du dépôt.

**P0.3 — Issue de fumée en fin d'installation.** *(effort : M ; impact : élevé)*
`bin/setup --smoke` crée une issue triviale et auto-refermante qui traverse
toute la chaîne (dispatch → triage → worker → preview → e2e). L'utilisateur
obtient une validation verte de bout en bout avant d'y engager du travail
réel. Transforme F2 en argument de confiance.

### P1 — L'UX de la boucle elle-même

**P1.1 — Un commentaire « Loop status » édité en place, par issue.**
*(effort : M ; impact : élevé — traite F5 + F6 d'un seul coup)*
Étape courante, itération n/max, coût cumulé, liens job + preview. Toutes les
données existent déjà (`health.jsonl`, `cost.json`). Réutiliser exactement le
modèle du status board : édition en place, zéro écriture API si le corps est
inchangé (`LOOP.md` §Status board). Coche au passage l'item roadmap
« cost estimate » et aligne enfin le produit sur son propre argumentaire.

**P1.2 — Hygiène des labels.** *(effort : S ; impact : moyen)*
Un seul espace de noms. Les internes moteur (`boucle:e2e-origin`,
`boucle:split-parent`, `boucle:commit`, `boucle:obligations`) passent en
métadonnées de corps d'issue ou reçoivent une couleur neutre les excluant du
board. Documenter explicitement les 4 labels que l'humain manipule.

**P1.3 — Configuration versionnée.** *(effort : M ; impact : moyen)*
Un `.boucle/config.yml` côté consommateur pour tout le non-secret, avec les
variables CI/CD conservées pour les seuls secrets et gardant la priorité.
Validation par `bin/doctor --audit` exécuté en CI sur chaque push : les
erreurs de configuration deviennent des échecs de PR au lieu de pannes en
milieu de boucle. Répond à F4.

**P1.4 — Antisèche d'interaction dans l'issue.** *(effort : S ; impact : moyen)*
Le premier commentaire de boucle sur chaque issue liste ce que l'humain peut
faire : réactions valant approbation, effet d'un commentaire, labels
disponibles. L'interface se documente là où la décision se prend, plutôt que
dans le README. Répond à F7.

### P2 — Hygiène projet et fondations contributeur

**P2.1 — `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, templates
issue/PR.** *(effort : S ; impact : moyen)* Le CHANGELOG est le plus urgent
des quatre : `bin/update` doit lier les notes de version dans son commit de
bump, pour qu'une auto-mise-à-jour cesse d'être opaque.

**P2.2 — Tags semver + `.boucle-version` lisible.** *(effort : S)* Permet
d'épingler, de diagnostiquer, et de distinguer une mise à jour mineure d'une
cassante.

**P2.3 — Éclater `AGENTS.md`.** *(effort : M)* Garder un noyau court et
impératif pour les agents (principes opérationnels), déplacer les leçons
apprises vers `docs/lessons/`, et écrire un vrai guide contributeur humain.
Bénéfice double : budget de prompt allégé et point d'entrée lisible.

**P2.4 — Bootstrap dev + harnais d'intégration local.** *(effort : M)*
`mise`/devcontainer plus une cible `make dev` qui installe shellcheck, shfmt
et bats ; fixture de forge simulée permettant d'exécuter `bin/boucle-ci
<stage>` hors-ligne. Devient réalisable une fois P0.1 livré — et c'est
précisément ce qui rend P0.1 rentable au-delà de la seule déduplication.

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

## 6. Le point stratégique à trancher

`CONTEXT.md` §3 vise les « Product Builders, pas nécessairement développeurs
à plein temps ». Or l'installation réelle demande une forge, un runner, un
compte bot, un PAT, des variables CI/CD masquées et un token Cloudflare —
c'est-à-dire des compétences de DevOps. Deux issues cohérentes :

1. **Tenir le persona** → P0.2 et P0.3 sont alors existentiels, et l'objectif
   devient une installation en une commande sans aucune infrastructure.
2. **Recadrer le persona** → « fondateurs techniques solos et petites équipes
   déjà installées sur GitLab/GitHub », ce que le produit sert déjà très bien.
   Les documents charte doivent alors le refléter.

Les deux sont défendables. Ce qui ne l'est pas, c'est de vendre le premier
tout en livrant le second : c'est exactement là que se creuse l'écart entre
la promesse et la première impression.

## 7. Références

- `README.md`, `CONTEXT.md`, `LOOP.md`, `AGENTS.md` — documents de charte
- `.gitlab-ci.yml`, `.github/workflows/boucle.yml`, `lib/boucle-ci/` — implémentations
- [GitHub Copilot coding agent](https://docs.github.com/copilot/concepts/agents/coding-agent/about-coding-agent)
- [Assigning and completing issues with coding agent](https://github.blog/ai-and-ml/github-copilot/assigning-and-completing-issues-with-coding-agent-in-github-copilot/)
- [OpenHands — coding agents fixing your issues](https://www.openhands.dev/blog/open-source-coding-agents-in-your-github-fixing-your-issues)
- [Jules vs Codex — async VM vs sandbox](https://weavai.app/blog/en/2026/05/21/2026-google-jules-vs-openai-codex-async-vm-vs-sandbox/)
- [Devin pricing & ACU](https://www.lindy.ai/blog/devin-pricing)
- [Lovable vs Bolt vs Replit (2026)](https://lovable.dev/guides/bolt-vs-replit-vs-lovable)
