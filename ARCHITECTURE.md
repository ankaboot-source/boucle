# ARCHITECTURE.md

> Documentation technique du projet **urgence-palestine.fr** — site statique
> Astro 5 du Collectif Urgence Palestine. Ce fichier décrit l'architecture
> générale, les collections de contenu, les composants, le flux de données,
> les dépendances et les patterns réutilisables. Il est fondé sur la lecture
> exhaustive des fichiers sous `src/`, des configs racines et des scripts.

---

## 1. Architecture générale et choix techniques

### 1.1 Stack

Le projet est un **site statique** généré par **Astro 5.6+** (SSG), sans
framework UI de rendu côté client (pas de React/Vue/Svelte pour le contenu).
Le HTML est produit à la build-time ; le peu de JavaScript est écrit
« à la main » dans des balises `<script>` des composants Astro (vanilla
TypeScript, IIFE), bundlé et typé par Astro.

**Configuration clé** (`astro.config.mjs`) :

```js
export default defineConfig({
  outDir: 'public',          // le build écrase le dossier ./public
  publicDir: 'static',       // assets statiques servis depuis ./static
  i18n: {
    defaultLocale: 'fr',
    locales: ['fr'],
    routing: { prefixDefaultLocale: false }, // /fr/ non préfixé
  },
  integrations: [tailwind()],
});
```

- `outDir: 'public'` — la sortie du build Astro va dans `public/` (qui
  contient déjà le build courant, servant de preview).
- `publicDir: 'static'` — les assets bruts (polices, images, favicon,
  `admin/`, `symbols/`, `media/`, symlink `sveltia-cms.config.yml`) vivent
  dans `static/` et sont copiés tels quels à la racine du site déployé.
- **i18n** mono-locale `fr`, sans préfixe → les URLs sont `/`, `/collectif/`,
  `/prises-de-parole/`, etc.
- **Tailwind CSS 3** est intégré via `@astrojs/tailwind` ; les layers
  `@tailwind base/components/utilities` sont injectés dans
  `src/styles/global.css`.

### 1.2 Système de design

Le design system repose sur **deux sources de tokens synchronisées** :

1. **`src/styles/tokens.css`** — source de vérité canonique, en **OKLCH**.
   Définit surfaces (ink/paper), palette du drapeau palestinien
   (`--color-flag-red/green/white/black` + variantes `-deep`), tokens
   sémantiques (`--color-text`, `--color-accent`, `--color-link`…), échelle
   typographique fluide (`clamp()` sur `--text-xs`…`--text-display`),
   familles `--font-heading` (The Bold Font) et `--font-body` (Poppins),
   grille d'espacement 8pt fluide (`--space-3xs`…`--space-3xl`), rayons,
   ombres, easing (`--ease-out`), durées (`--duration-fast/base/slow`) et
   **désactivation automatique du motion** via
   `@media (prefers-reduced-motion: reduce)`.

2. **`tailwind.config.mjs`** — expose les mêmes couleurs et familles en
   hex sRGB pour les utilitaires Tailwind (`bg-palestine-red`,
   `font-display`, etc.). Le commentaire du fichier précise que les valeurs
   sont « kept in sync with the OKLCH tokens ».

**Charte CTA** (`src/styles/CTA.md`) : deux variantes canoniques —
**A** (clic, bloc rouge unique, `--radius-sharp`) et **B** (non-clic, deux
blocs empilés vert + rouge). `GeneralCTA.astro` implémente la variante B.

**Feuilles globales** chargées par `Layout.astro` :
- `src/styles/global.css` → `@import "./tokens.css"` + layers Tailwind +
  `@font-face` (The Bold Font, Poppins 400/500/600/700, self-hostés sous
  `/fonts/`) + reset + typographie site-wide (h1…h6, `.display`, `.eyebrow`,
  `.container`).
- `src/styles/sections.css` → styles de sections (`.hero`, `.btn`,
  `.btn--primary`, `.btn--ghost`, `.flag-stripe`, `.section-head`,
  `.pillars`, `.symbol-card`, `.site-footer`, `.newsletter-section`).

### 1.3 CMS Headless : Sveltia CMS

L'édition de contenu est déléguée à **Sveltia CMS** (fork léger de
Decap/Netlify CMS), chargé côté client depuis un CDN :

- `public/admin/index.html` — SPA d'admin minimale : `<link
  rel="cms-config-url" href="/sveltia-cms.config.yml">` +
  `<script src="https://unpkg.com/@sveltia/cms/dist/sveltia-cms.js">`.
  `noindex,nofollow`.
- `sveltia-cms.config.yml` (racine) — **configuration canonique** du CMS,
  exposée à `/sveltia-cms.config.yml` via le symlink
  `static/sveltia-cms.config.yml -> ../sveltia-cms.config.yml`.
- Backend `test-repo` (dev), `media_folder: /static/media`,
  `public_folder: /media`.

### 1.4 Build, scripts et tooling

`package.json` (type: module) — scripts :

| Script | Rôle |
| --- | --- |
| `dev` | `astro dev` — serveur de dev |
| `build` | `astro build` — génère `public/` |
| `preview` | `astro preview` |
| `build:symbols` | `node scripts/build-symbols.mjs` — génère les 9 PNG de symboles via `sharp` (SVG → PNG 512×512 avec filtre « wobble » main levée) |
| `migrate` | `node scripts/migrate.mjs` — migration WordPress → collections Astro (REST API, Turndown, ré-hébergement d'images) |
| `verify:migration` | `node scripts/verify-migration.mjs` — contrôle post-migration |

`tsconfig.json` — `extends: "astro/tsconfigs/strict"`, inclut
`.astro/types.d.ts`.

Dépendances : `astro`, `@astrojs/tailwind`, `tailwindcss`.
DevDeps : `@astrojs/check`, `typescript`, `turndown` (HTML→Markdown pour la
migration). `sharp` est utilisé par `build-symbols.mjs` (transitif via
Astro).

---

## 2. Collections de contenu et schémas Zod

### 2.1 Configuration — `src/content.config.ts`

Trois collections déclarées avec le loader **`glob()`** d'Astro 5
(`pattern: "**/*.md"` + `base: "./src/content/<name>"`). Les schémas Zod
sont **miroir 1:1** des `fields` Sveltia de `sveltia-cms.config.yml`.

Helpers Zod réutilisables (haut du fichier) :

```ts
const requiredString = z.string().min(1);
const optionalString = z.string().optional();
const optionalDate = z.coerce.date().optional();
const optionalUrl = z.string().url().optional();
const optionalImagePath = z.string()
  .regex(/^\//, { message: "image must start with '/' (static asset path)" })
  .optional();
const entryKind = z.enum(["section-locale", "mobilisation-etudiante"]);
```

### 2.2 Collection `communiques` — Prises de parole

- **Dossier** : `src/content/communiques/` (39 fichiers
  `YYYY-MM-DD-<slug>.md`, de 2023-10-28 à 2026-04-15).
- **Sveltia** : `name: communiques`, `slug: "{{year}}-{{month}}-{{slug}}"`,
  champs `title`, `date` (datetime), `description` (text, optionnel),
  `body` (markdown).
- **Schéma Zod** :
  ```ts
  { title: requiredString, date: z.coerce.date(), description: optionalString }
  ```
- Le `body` Markdown n'est pas dans le schéma (Astro l'expose via
  `entry.body` / `render(entry)`).

Exemple de frontmatter (`2025-01-16-cessez-le-feu-a-gaza.md`) :
```yaml
title: "Cessez-le-feu à Gaza"
date: 2025-01-16
description: "Une victoire pour le peuple palestinien…"
```
Le corps commence par `![Featured image](/communiques/.../…jpeg)` — image
ré-hébergée sous `static/communiques/<slug>/`.

### 2.3 Collection `collectif` — Sections locales + mobilisation étudiante

- **Dossier** : `src/content/collectif/` (28 fichiers : 27 villes +
  `mobilisation-etudiante.md`).
- **Sveltia** : `name: collectif`, `identifier_field: city`,
  `slug: "{{slug}}"`, discriminateur `kind` (select :
  `section-locale` | `mobilisation-etudiante`, défaut `section-locale`).
- **Schéma Zod** :
  ```ts
  {
    city: requiredString,                 // "Paris" ou "Étudiants"
    title: optionalString,
    contact_email: z.string().email().optional(),
    description: optionalString,
    image: optionalImagePath,             // ex. "/collectif/...png"
    instagram: optionalUrl,
    telegram: optionalUrl,
    twitter: optionalUrl,
    facebook: optionalUrl,
    website: optionalUrl,
    kind: entryKind.default("section-locale"),
    date: optionalDate,                   // pas dans Sveltia, réservé
  }
  ```
- **Rationale** (commentaire) : une seule collection homogène pour les deux
  « saveurs » du Collectif héritées de WordPress ; `city` est l'identifiant
  stable, `kind` permet à la page d'index de splitter en deux onglets. Pour
  la mobilisation étudiante, `city` vaut `"Étudiants"`.

Exemple (`paris.md`) : `title`, `city`, `description` + corps Markdown avec
coordonnées. Exemple étudiant (`mobilisation-etudiante.md`) :
`city: "Étudiants"`, `kind: "mobilisation-etudiante"`,
`image: "/collectif/collectif-urgence-palestine.png"`.

### 2.4 Collection `mobilisation` — Événements & campagnes

- **Dossier** : `src/content/mobilisation/` (5 fichiers : 3 campagnes
  `kit-militant`/`boycott`/`prisonniers` + 2 événements).
- **Sveltia** : `name: mobilisation`, `slug: "{{year}}-{{month}}-{{slug}}"`,
  champs `title`, `date`, `location`, `description`, `featured_image`
  (image, optionnel), `category` (select : `evenement` | `kit-militant` |
  `boycott` | `prisonniers`, défaut `evenement`), `body`.
- **Schéma Zod** :
  ```ts
  {
    title: requiredString,
    date: z.coerce.date(),
    location: requiredString,             // ex. "En ligne — national"
    description: optionalString,
    featured_image: optionalString,       // ex. "/mobilisation/kit-militant/affiche.jpg"
    category: z.enum(["evenement","kit-militant","boycott","prisonniers"])
                 .default("evenement"),
  }
  ```
- **Rationale** : mélange deux formes — (1) événements datés
  (rassemblements) et (2) landing pages de campagnes migrées depuis
  `urgence-palestine.com`. `category` optionnel pour garder valides les
  événements ad-hoc sans regroupement.

Exemple (`2025-05-kit-militant.md`) : `category: kit-militant`,
`featured_image: "/mobilisation/kit-militant/affiche.jpg"`, corps avec
listes de liens PDF/JPG vers `/mobilisation/kit-militant/...`.

### 2.5 Export

```ts
export const collections = { communiques, collectif, mobilisation };
```

---

## 3. Composants Astro et responsabilités

Tous les composants sont dans `src/components/`. Aucun n'utilise de
framework UI ; le JS client est vanilla, typé, encapsulé en IIFE et
déclaré dans des `<script>` Astro.

### 3.1 Chrome global

| Composant | Fichier | Responsabilité |
| --- | --- | --- |
| **Layout** | `src/layouts/Layout.astro` | Layout racine. Importe `global.css` + `sections.css`, rend `<Header/>`, `<slot/>`, `<slot name="modal"/>`, `<Footer/>`. Props `title?`, `description?` (défauts « Urgence Palestine »). `<head>` : meta, `theme-color`, **preload** des polices critiques (`the-bold-font.woff2`, `poppins-400.woff2`), favicon SVG. Le slot `modal` permet aux pages d'injecter `NewsletterModal`. |
| **Header** | `src/components/Header.astro` | Barre supérieure sticky, fond noir (`--color-flag-black`), wordmark + nav 4 liens (`Prises de parole` `/prises-de-parole`, `Collectif` `/collectif`, `Faites un don` `/don`, `Mobilisation` `/mobilisation`). Hover accent rouge. Responsive empilé sous 40rem. |
| **Footer** | `src/components/Footer.astro` | Pied de page actif (utilisé par `Layout`). Brand block, liens, `<NewsletterSignup variant="inline">`, réseaux sociaux, **email obfusqué** : fragments `["contact","urgence-palestine"]` / `["fr"]` passés en `data-*`, réassemblés en `mailto:` par un `<script>` IIFE pour échapper aux scrapers. Fallback `<noscript>` vers `/contact`. |
| **SiteFooter** | `src/components/SiteFooter.astro` | Variante alternative de footer (flag-stripe + `NewsletterSignup variant="footer"`). Présent mais **non référencé** par `Layout.astro` (qui utilise `Footer`). |

### 3.2 CTA

| Composant | Fichier | Responsabilité |
| --- | --- | --- |
| **DonationCTA** | `src/components/DonationCTA.astro` | Bloc don homepage. Sans props. Fond `--color-flag-red` + dégradé diagonal (green-deep → black), titre + lede + bouton « Faire un don » vers `https://donorbox.org/soutenir-up`. |
| **GeneralCTA** | `src/components/GeneralCTA.astro` | **Variante B de la charte CTA** (non-clic). Props `title` (requis), `ctaLabel` (requis), `eyebrow?`, `tone?: "green-then-red"` (réservé). Deux stripes empilés : vert (titre) + rouge (label). Aucun `<a>`, aucun JS. `aria-labelledby="general-cta-title"`. |

### 3.3 Newsletter & engagement

| Composant | Fichier | Responsabilité |
| --- | --- | --- |
| **NewsletterSignup** | `src/components/NewsletterSignup.astro` | Formulaire newsletter réutilisable. Props : `id?` (défaut `newsletter-signup`), `variant?: "inline" \| "block" \| "stacked" \| "footer"` (`stacked` normalisé en `block`), `heading?`, `description?`, `buttonLabel?`, `labelledBy?`. `<form data-newsletter>` avec input email + submit + régions success/error (`role=status`/`role=alert`, `aria-live`). **Script client** : valide (`checkValidity`), simule POST (350ms), marque `sessionStorage["up-newsletter-subscribed"]="1"`, cache le formulaire, affiche le succès, dispatche `CustomEvent("up:newsletter:subscribed")`. Au load, si déjà inscrit → affiche directement le succès. |
| **NewsletterModal** | `src/components/NewsletterModal.astro` | `<dialog data-newsletter-modal>` natif. Props : `delayMs?` (défaut 30000), `heading?`, `description?`, `buttonLabel?`. **Tracker d'inactivité** : ouvre après `delayMs` sans activity (click/scroll/keydown) ; toute activité annule et détache les listeners. Clôture par bouton ×, « Non merci », Escape, clic backdrop, ou succès. `sessionStorage["up-newsletter-modal-dismissed"]` + `["up-newsletter-subscribed"]` suppriment la réapparition. Écoute `up:newsletter:subscribed` pour se fermer. Embedde `<NewsletterSignup variant="block" heading="" description="" labelledBy=…>` (pas de `<form method="dialog">` pour éviter le nesting de forms). Animations `@keyframes nl-modal-in` / `nl-backdrop-in`, réduites sous `prefers-reduced-motion`. |
| **EngagementForm** | `src/components/EngagementForm.astro` | Formulaire 4 champs (`name`, `email`, `city`, `message`, tous requis). Props `formId?` (défaut `engagement-form`). `novalidate` + validation client : `validateField` par champ (longueurs min, `checkValidity` email, message ≥ 10), focus sur 1er invalide, bouton « Envoi en cours… », simule POST 500ms, remplace le form par une carte de succès reprenant nom + ville (`data-engagement-success-name/city`), `scrollIntoView`, dispatche `up:engagement:submitted`. |
| **EngagementPage** | `src/components/EngagementPage.astro` | Corps partagé des routes `/engagement` et `/agir`. Props `formId: string` (requis). Hero + 3 bénéfices (01/02/03) + `<EngagementForm formId>` + aside newsletter (`<NewsletterSignup variant="inline">`). Inclut `<NewsletterModal slot="modal">`. |

### 3.4 Communication inter-composants

Les scripts client utilisent trois `CustomEvent` dédiés (sur `document`) :
- `up:newsletter:subscribed` — émis par `NewsletterSignup` ; écouté par
  `NewsletterModal` pour se fermer.
- `up:engagement:submitted` — émis par `EngagementForm`.
- (réservé) `up:newsletter:modal-dismissed` implicite via `dialog.close`.

Clés `sessionStorage` partagées :
- `up-newsletter-subscribed` (NewsletterSignup + NewsletterModal)
- `up-newsletter-modal-dismissed` (NewsletterModal)

---

## 4. Flux de données : collections → composants → pages

### 4.1 Vue d'ensemble

```
src/content/<collection>/*.md
   │  (glob loader, Zod validation)
   ▼
astro:content  →  getCollection("<name>")  /  render(entry)
   │
   ├── pages index   (src/pages/<route>.astro)
   └── pages détail  (src/pages/<route>/[...slug].astro  via getStaticPaths)
```

Les pages consomment les collections exclusivement via
`import { getCollection, render } from "astro:content"`. Aucune logique
métier n'est extraite dans des modules utilitaires — le tri/filtre/groupage
est en ligne dans chaque page.

### 4.2 Route `/` — `src/pages/index.astro`

- Aucune collection. Compose `Layout` + `GeneralCTA` + `DonationCTA` +
  `.flag-stripe` + section `.pillars` (3 piliers) +
  `<NewsletterSignup variant="block">` dans `.newsletter-section` +
  `<NewsletterModal slot="modal">`.
- Hero avec `img src="/symbols/antique-key.webp"` (eager, high priority).

### 4.3 Routes `/engagement` et `/agir`

- `src/pages/engagement.astro` → `<EngagementPage formId="engagement" />`.
- `src/pages/agir.astro` → `<EngagementPage formId="agir" />` (alias pour
  que le CTA hero « Agir maintenant » atterrisse sur une URL cohérente).
- Le `formId` unique évite les collisions d'`id` input/label.

### 4.4 Route `/prises-de-parole` — communiqués

**Index** (`src/pages/prises-de-parole.astro`) :
```ts
const entries = (await getCollection("communiques"))
  .sort((a, b) => b.data.date.getTime() - a.data.date.getTime());
const entrySlug = (e) => e.id.replace(/^\d{4}-\d{2}-\d{2}-/, "");
const firstImage = (e) => (e.body ?? "").match(/!\[.*?\]\((\/[^)\s]+)\)/)?.[1] ?? null;
```
- Tri **du plus récent au plus ancien**.
- Slug = `entry.id` (nom de fichier sans `.md`) **sans le préfixe
  `YYYY-MM-DD-`** pour matcher le slug WordPress legacy.
- **Vignette** : regex sur `entry.body` pour extraire la 1ère image
  Markdown inline (`![…](/…)`) ; placeholder hachuré sinon.
- Carte → lien `/prises-de-parole/<slug>/`. Date formatée
  `Intl.DateTimeFormat("fr-FR", {day,month:"long",year})`.

**Détail** (`src/pages/prises-de-parole/[...slug].astro`) :
```ts
export const getStaticPaths = (async () => {
  const entries = await getCollection("communiques");
  return entries.map((entry) => ({
    params: { slug: entry.id.replace(/^\d{4}-\d{2}-\d{2}-/, "") },
    props: { entry },
  }));
}) satisfies GetStaticPaths;

const { entry } = Astro.props;
const { Content } = await render(entry);
```
- Breadcrumb + header (titre, date `<time datetime=…>`, description) +
  `<Content />` (Markdown rendu, images pointant vers
  `/communiques/<slug>/…`) + footer CTA (newsletter + retour index).

### 4.5 Route `/collectif` — Collectif

**Index** (`src/pages/collectif.astro`) :
```ts
const entries = await getCollection("collectif");
const sections = entries
  .filter((e) => (e.data.kind ?? "section-locale") === "section-locale")
  .sort((a, b) => a.data.city.localeCompare(b.data.city, "fr"));
const mobilisation = entries
  .filter((e) => e.data.kind === "mobilisation-etudiante")
  .sort((a, b) => a.data.city.localeCompare(b.data.city, "fr"));
const mobilisationWithBody = await Promise.all(
  mobilisation.map(async (e) => ({ entry: e, Content: (await render(e)).Content })),
);
```
- **Split par `kind`** en deux groupes ; sections triées alphabétiquement
  par `city` (locale `fr`).
- Cartes sections locales : affichent `city`, `description`, chips de
  canaux (email/Instagram/Telegram/X/Facebook/site web déduits des
  frontmatter booléens) → lien `/collectif/<slug>/`.
- Carte mobilisation étudiante : **pré-rend** le `<Content />` de chaque
  entrée (commentaire : « so the index doesn't need to call `render()` per
  card at request time »), affiche `image`, `title ?? city`, `description`,
  le Markdown, et deux CTA (Linktree annuaire + « Je m'engage »).
- URLs externes centralisées : `CREER_UN_COLLECTIF_URL` (Google Form),
  `JE_MENGAGE_URL` (forms.gle), `MOBILISATION_ETUDIANTE_URL`
  (linktr.ee/etudiant.es) — dupliquées dans la page détail (commentaire
  « kept in sync with the index page »).
- Section `legacy-ctas` : deux images-boutons
  (`/collectif/cta-creer-un-collectif.png`,
  `/collectif/cta-je-mengage.png`) vers les mêmes formulaires.

**Détail** (`src/pages/collectif/[...slug].astro`) :
- `getStaticPaths` depuis `getCollection("collectif")`, `params: { slug:
  entry.id }` (slug = nom de fichier, car Sveltia slugifie `city`).
- Construit un tableau typé `Channel[]` (`{ label, href, icon }`) à partir
  des champs `contact_email` (mailto + icône ✉), `instagram` (◐),
  `telegram` (✈), `twitter` (✕), `facebook` (f), `website` (↗).
- Variante étudiante (`isEtudiante = kind === "mobilisation-etudiante"`) :
  pas de hero image, panneau contact sur fond clair, CTA « Annuaire des
  campus » + « Je m'engage ». Sinon : hero image, panneau contact noir,
  CTA « Créer un collectif ».
- Fallback « Aucun contact public » si `channels.length === 0`.

### 4.6 Route `/mobilisation` — Mobilisation

**Index** (`src/pages/mobilisation.astro`) :
```ts
const entries = (await getCollection("mobilisation"))
  .sort((a, b) => b.data.date.getTime() - a.data.date.getTime());
type GroupKey = "kit-militant" | "boycott" | "prisonniers" | "evenements";
const order: GroupKey[] = ["kit-militant","boycott","prisonniers","evenements"];
// groupage : category "evenement" → group "evenements"
for (const e of entries) {
  const cat = e.data.category ?? "evenement";
  const key = (cat === "evenement" ? "evenements" : cat) as GroupKey;
  grouped[key].push(e);
}
```
- `groupMeta` : label + tagline par groupe ; `sectionIndex(key)` →
  eyebrow « 01 »…« 04 ».
- Cartes : `featured_image` (ou placeholder hachuré), date `<time>`,
  `location`, `title` (lien), `description`, « Voir le détail → ».
- **Slug** : `entry.id.replace(/^\d{4}-\d{2}-/, "")` (strip `YYYY-MM-`,
  contrairement aux communiqués qui strip `YYYY-MM-DD-`).

**Détail** (`src/pages/mobilisation/[...slug].astro`) :
- `getStaticPaths` avec le même strip `YYYY-MM-`.
- `groupLabel` mappe `category` → `{ tag, tagline }` (kit-militant / boycott
  / prisonniers / evenement).
- Header avec tag pill + titre + date + location + description, hero
  `featured_image`, `<Content />`, footer CTA vers `/mobilisation/` et
  `/engagement/`.

### 4.7 Route `/symboles` — `src/pages/symboles.astro`

- Aucune collection. Tableau local `symbols` (9 entrées :
  `antique-key`, `pomegranate`, `olive-oil`, `keffieh`, `sunbird`, `poppy`,
  `al-quds`, `al-aqsa`, `orange`) avec `label` + `caption`.
- Rendu via `<img src="/symbols/${name}.webp">` (PNG/WebP générés par
  `scripts/build-symbols.mjs` — **aucun `<svg>` inline**, critère
  d'acceptation).
- `<NewsletterModal slot="modal">`.

### 4.8 Récapitulatif des stratégies de slug

| Collection | Fichier | Strip pour URL | Route détail |
| --- | --- | --- | --- |
| communiques | `YYYY-MM-DD-<slug>.md` | `YYYY-MM-DD-` | `/prises-de-parole/<slug>/` |
| mobilisation | `YYYY-MM-<slug>.md` | `YYYY-MM-` | `/mobilisation/<slug>/` |
| collectif | `<slug>.md` (slugifié depuis `city`) | aucun | `/collectif/<slug>/` |

---

## 5. Dépendances externes et leur rôle

### 5.1 Runtime (`dependencies`)

| Package | Rôle |
| --- | --- |
| **astro** `^5.6.1` | Framework SSG : routing fichier, content collections (glob loader, `getCollection`/`render`), compilation `.astro`, bundling des `<script>`. |
| **@astrojs/tailwind** `^6.0.2` | Intégration Tailwind : injecte les layers dans `global.css`, génère le CSS utilitaire. |
| **tailwindcss** `^3.4.19` | Moteur Tailwind v3 (config `tailwind.config.mjs`). |

### 5.2 Dev (`devDependencies`)

| Package | Rôle |
| --- | --- |
| **@astrojs/check** `^0.9.10` | Diagnostics Astro (type-check `.astro`). |
| **typescript** `^5.9.3` | Typage des scripts composants et de `content.config.ts`. |
| **turndown** `^7.2.0` | HTML→Markdown pour `scripts/migrate.mjs` (conversion des corps WordPress). |

### 5.3 Dépendances implicites / externes au bundle

- **Sveltia CMS** (`@sveltia/cms`) — chargé depuis `unpkg.com` CDN par
  `public/admin/index.html` (pas dans `package.json`).
- **sharp** — utilisé par `scripts/build-symbols.mjs` (et par Astro en
  interne) pour rastériser les SVG de symboles en PNG 512×512.
- **Donorbox** — `https://donorbox.org/soutenir-up` (CTA don, externe).
- **Google Forms** — `CREER_UN_COLLECTIF_URL`, `JE_MENGAGE_URL` (externes).
- **Linktree** — `https://linktr.ee/etudiant.es` (annuaire étudiant).
- **WordPress REST API** — `https://www.urgence-palestine.com/wp-json/wp/v2`
  (source legacy, utilisée uniquement par `scripts/migrate.mjs`).

### 5.4 Scripts Node

| Fichier | Rôle |
| --- | --- |
| `scripts/build-symbols.mjs` | Génère les 9 PNG de symboles (SVG inline avec filtres `feTurbulence`/`feDisplacementMap` « wobble » + hachure, puis `sharp` → `static/symbols/<name>.png`). |
| `scripts/migrate.mjs` | Migration WordPress → `communiques` : fetch REST API (cat 51/55/54), télécharge les images dans `static/communiques/<slug>/`, convertit HTML→Markdown (Turndown), réécrit les URLs d'images en `/communiques/<slug>/…`, écrit `src/content/communiques/YYYY-MM-DD-<slug>.md`, alimente `migration-inventory.md`. |
| `scripts/verify-migration.mjs` | Vérification post-migration. |
| `scripts/test-admin-mount.cjs` | Test du montage Sveltia CMS. |
| `bin/` (`doctor`, `fetch-issue-images`, `oc`, `setup`) | Outils shell du harness (non liés au runtime Astro). |

---

## 6. Patterns réutilisables identifiés

### 6.1 Pattern « collection → index + détail `[...slug]` »

Toutes les collections content suivent le même squelette :

- **Index** : `getCollection()` → tri/filtre en ligne → `.map()` vers des
  cartes liant `/route/<slug>/`. Slug dérivé de `entry.id` par regex de
  strip. Empty state explicite (`entries.length === 0`).
- **Détail** : `getStaticPaths` (`satisfies GetStaticPaths`) mappe
  `entries` → `{ params: { slug }, props: { entry } }` ; page récupère
  `entry` via `Astro.props`, rend `<Content />` via `await render(entry)`.
- Header avec breadcrumb `← Retour`, eyebrow, titre `<h1>`, date `<time
  datetime={d.date.toISOString()}>` formatée `Intl.DateTimeFormat("fr-FR")`,
  description optionnelle, hero image optionnelle, corps Markdown, footer
  CTA.

### 6.2 Pattern « enveloppe page mince + composant partagé »

`/engagement` et `/agir` sont des one-liners :
```astro
<EngagementPage formId="engagement" />
```
Le composant `EngagementPage` porte tout le contenu et se charge d'inclure
`Layout` + `NewsletterModal`. Le `formId` est l'unique variable, garantissant
l'unicité des `id` HTML.

### 6.3 Pattern « slot modal »

`Layout.astro` expose `<slot name="modal" />` après `<slot />`. Les pages
injectent `<NewsletterModal slot="modal" />` (index, symboles,
EngagementPage) pour que le `<dialog>` soit rendu une seule fois, hors du
`<main>`.

### 6.4 Pattern « vanilla IIFE + CustomEvent + sessionStorage »

Tous les scripts client (NewsletterSignup, NewsletterModal, EngagementForm,
Footer) :
- IIFE défensive (`if (document.readyState === "loading") … else init()`),
- queries scopées par attributs `data-*` (`data-newsletter`,
  `data-engagement-form`, `data-email-user-parts`…),
- communication inter-composants par `CustomEvent` sur `document`
  (`up:newsletter:subscribed`, `up:engagement:submitted`),
- persistance d'état par `sessionStorage` avec `try/catch` (private mode),
- `prefers-reduced-motion` respecté (CSS + court-circuit JS).

### 6.5 Pattern « validation native + feedback ARIA »

Les formulaires combinent : `required` + `type="email"` + `minlength` HTML,
`novalidate` sur le `<form>`, validation JS `input.checkValidity()` /
`validity.valueMissing`, régions de retour `role="alert"` /
`role="status"` avec `aria-live="assertive"` / `"polite"`, focus sur le
1er champ invalide, bouton en état « busy » (`dataset["busy"]="1"`).

### 6.6 Pattern « obfuscation d'email »

`Footer.astro` éclate l'email en fragments `data-email-user-parts` /
`data-email-domain-parts` (JSON), réassemblés à l'exécution ; le schéma
`mailto:` est lui-même reconstruit lettre par lettre
(`["m","a","i","l","t","o",":"].join("")`) pour qu'aucune adresse
contiguë n'apparaisse dans le HTML statique. Fallback `<noscript>`.

### 6.7 Pattern « tokens OKLCH + miroir Tailwind »

Toute couleur/typo vient de `tokens.css` (OKLCH) via `var(--…)` dans le CSS
composant. `tailwind.config.mjs` duplique les valeurs en hex pour les
rares utilitaires Tailwind (`bg-palestine-red`, `font-display` sur le hero
de `index.astro`). `src/styles/CTA.md` documente la charte d'usage des
tokens pour les CTA.

### 6.8 Pattern « assets ré-hébergés, jamais hot-linkés »

- Images communiqués : `static/communiques/<slug>/…` (ré-hébergées par
  `migrate.mjs`), URLs réécrites en `/communiques/<slug>/…` dans le
  Markdown.
- Images mobilisation : `static/mobilisation/<category>/…`,
  `featured_image: "/mobilisation/…"` en frontmatter.
- Images collectif : `static/collectif/…`, `image: "/collectif/…"`.
- Symboles : `static/symbols/<name>.webp` (générés par `build-symbols.mjs`).
- Polices : `static/fonts/*.woff2` (self-hosted, preload dans `Layout`).

### 6.9 Pattern « placeholder hachuré »

Quand une image est absente (`firstImage` null, `featured_image` absent),
les cartes affichent un placeholder CSS
`repeating-linear-gradient(45deg, …)` plutôt que de casser la grille.

### 6.10 Pattern « discriminateur `kind` / `category` »

Une même collection rassemble des entrées de formes différentes, distinguées
par un enum Zod avec `.default(...)` :
- `collectif.kind` → `section-locale` (défaut) | `mobilisation-etudiante`.
- `mobilisation.category` → `evenement` (défaut) | `kit-militant` |
  `boycott` | `prisonniers`.

Les pages d'index filtrent/groupent sur ce champ, et le détail adapte le
rendu (panneau contact clair/sombre, CTA différents).

### 6.11 Pattern « commentaires-docs dans les `.astro` »

Chaque page/composant commence par un bloc commentaire expliquant le
rôle, la route, la stratégie de slug, les dépendances et les choix
(héritage WordPress, pré-rendu `Content`, URLs externes à synchroniser).
`content.config.ts` et `sveltia-cms.config.yml` font de même, se
référençant mutuellement pour garder les schémas alignés.

---

## 7. Cartographie des fichiers

```
.
├── astro.config.mjs              # SSG config (outDir=public, publicDir=static, i18n fr, tailwind)
├── tailwind.config.mjs           # tokens miroir (hex) pour utilitaires
├── sveltia-cms.config.yml        # config CMS canonique (3 collections)
├── tsconfig.json                 # strict Astro
├── package.json                  # astro + tailwind + turndown
├── static/                       # publicDir → copié à la racine
│   ├── admin/index.html          # SPA Sveltia CMS
│   ├── sveltia-cms.config.yml    # symlink → ../sveltia-cms.config.yml
│   ├── fonts/                    # the-bold-font, poppins 400/500/600/700
│   ├── symbols/                  # 9 PNG/WebP (build-symbols.mjs)
│   ├── communiques/              # images ré-hébergées
│   ├── mobilisation/             # images ré-hébergées
│   ├── collectif/                # images + CTA legacy
│   ├── media/                    # media_folder Sveltia
│   └── favicon.svg
├── public/                       # outDir (build courant)
├── scripts/
│   ├── build-symbols.mjs         # SVG → PNG (sharp)
│   ├── migrate.mjs               # WordPress REST → communiques (Turndown)
│   ├── verify-migration.mjs
│   └── test-admin-mount.cjs
└── src/
    ├── content.config.ts         # 3 collections + schémas Zod
    ├── content/
    │   ├── communiques/*.md      # 39 entrées
    │   ├── collectif/*.md        # 28 entrées (villes + étudiants)
    │   └── mobilisation/*.md     # 5 entrées
    ├── layouts/
    │   └── Layout.astro          # <head>, Header, slots, Footer
    ├── components/
    │   ├── Header.astro
    │   ├── Footer.astro          # email obfusqué
    │   ├── SiteFooter.astro      # variante alternative
    │   ├── DonationCTA.astro
    │   ├── GeneralCTA.astro      # CTA variante B (non-clic)
    │   ├── NewsletterSignup.astro
    │   ├── NewsletterModal.astro
    │   ├── EngagementForm.astro
    │   └── EngagementPage.astro
    ├── pages/
    │   ├── index.astro
    │   ├── agir.astro            # alias → EngagementPage formId="agir"
    │   ├── engagement.astro      # → EngagementPage formId="engagement"
    │   ├── symboles.astro
    │   ├── prises-de-parole.astro
    │   ├── prises-de-parole/[...slug].astro
    │   ├── collectif.astro
    │   ├── collectif/[...slug].astro
    │   ├── mobilisation.astro
    │   └── mobilisation/[...slug].astro
    └── styles/
        ├── tokens.css            # design tokens OKLCH (source de vérité)
        ├── global.css            # @import tokens + Tailwind + @font-face + reset
        ├── sections.css          # hero, btn, flag-stripe, pillars, symbols, footer…
        └── CTA.md                # charte des 2 variantes CTA
```

---

## 8. Points d'attention et dette technique observable

- **Footer vs SiteFooter** : `Layout.astro` importe `Footer.astro` ;
  `SiteFooter.astro` (variante avec flag-stripe + `variant="footer"`)
  n'est pas référencé — duplication potentielle à clarifier.
- **Duplication des URLs externes** : `CREER_UN_COLLECTIF_URL`,
  `JE_MENGAGE_URL`, `MOBILISATION_ETUDIANTE_URL` sont redéclarées entre
  `collectif.astro` et `collectif/[...slug].astro` (commentaire
  « kept in sync ») — candidat à l'extraction vers un module
  `src/lib/links.ts`.
- **`featured_image`** de `mobilisation` est `optionalString` (non
  validé comme chemin `/`) contrairement à `collectif.image` qui utilise
  `optionalImagePath` — incohérence mineure entre les deux schémas.
- **`category` Sveltia vs Zod** : Sveltia déclare 4 options dont
  `evenement` (défaut), Zod aussi ; cohérent, mais l'index doit mapper
  `evenement` → groupe `evenements` (pluralisation ad hoc).
- **`/don`** : le `Header` lien « Faites un don » pointe vers `/don` qui
  n'a pas de page dédiée (le don réel va vers Donorbox via
  `DonationCTA`) — route potentiellement manquante.
- **`AGENTS.md`** impose un workflow *upstream-first* (boucle) pour les
  bugs et un commit obligatoire après tout travail.