import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

/**
 * Astro 5 content collections.
 *
 * Mirrors the three collections declared in `sveltia-cms.config.yml` at the
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

// =============================================================================
// Communiqués / Prises de parole
// =============================================================================
const communiques = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/communiques" }),
	schema: z.object({
		title: requiredString,
		date: z.coerce.date(),
		description: optionalString,
	}),
});

// =============================================================================
// Collectif (Sections locales)
// =============================================================================
const collectif = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/collectif" }),
	schema: z.object({
		// `city` doubles as the entry identifier (slug source) in Sveltia.
		city: requiredString,
		title: optionalString,
		contact_email: z.string().email().optional(),
		description: optionalString,
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
	communiques,
	collectif,
	mobilisation,
};
