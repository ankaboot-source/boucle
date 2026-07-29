import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

/*
 * Astro content collections for Urgence Palestine.
 *
 * Mirrors the three collections declared in sveltia-cms.config.yml so
 * that content authored by editors in /admin/ — which writes Markdown
 * files with YAML frontmatter into src/content/<name>/ — is consumable
 * by Astro pages via `getCollection()`.
 *
 * Field names match the Sveltia config 1:1; that is the contract that
 * keeps the two sides in agreement.
 */

const communiques = defineCollection({
	loader: glob({ base: "./src/content/communiques", pattern: "**/*.md" }),
	schema: z.object({
		title: z.string(),
		date: z.coerce.date(),
		description: z.string().optional(),
		body: z.string().optional(),
	}),
});

const sectionsLocales = defineCollection({
	loader: glob({ base: "./src/content/sections-locales", pattern: "**/*.md" }),
	schema: z.object({
		title: z.string(),
		city: z.string(),
		description: z.string().optional(),
		body: z.string().optional(),
	}),
});

const mobilisation = defineCollection({
	loader: glob({ base: "./src/content/mobilisation", pattern: "**/*.md" }),
	schema: z.object({
		title: z.string(),
		date: z.coerce.date(),
		location: z.string(),
		description: z.string().optional(),
		body: z.string().optional(),
	}),
});

export const collections = {
	communiques,
	"sections-locales": sectionsLocales,
	mobilisation,
};
