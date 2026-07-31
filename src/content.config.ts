import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

/**
 * Astro 5 content collections.
 *
 * Mirrors the collections declared in `sveltia-cms.config.yml` at the
 * repository root, so the same Markdown files authored through the Sveltia
 * admin UI (under `src/content/<collection>/`) can be read with
 * `getCollection()` from pages and components.
 *
 * The Zod field names below match the Sveltia `fields` schema 1:1, including
 * optional ones — keep them in sync if a collection is extended.
 *
 * @see https://docs.astro.build/en/guides/content-collections/
 */

/** A short, non-empty string. */
const requiredString = z.string().min(1);

/** An optional, possibly-empty string. */
const optionalString = z.string().optional();

/** An optional ISO-8601 date string. */
const optionalDate = z.coerce.date().optional();

/** An optional URL — must look like `http(s)://…` when present. */
const optionalUrl = z.string().url().optional();

/** A relative or absolute path to a static asset (e.g. `/collectif/foo.png`). */
const optionalImagePath = z
	.string()
	.regex(/^\//, { message: "image must start with '/' (static asset path)" })
	.optional();

/** Either "section-locale" (per-city chapter) or "mobilisation-etudiante". */
const entryKind = z.enum(["section-locale", "mobilisation-etudiante"]);

// =============================================================================
// Prises de parole (anciennement « communiqués »)
// =============================================================================
//
// Single bucket that mixes three textual flavours of the collectif's
// public voice:
//
//   - `communique`            → communiqué de presse (default);
//   - `analyse`               → analyse politique signée (par un·e
//                                membre ou un·e contributeur·ice
//                                externe, ex. Ramy Shaath);
//   - `appel-a-mobilisation`  → appel à rassemblement / mobilisation
//                                publique lié à un événement.
//
// The `category` field is optional with a default of `communique` so
// older entries that pre-date the taxonomy keep validating unchanged.
// The matching Sveltia block in `sveltia-cms.config.yml` lists the
// same three options — keep them in sync.
const priseCategory = z.enum([
	"communique",
	"analyse",
	"appel-a-mobilisation",
]);

const prisesDeParole = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/prises-de-parole" }),
	schema: z.object({
		title: requiredString,
		date: z.coerce.date(),
		description: optionalString,
		// Editorial taxonomy — defaults to "communique" for legacy
		// entries that pre-date the field. The home page and the
		// takes-de-parole index render a coloured badge derived from
		// this enum (see `categoryLabel`).
		category: priseCategory.default("communique"),
	}),
});

// =============================================================================
// Collectif — sections locales (per-city chapters) + mobilisation étudiante
// =============================================================================
//
// One content collection to hold both flavours of "Collectif" entry that
// the legacy WordPress site exposed under a single taxonomy:
//
//   - "section-locale"          → per-city local chapter (Marseille, Lyon, …)
//   - "mobilisation-etudiante"  → student-mobilisation hub page
//
// The `city` field is the stable identifier for city chapters; for the
// student-mobilisation hub we synthesise it as "Étudiants" so the schema
// stays uniform and `getCollection("collectif")` returns a homogeneous
// list. The optional `kind` discriminator lets the index page split the
// list into the two tabs seen in the legacy UI.
//
// Frontmatter fields match the Sveltia `fields` schema for the
// `sections-locales` collection (the only one the CMS currently manages);
// `image` is added here so entries can carry a hero/photo asset.
const collectif = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/collectif" }),
	schema: z.object({
		// `city` is the required identifier (slug source in Sveltia). For
		// mobilisation étudiante the value is the literal "Étudiants".
		city: requiredString,
		title: optionalString,
		contact_email: z.string().email().optional(),
		description: optionalString,
		// Optional hero/photo asset path, served from `static/`. The path
		// must be root-relative so Astro's `getImage()` / `<Image>` helpers
		// can resolve it.
		image: optionalImagePath,
		// Legacy contact links preserved as plain URLs. They render in the
		// detail page and help build the inventory file.
		instagram: optionalUrl,
		telegram: optionalUrl,
		twitter: optionalUrl,
		facebook: optionalUrl,
		website: optionalUrl,
		// Internal discriminator — defaults to "section-locale" because
		// every per-city file in `src/content/collectif/` is a city chapter.
		kind: entryKind.default("section-locale"),
		// We allow `date` for future use, even if not in the Sveltia schema.
		date: optionalDate,
	}),
});

// =============================================================================
// Événements / Mobilisation
// =============================================================================
//
// The Mobilisation bucket now mixes two shapes:
//
//   1. **Time-bound events** (rassemblements, marches, actions on a date and
//      at a specific place). `date` and `location` are required.
//
//   2. **Campaign landing pages** migrated from the legacy
//      `urgence-palestine.com` site, scoped to one of three categories:
//
//        - `kit-militant` — the militant kit (affiches, tracts, stickers,
//          pancartes), sourced from the legacy Google Drive folder;
//        - `boycott`      — the boycott campaign landing page (visuels,
//          flyers, downloadable tracts);
//        - `prisonniers`  — the prisonnier·es landing page and the
//          communiqués/actions that support Palestinian prisoners.
//
//      Campaign entries still need a `date` (the legacy page's last-modified
//      date, or the action date for a communiqué) and a `location` (an
//      explicit "En ligne" / "National" marker is fine for pages that have
//      no single physical venue). `category` is optional in the schema so
//      that ad-hoc events (rassemblements without a campaign grouping)
//      stay valid; campaign entries should always set it so the
//      `/mobilisation/` index can group them under the right heading.
//
// Mirrors the matching `mobilisation` collection block in
// `sveltia-cms.config.yml`.
const mobilisationCategory = z.enum([
	"kit-militant",
	"boycott",
	"prisonniers",
]);

const mobilisation = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/mobilisation" }),
	schema: z.object({
		title: requiredString,
		date: z.coerce.date(),
		location: requiredString,
		description: optionalString,
		// Local path under /public/, e.g. `/mobilisation/boycott/2025-visuel-boycott.png`.
		// Used by the /mobilisation index page as the card thumbnail. Optional,
		// but recommended for campaign entries so the index isn't text-only.
		featured_image: optionalString,
		// Optional category — defaults to `evenement` so existing entries
		// that omit it keep validating unchanged.
		category: z
			.enum(["evenement", "kit-militant", "boycott", "prisonniers"])
			.default("evenement"),
	}),
});

export const collections = {
	prisesDeParole,
	collectif,
	mobilisation,
};
