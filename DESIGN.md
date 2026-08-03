# DESIGN.md — Charte visuelle d'Urgence Palestine

> Synthèse opérationnelle de l'identité visuelle du site. Ce document est la
> **référence unique** que tout nouveau composant, visuel, contenu rédigé ou
> contribution extérieure doit consulter avant d'être livré.
>
> Les valeurs concrètes (couleurs, échelles, durées) vivent dans
> [`src/styles/tokens.css`](src/styles/tokens.css). Ce fichier en expose
> l'intention, les interdits, et la direction esthétique.

---

## 1. Philosophie

### 1.1 Identité humaine, imparfaite, intentionnelle

Urgence Palestine est un **collectif d'action** — pas une marque, pas une
agence, pas une plateforme SaaS. Le site doit avoir l'air d'avoir été fait
**par des gens qui savent pourquoi ils se lèvent le matin**, pas par un outil
générique.

Concrètement :

- **Humain avant tout** : on assume des choix éditoriaux qui sentent le
  comité de rédaction militant — phrases directes, mots pesés, hierarchie
  visuelle forte, pas de voix corporate.
- **Imparfait assumé** : un cadre dur, une typo qui s'impose, un peu
  d'espace blanc ou de noir plein — pas de polissage en sucre glace. La
  rugosité sert le propos.
- **Intentionnel à chaque pixel** : si un élément n'a pas de raison d'être
  là, on l'enlève. Pas de décoration « pour faire joli ». Pas de gradient
  décoratif. Pas d'illustration stock.

### 1.2 Opposition aux standards IA génériques

Le site doit être **immédiatement reconnaissable** comme n'étant pas
sorti d'un template AI/Dribbble. Les marqueurs typiques de cette laideur
sont tous interdits — voir la section 2.

Le test simple : si on cache le logo et qu'on montre une capture d'écran à
quelqu'un, doit-on pouvoir l'identifier comme « un site militant pour la
Palestine » avant de lire un mot ? Si l'écran ressemble à une landing page
de startup B2B avec un sous-titre « Solidarité » glissé dedans, on a perdu.

### 1.3 Finalité politique du collectif

Chaque décision de design sert un objectif **politique et opérationnel** :

- **Informer** — la lisibilité prime sur la décoration.
- **Agir** — chaque page doit pousser vers une action concrète
  (don, engagement, prise de parole, relais).
- **Faire mémoire** — chaque pièce visuelle doit pouvoir être reprise
  (screenshot, capture, impression) sans perdre son impact.

Aucun ton corporate. Aucune neutralité tiède. Aucune promesse vide.

---

## 2. Interdits

Liste **exhaustive** des signaux « design générique / IA » interdits sur
l'ensemble du site. Tout composant qui en contient un seul doit être
revu avant publication.

### 2.1 Grille et mise en page

- ❌ **Grille bento** (cards de tailles inégales dans une grille sans
  hiérarchie claire).
- ❌ **Cartes arrondies uniformes** (`border-radius` 8–16 px systématiques).
- ❌ **Cartes « SaaS »** : fond `--color-paper-soft`, coin arrondi, ombre
  douce, padding généreux — la combinaison interdite par excellence.
- ❌ **Centrage par défaut** de tout (texte, blocs, listes) — le rendu
  asymétrique est plus juste.
- ❌ **Padding massif et régulier** autour de chaque bloc.

### 2.2 Couleurs

- ❌ **Dégradés violets / bleus / cyan** (la signature Tailwind/AI la plus
  reconnaissable). Aucun gradient décoratif en arrière-plan.
- ❌ **Bleu « tech »** comme couleur d'accent ou de lien.
- ❌ **Palette pastel sucrée** globale.
- ❌ **Trop de couleurs à la fois** : on reste sur noir + blanc + les
  quatre couleurs du drapeau palestinien. Point.

### 2.3 Typographie

- ❌ **Inter, Roboto, Arial, « System UI »** en police principale sans
  traitement. Ces familles signalent immédiatement un site générique.
- ❌ **Structure « tout en MAJUSCULES AVEC LETTER-SPACING ÉNORME »** —
  la combinaison « H1 gras + uppercase + tracking 0.2em + 36px » est un
  marqueur IA bien documenté. **Petits sous-titres en majuscules + tracking
  0.18em+ au-dessus des titres (`.eyebrow` et équivalents) sont interdits
  par défaut, proscrits.**
- ❌ **Centrage systématique** des titres et paragraphes.
- ❌ **Hiérarchie molle** : si on ne sait pas distinguer H1 / H2 / H3 du
  premier coup d'œil, on refait.

### 2.4 Effets et motion

- ❌ **Transitions CSS parfaitement ease-in-out** sur tout élément
  interactif — la régularité parfaite étouffe l'intention.
- ❌ **Ombres douces diffuses systématiques** (`box-shadow: 0 8px 32px
  rgba(0,0,0,0.08)` et variantes).
- ❌ **Glassmorphism** (fond flou, transparence sur fond coloré).
- ❌ **Animations qui durent plus longtemps que nécessaire** (`.4s ease`
  par défaut sur tout).

### 2.5 Espace et composition

- ❌ **Espace blanc massif et homogène** entre chaque bloc, comme sur les
  landing pages Stripe ou Linear. Notre espace est **rythmé**, pas vide.

---

## 3. Direction positive : Brutalisme éditorial

L'option retenue (parmi les quatre proposées) est le **brutalisme**, avec
une inflexion **éditoriale** assumée. C'est la direction déjà incarnée
dans les tokens, le CSS et la page d'accueil actuelle — ce document la
nomme explicitement pour qu'elle ne dérive plus.

> Pourquoi le brutalisme : il sert notre propos politique. Une cause
> urgente, traitée par un cadre dur, sans sucre, sans bling-bling — la
> forme colle au fond. Le peuple palestinien n'a pas le temps des
> dégradés violets.

### 3.1 Caractéristiques de forme

| Aspect | Décision |
| --- | --- |
| **Coins** | Toujours **droits** (`border-radius: 0`). Aucun arrondi. |
| **Bordures** | Traits francs, noirs, 1–2 px ou plus quand nécessaire. Pas de `border-image`. |
| **Découpage** | Blocs rectangulaires qui s'empilent, se coupent, se juxtaposent. Pas de flottement. |
| **Texture** | Aucune texture décorative (pas de grain SVG répété, pas de noise PNG). |

### 3.2 Ombre et profondeur

Ombre **rare et franche** quand elle existe :

```css
/* À utiliser — relief franc, pas diffusé */
--shadow-soft: 0 1px 0 rgba(0, 0, 0, 0.04);
--shadow-lift: 0 18px 40px -24px rgba(15, 15, 15, 0.32);
```

Jamais d'ombres douces diffuses continues — c'est l'un des tout premiers
signaux de design générique.

### 3.3 Typographie

Deux familles, **deux rôles**, contrat clair :

| Famille | Rôle | Tailwind / CSS |
| --- | --- | --- |
| **The Bold Font** (Sven Pels) | Titres, display, CTA, hero | `var(--font-heading)` |
| **Poppins** | Corps, UI, formulaires, nav | `var(--font-body)` |

- **The Bold Font** est auto-hébergée sous `/fonts/the-bold-font.woff2`.
  C'est un display géométrique fort qui **s'impose** sans avoir à
  monter en taille démesurément.
- **Poppins** est auto-hébergée sous `/fonts/poppins-{400,500,600,700}.woff2`.
  Modern, neutre, lisible — un sans-serif de **travail**, pas de parade.
- **Fallback display** : si The Bold Font ne charge pas, on retombe sur
  `Boldonse`, `Anton`, `Oswald`, `Arial Black`, `Impact`, `sans-serif`.
  Ces familles de secours partagent la même énergie (display condensé
  géométrique) plutôt que de retomber dans un défaut générique.
- **Police mono** réservée au code ; jamais utilisée pour du contenu
  éditorial.

**Échelle typographique** (fluid, ratio mineur +3 ≈ 1.200) :

| Token | Plage fluide |
| --- | --- |
| `--text-xs` | `clamp(0.75rem, 0.71rem + 0.2vw, 0.8125rem)` |
| `--text-sm` | `clamp(0.875rem, 0.83rem + 0.23vw, 0.9375rem)` |
| `--text-base` | `clamp(1rem, 0.95rem + 0.25vw, 1.0625rem)` |
| `--text-lg` | `clamp(1.125rem, 1.06rem + 0.32vw, 1.25rem)` |
| `--text-xl` | `clamp(1.375rem, 1.27rem + 0.5vw, 1.625rem)` |
| `--text-2xl` | `clamp(1.75rem, 1.55rem + 0.95vw, 2.25rem)` |
| `--text-3xl` | `clamp(2.25rem, 1.9rem + 1.7vw, 3.25rem)` |
| `--text-4xl` | `clamp(3rem, 2.3rem + 3.4vw, 5rem)` |
| `--text-display` | `clamp(3.75rem, 2.7rem + 5vw, 7rem)` |

### 3.4 Palette

**Philosophie : le noir et le blanc d'abord, le drapeau ensuite.**

Le site vit à 80 % en monochrome (ink / paper). Les quatre couleurs du
drapeau palestinien (rouge, vert, blanc, noir) sont réservées aux **moments
où elles portent un signal politique** :

- bandeau tricolore du drapeau,
- bouton d'action primaire (CTA don, « j'agis »),
- encart de mobilisation,
- pied de page et fond noir.

#### Surfaces et encre (prédominantes)

| Token | Rôle | OKLCH |
| --- | --- | --- |
| `--color-ink` | Corps de texte | `oklch(15% 0 0)` |
| `--color-ink-soft` | Titres légèrement relevés | `oklch(28% 0 0)` |
| `--color-ink-muted` | Texte secondaire | `oklch(45% 0 0)` |
| `--color-ink-faint` | Légendes, méta | `oklch(62% 0 0)` |
| `--color-paper` | Fond de page | `oklch(99% 0 0)` |
| `--color-paper-soft` | Surface alternée (rare) | `oklch(96.5% 0 0)` |
| `--color-paper-edge` | Filet, séparateur | `oklch(91% 0 0)` |
| `--color-ink-on-dark` | Texte sur fond noir | `oklch(98% 0 0)` |

#### Couleurs du drapeau (accents)

| Token | Rôle | OKLCH |
| --- | --- | --- |
| `--color-flag-red` | Action, CTA, accent politique | `oklch(53% 0.21 27)` |
| `--color-flag-red-deep` | Hover / pressed | `oklch(42% 0.19 27)` |
| `--color-flag-green` | Bloc « mobilisation », accent | `oklch(45% 0.13 145)` |
| `--color-flag-green-deep` | Hover / pressed | `oklch(35% 0.11 145)` |
| `--color-flag-white` | Texte sur fond rouge/vert | `oklch(99% 0 0)` |
| `--color-flag-black` | Fond plein (footer, hero CTA) | `oklch(15% 0 0)` |

> **Note** : les couleurs sont exprimées en OKLCH. Les valeurs hex
> équivalentes sont calculées par le navigateur au moment du rendu. Pour
> vérifier une teinte précise, ouvrir DevTools, inspecter l'élément et
> lire la couleur en `oklch(…)` ; les valeurs hex sortiront automatiquement
> correctes.

#### Tokens sémantiques (à utiliser dans le code)

| Token | Pointe vers |
| --- | --- |
| `--color-text`, `--color-text-soft/muted/faint` | `--color-ink*` |
| `--color-bg`, `--color-bg-soft` | `--color-paper*` |
| `--color-border` | `--color-paper-edge` |
| `--color-accent`, `--color-accent-strong` | `--color-flag-red*` |
| `--color-secondary`, `--color-secondary-strong` | `--color-flag-green*` |
| `--color-link`, `--color-link-hover` | ink → flag-red |

### 3.5 Espacement et grille

Grille **8 pt** classique, avec rampes fluides pour les grands
espacements :

| Token | Valeur | Usage |
| --- | --- | --- |
| `--space-3xs` | `0.25rem` (4 px) | Ajustement inline |
| `--space-2xs` | `0.5rem` (8 px) | Marge interne faible |
| `--space-xs` | `0.75rem` (12 px) | Marge interne |
| `--space-s` | `1rem` (16 px) | Marge standard |
| `--space-m` | `clamp(1.25rem, 1.1rem + 0.6vw, 1.5rem)` | Entre paragraphes |
| `--space-l` | `clamp(1.75rem, 1.5rem + 1.1vw, 2.25rem)` | Entre sous-sections |
| `--space-xl` | `clamp(2.5rem, 2rem + 2vw, 3.5rem)` | Séparation majeure |
| `--space-2xl` | `clamp(3.5rem, 2.5rem + 4vw, 5.5rem)` | Frontière de section |
| `--space-3xl` | `clamp(5rem, 3.5rem + 6vw, 8rem)` | Héros |

Conteneurs (largeurs max) :

| Token | Valeur | Usage |
| --- | --- | --- |
| `--container-narrow` | `42rem` | Lecture d'article |
| `--container-base` | `60rem` | Newsletter, formulaires |
| `--container-wide` | `78rem` | Page, sections |

### 3.6 Rayons, ombres, motion

#### Rayons (`--radius-*`)

| Token | Valeur | Usage |
| --- | --- | --- |
| `--radius-sharp` | `0` | Défaut site — bord droit |
| `--radius-xs` | `4px` | Filets arrondis très légers |
| `--radius-s` | `8px` | **Réservé, à éviter** |
| `--radius-m` | `14px` | **Interdit en usage normal** |
| `--radius-l` | `22px` | **Interdit** — c'est le radius « carte SaaS » |
| `--radius-pill` | `999px` | Uniquement pour la `flag-stripe` du drapeau |

> **Règle d'or : par défaut, `var(--radius-sharp)`.** Tout autre radius
> doit être justifié dans la PR.

#### Motion

| Token | Valeur |
| --- | --- |
| `--ease-out` | `cubic-bezier(0.22, 1, 0.36, 1)` |
| `--ease-in-out` | `cubic-bezier(0.65, 0, 0.35, 1)` (à utiliser **rarement**) |
| `--duration-fast` | `140 ms` |
| `--duration-base` | `240 ms` |
| `--duration-slow` | `420 ms` |

`@media (prefers-reduced-motion: reduce)` ramène toutes les durées à
`0 ms` — toujours.

### 3.7 Variante « angled-split » des CTA

La variante `angled-split` du composant `GeneralCTA` impose deux règles
supplémentaires, en complément de la charte brute du collectif :

1. **Le fond coloré épouse la largeur du texte**, pas celle du conteneur.
   Chaque stripe est rendu avec `display: inline-block; width: fit-content`.
   Le texte est enveloppé dans un `<span>` inline portant le fond et le
   padding ; `box-decoration-break: clone` (y compris le préfixe WebKit)
   garantit que chaque fragment de ligne wrap garde son propre fond serré,
   sans bandeau plein-largeur entre les lignes.

2. **Coupe diagonale discrète entre la stripe verte (titre, en haut) et la
   stripe rouge (label CTA, en bas).** L'angle visible doit rester discret,
   compris **entre 6° et 10°**. La stripe verte conserve un bord inférieur
   **strictement horizontal** — c'est un fond de texte stable. La stripe
   rouge, située juste en dessous, est inclinée vers le haut à droite
   (`transform: skewY(-6°)`), créant une pente ascendante. Le texte rouge
   est contre-incliné (`skewY(6°)`) pour rester horizontal et lisible.
   Cette règle évite l'effet « deux triangles » où les deux blocs
   seraient coupés en biais.

Ces deux contraintes préservent les exigences d'accessibilité existantes :
hit-area vertical ≥ 44 px sur les deux stripes, texte blanc sur fond vert
ou rouge du drapeau (contraste AA), et `aria-labelledby` pointant vers
le `<h2>` du titre.

### 3.8 Le « vibe » en une phrase

**Le site ressemble à un tract imprime sur du papier offset noir et
rouge par un comité de rédaction qui sait ce qu'il fait.** Pas un tract
agressif pour autant — un tract **tenu**, lisible, qui assume son sujet
sans crier plus fort que nécessaire.

### 3.9 « Grunge highlight » du lien featured

Le lien **« Right to Resist »** dans le header principal (`navItems[3]`
dans [`src/components/Header.astro`](src/components/Header.astro))
bénéficie d'un surligné *rough marker stroke* qui apparaît **derrière**
le texte au `:hover` et `:focus-visible`, et **disparaît** lorsque
l'interaction se termine. Il ne faut jamais se substituer à un
`text-decoration: underline`.

#### Contrastes par surface

| Surface du header | Fond du surligné | Texte au hover/focus | Contraste |
| --- | --- | --- | --- |
| Étendu (fond noir) | `--color-flag-white` | `--color-flag-red` | Rouge sur blanc ≥ 4.5:1 (AA) |
| Défilé (fond rouge sang) | `--color-flag-white` | `--color-flag-red` | Rouge sur blanc ≥ 4.5:1 (AA) |
| Clair (fond blanc, futur) | `--color-flag-red` | `--color-flag-white` | Blanc sur rouge ≥ 4.5:1 (AA) |

> Le cas blanc-sur-rouge au hover a été abandonné pour le header
> scrollé : le blanc sur le rouge sang `--color-flag-red`
> (`oklch(53% 0.21 27)`) n'atteint pas 4.5:1 à la taille de texte
> `--text-sm`. On garde donc le surligné **blanc** et on inverse
> le texte en rouge.

#### Règles d'implémentation

- Le surligné est un pseudo-élément `::after` positionné en arrière-plan
  (`z-index: -1`) avec `left: -2px; right: -2px; bottom: 2px; height: 70%`.
- La texture est produite par **deux gradients linéaires superposés**
  (angles 104deg et 183deg) et une légère rotation (`transform:
  rotate(-1deg)`), créant des bords irréguliers sans recourir à une
  image externe.
- La couleur du surligné est pilotée par `--featured-highlight-bg`,
  la couleur du texte au hover/focus par
  `--featured-text-on-highlight`. Les deux tokens changent en fonction
  de la surface (default / scrolled / light).
- La révélation se fait par `clip-path: inset(0 100% 0 0)` →
  `clip-path: inset(0 0 0 0)`, avec `transition: clip-path
  var(--duration-base) var(--ease-out)`. Lorsque le pointeur quitte
  l'élément ou que le focus disparaît, le surligné retombe dans son
  état masqué.
- Sous `@media (prefers-reduced-motion: reduce)`, la transition du
  pseudo-élément est annulée (`transition: none`) et le surligné reste
  masqué. Les tokens de durée étant déjà réduits à `0ms`, aucune
  animation ne persiste.

#### Accessibilité

- La hit-area verticale du lien reste ≥ 44 px héritée de
  `.site-header__link` (`min-height: 44px`).
- L'outline `:focus-visible` de 2 px
  (`outline: 2px solid var(--color-flag-red)`) est préservée sur le
  lien featured.
- Aucune information n'est véhiculée par la couleur seule : le texte
  reste lisible même sans surligné.

---

## 4. Les trois règles d'or

Tout composant, toute contribution, toute revue PR se juge sur ces trois
critères. Si l'un manque, on retravaille.

1. **Intentionnalité** — chaque élément a une raison d'être là. Si on
   ne peut pas dire laquelle en une phrase, on l'enlève. Le décoratif pur
   est interdit.

2. **Imperfection** — on assume l'aspérité : coins durs, contrastes
   francs, hiérarchies sans nuance, listes non arrondies. Mieux vaut une
   page honnête et rude qu'une page léchée et oubliable.

3. **Caractère** — le site doit avoir une voix. Pas une voix de chatbot,
   pas une voix d'ONG corporate — **une voix de collectif** : directe,
   solidaire, sans complaisance, sans condescendance.

---

## 5. Ancrage contextuel

Urgence Palestine n'est pas né d'un brief marketing. Le design s'ancre dans
deux héritages qu'on prolonge, pas qu'on remplace.

### 5.1 Héritage historique — `urgence-palestine.com`

L'ancien site s'adressait à un public déjà convaincu, avec une
iconographie militante assumée (keffieh, olive, dôme de Jérusalem,
carte de la Palestine). On **garde** cette imagerie symbolique comme
vocabulaire récurrent — les fichiers existent dans
[`static/symbols/`](static/symbols/) :

- keffieh (`keffiyeh_-_ancala_nusantara.png`)
- branche d'olivier (`olive_branch_-_ccnisa.png`)
- dôme du Rocher (`35374425-dome-rocher-jerusalem-aquarelle.jpg`)
- cartes de la Palestine
- grenade (symbole local)
- main de la victoire
- lance-pierre
- triangle rouge (mouvement mondial)
- fleur rouge

Ces images sont traitées en **accents décoratifs** (32–64 px), jamais en
illustrations pleine page.

### 5.2 Héritage campagne — `urgence-palestine-campagne.my.canva.site`

La version campagne avait déjà mis en place :

- une **bande tricolore drapeau** en pied ou sommet de sections
  (noir / blanc / vert / rouge) — c'est devenu notre composant
  `flag-stripe` ;
- des **CTA à fond rouge plein, bord droit**, en majuscules grasses ;
- un ton direct, des CTA type « je m'engage », « je crée un collectif ».

Ces choix sont **conservés** et durcis (voir composant
[`flag-stripe`](src/styles/sections.css), variantes CTA documentées dans
[`src/styles/CTA.md`](src/styles/CTA.md)).

### 5.3 Traduction opérationnelle

Concrètement, l'ancrage politique se traduit par :

- **Pas de ton corporate** dans les microcopies (« Bonjour ! »,
  « Découvrez notre solution », « Merci pour votre patience »). On
  parle comme on parle à un comité de soutien.
- **CTA explicites, jamais neutres** : « Agir maintenant », « Faire un
  don », « Je m'engage », « Lire les communiqués ». Pas de
  « En savoir plus » mou.
- **Pas de témoignage client, pas de bandeau de logos partenaires**.
  On cite nos collectifs et nos alliés quand c'est utile, sans les
  exhiber comme des références commerciales.
- **Accessibilité rigoureuse** (WCAG 2.1 AA) : on ne met pas en danger
  des militant·es en situation de handicap. Contrastes ≥ 4.5:1, hit
  area ≥ 44×44 px, focus visible, prefers-reduced-motion respecté.

---

## 6. Garde-fous et processus

- **Tout nouveau composant** doit consommer **exclusivement** les tokens
  documentés dans [`src/styles/tokens.css`](src/styles/tokens.css).
  Aucune valeur de couleur, de font-family ou de radius ne doit être
  hard-codée hors de `tokens.css` et `global.css`.
- **Toute PR de design** doit citer ce `DESIGN.md` dans sa description et
  expliquer, même brièvement, où se situent les choix par rapport aux
  interdits de la section 2 et aux trois règles d'or de la section 4.
- **Le ton éditorial** des contenus rédigés (communiqués, newsletter,
  pages « agir ») est revu par le comité de rédaction du collectif — pas
  par la génération automatique.

---

## Voir aussi

- [`src/styles/tokens.css`](src/styles/tokens.css) — source unique des
  valeurs de design (couleurs, type, espacement, motion).
- [`src/styles/global.css`](src/styles/global.css) — reset, webfonts
  self-hosted, application des tokens au site entier.
- [`src/styles/sections.css`](src/styles/sections.css) — composants
  transverses (hero, pillars, flag-stripe, footer).
- [`src/styles/CTA.md`](src/styles/CTA.md) — charter des deux variantes
  de CTA (Variant A cliquable, Variant B non-cliquable).
