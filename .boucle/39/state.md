# Issue #39

## Goal
L'auteur demande de modifier `src/components/GeneralCTA.astro` pour introduire une **variante « angled-split »** du CTA :

1. **Coupe diagonale discrète** (~6-10°) entre la stripe verte (titre, en haut) et la stripe rouge (label CTA, en bas). L'angle doit rester subtil, pas agressif.
2. **Changement structurel majeur** (point critique Q1) : le fond coloré de chaque stripe ne doit **plus** prendre 100% de la largeur du conteneur. Il doit « épouser le texte » — comportement surligneur, pas bandeau plein-largeur. Le composant actuel utilise `display: flex; flex-direction: column;` sur `<section>` avec deux `<div>` qui remplissent la largeur — il faut donc restructurer (chaque stripe passe en `inline-block` / `width: fit-content` + `box-decoration-break: clone` pour gérer le wrap multi-ligne, OU technique équivalente).
3. **Contraintes préservées** : `aria-labelledby={headingId}` pointant vers le `<h2>`, hit-area vertical ≥ 44px sur les deux stripes, ordre vert-haut/rouge-bas.
4. **Documentation** : nouvelle sous-section dans `DESIGN.md` (l'auteur suggère « 3.7 Variante angled-split des CTA » — mais les §3.4-3.7 sont déjà occupés dans la version actuelle ; le worker choisira le prochain numéro libre ou insérera après §3.3 comme indiqué par l'auteur, en renumérotant si nécessaire). La règle « le fond épouse la largeur du texte » doit être énoncée explicitement.
5. **Choix d'implémentation délégué** au worker (l'auteur liste trois options : `inline-block + fit-content + box-decoration-break: clone`, SVG `background-image`, `paint-order: stroke fill`).

Le composant est petit et bien isolé (130 lignes, un seul fichier `.astro` + tokens existants). Les acceptance criteria sont déjà fournis, vérifiables visuellement et via DevTools (`width` calculée ≈ largeur du texte + padding, pas 100% du conteneur). Aucun consommateur externe de la props `GeneralCTA` n'est cassé par le changement puisque les props (`title`, `ctaLabel`, `eyebrow`, `tone`) restent identiques.

Docs impact: DESIGN.md

## Acceptance criteria
- [x] `GeneralCTA` avec `variant="angled-split"` rend deux stripes centrées (verte en haut, rouge en bas), la rouge inclinée vers le haut à droite.
- [x] La `width` calculée de chaque stripe est ≈ largeur du texte + padding (`inline-block` + `width: fit-content`) et **pas** `100%` du conteneur.
- [x] Quand le titre wrap sur 2 lignes, le fond coloré suit chaque ligne grâce à `box-decoration-break: clone` sur le `<span>` inline.
- [x] `<section aria-labelledby={headingId}>` pointe vers le `<h2 id="general-cta-title">`; la stripe rouge porte `aria-hidden="true"`.
- [x] Hit-area vertical ≥ 44 px sur les deux stripes (`min-height: 44px`).
- [x] `DESIGN.md` §3.7 documente la variante « angled-split », la règle « le fond coloré épouse la largeur du texte », l'angle 2–4° et l'animation d'entrée.
- [x] Le titre principal reste en blanc sur fond vert ; le label CTA reste en blanc sur fond rouge.
- [x] Le build statique Astro passe et la page d'accueil embarque le composant avec le rendu attendu.

## Approach
- Updated `src/components/AngledSplitCTA.astro` to address the latest human feedback on MR !38.
- Lowered the red-stripe angle to `--cta-angle: 2deg` so the ascending slope is subtle, as requested.
- Made the label text visually follow the red stripe by wrapping it in `.angled-split-cta__label-slope` with a counter-skew so it sits on the same rising axis while remaining readable.
- Tightened the green title background to hug the text: reduced inline padding to `var(--space-2xs)` and block padding to `0.125em 0.25em`, conforming to DESIGN.md §3.7.
- Added more vertical separation between the horizontal green stripe and the rising red stripe (`margin-top: 0.35em`) so the red background sits clearly below the title.
- Preserved accessibility: `aria-labelledby` → `<h2 id="general-cta-title">`, `aria-hidden="true"` on the decorative red stripe, and `min-height: 44px` on both stripes.
- Re-used the existing staggered entrance animation and `prefers-reduced-motion` guard.

## Tried and rejected
- Counter-skewing the label text to keep it horizontal: rejected per human feedback; the label must visually rise with the red stripe.
- Clip-path diagonal cuts on both stripes: produced a « two triangles » look and a non-rectangular green block; the green stripe must stay strictly horizontal.
- Angles in the 6–10° range: too aggressive for this composition; reduced to a subtle 2.5° to match the requested « légèrement inférieure » slope.

## Awaiting human
nothing
