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
// Sections locales (Collectif)
// =============================================================================
const sectionsLocales = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/sections-locales" }),
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
const mobilisation = defineCollection({
	loader: glob({ pattern: "**/*.md", base: "./src/content/mobilisation" }),
	schema: z.object({
		title: requiredString,
		date: z.coerce.date(),
		location: requiredString,
		description: optionalString,
	}),
});

export const collections = {
	communiques,
	"sections-locales": sectionsLocales,
	mobilisation,
};
