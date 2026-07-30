#!/usr/bin/env node
// Migrate "Prises de parole" entries from the legacy WordPress site
// (urgence-palestine.com) into the Astro `communiques` content collection.
//
// For every entry in the "Communiqués" + "Analyses politiques" categories
// (plus two unique "Communiqué" entries that live only in the singular
// `communique` category), this script:
//   1. fetches the post metadata + body via the WordPress REST API,
//   2. downloads every image (featured + in-body) into
//      `static/communiques/<slug>/`,
//   3. converts the body HTML to Markdown, rewriting image URLs to local
//      paths beginning with `/communiques/<slug>/…`,
//   4. emits `src/content/communiques/YYYY-MM-DD-<slug>.md` with
//      frontmatter matching the `communiques` Zod schema,
//   5. appends a line to `migration-inventory.md` mapping the legacy URL
//      to the new file path.

import { mkdir, writeFile, unlink, readFile, readdir, stat } from "node:fs/promises";
import { existsSync, createWriteStream } from "node:fs";
import { dirname, join, basename, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import TurndownService from "turndown";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const STATIC_BASE = join(ROOT, "static", "communiques");
const CONTENT_BASE = join(ROOT, "src", "content", "communiques");
const INVENTORY = join(ROOT, "migration-inventory.md");

const API = "https://www.urgence-palestine.com/wp-json/wp/v2";

// Categories on the legacy site that make up "Prises de parole".
// 51 = Communiqués, 55 = Analyses politiques, 54 = Communiqué (singular).
// We fetch all three and dedupe by post id.
const CATEGORY_IDS = [51, 55, 54];

// ---- helpers ----------------------------------------------------------------

const log = (...args) => console.log("[migrate]", ...args);
const warn = (...args) => console.warn("[migrate] WARN", ...args);
const err = (...args) => console.error("[migrate] ERROR", ...args);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchJSON(url, attempts = 3) {
  for (let i = 1; i <= attempts; i++) {
    try {
      const r = await fetch(url, {
        headers: { "user-agent": "urgence-palestine-migration/1.0" },
        redirect: "follow",
        signal: AbortSignal.timeout(30_000),
      });
      if (!r.ok) throw new Error(`HTTP ${r.status} for ${url}`);
      return await r.json();
    } catch (e) {
      if (i === attempts) throw e;
      warn(`fetch ${url} failed (${e.message}); retry ${i + 1}/${attempts}`);
      await sleep(1500 * i);
    }
  }
}

async function downloadToFile(url, dest) {
  if (existsSync(dest)) return; // already have it
  const r = await fetch(url, {
    headers: { "user-agent": "urgence-palestine-migration/1.0" },
    redirect: "follow",
    signal: AbortSignal.timeout(60_000),
  });
  if (!r.ok) throw new Error(`download HTTP ${r.status} for ${url}`);
  await mkdir(dirname(dest), { recursive: true });
  // Stream to disk
  const body = Readable.fromWeb(r.body);
  await pipeline(body, createWriteStream(dest));
}

function decodeSlug(raw) {
  // WP slugs are URL-encoded UTF-8 (e.g. `candidat%c2%b7es` for `candidat·es`).
  let s;
  try {
    s = decodeURIComponent(raw);
  } catch {
    s = raw;
  }
  // Normalise: replace middle-dot (·) with a hyphen, then transliterate
  // any other non-ASCII chars to their ASCII counterpart. This keeps
  // filenames portable and URL-safe on every platform.
  s = s.replace(/[·•]/g, "-");
  s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, ""); // strip diacritics
  s = s.replace(/[–—]/g, "-");
  s = s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return s || "untitled";
}

function decodeHtmlEntities(s) {
  // The WP excerpt is HTML-encoded; we want plain text in frontmatter.
  return s
    .replace(/<[^>]+>/g, "") // strip tags
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&hellip;/g, "…")
    .replace(/&rsquo;|&lsquo;/g, "'")
    .replace(/&rdquo;|&ldquo;/g, '"')
    .replace(/&[a-z]+;|\&#\d+;/g, "") // anything left
    .replace(/\s+/g, " ")
    .trim();
}

// YAML-escape a string for frontmatter (wrap in double quotes, escape
// backslash and double-quote, drop control chars).
function yamlString(s) {
  return JSON.stringify(String(s));
}

function isoDate(d) {
  // WordPress `date` is "2024-02-08T15:41:19" (no tz) — treat as UTC.
  return new Date(d).toISOString().slice(0, 10);
}

function basenameFromUrl(url) {
  let p;
  try {
    p = new URL(url).pathname;
  } catch {
    p = url.split("?")[0];
  }
  const name = basename(p);
  return name || "image";
}

// Some legacy URLs end with stray whitespace or non-breaking spaces
// before the closing shortcode/quote. Trim before doing path ops.
function trimUrl(u) {
  return String(u).replace(/[\s\u00a0]+$/g, "").replace(/^[\s\u00a0]+/g, "");
}

// Drop Divi-builder layout shortcodes so turndown only sees the inner
// HTML. We keep the inner content of `[et_pb_text]` (the actual text/HTML)
// and strip purely structural wrappers. The regex matches the opening
// shortcode (with all its attributes) plus the optional closing tag.
function unwrapDiviShortcodes(html) {
  if (!html) return html;
  if (!/et_pb_(section|row|column|code|text|image|button|divider)\b/.test(html)) {
    return html;
  }
  let out = html;
  // The order matters: unwrap from the outermost in.
  // 1) Remove structural opens/closes that are pure layout.
  out = out.replace(/\[et_pb_section[^\]]*\]\s*/g, "");
  out = out.replace(/\s*\[\/et_pb_section\]/g, "");
  out = out.replace(/\[et_pb_row[^\]]*\]\s*/g, "");
  out = out.replace(/\s*\[\/et_pb_row\]/g, "");
  out = out.replace(/\[et_pb_column[^\]]*\]\s*/g, "");
  out = out.replace(/\s*\[\/et_pb_column\]/g, "");
  // 2) Keep the contents of [et_pb_text]…[/et_pb_text].
  out = out.replace(/\[et_pb_text[^\]]*\]\s*/g, "");
  out = out.replace(/\s*\[\/et_pb_text\]/g, "");
  // 3) Self-closing leaf shortcodes → drop entirely.
  out = out.replace(/\[et_pb_(image|button|divider|code|post_title|post_content)[^\]]*\/?\]/g, "");
  // 4) Generic catch-all for any et_pb_* opening/closing tag we didn't
  //    explicitly handle above.
  out = out.replace(/\[et_pb_[a-z_]+\s+[^\]]*\]\s*/g, "");
  out = out.replace(/\s*\[\/et_pb_[a-z_]+\]/g, "");
  out = out.replace(/\[et_pb_[a-z_]+\/?\]/g, "");
  return out;
}

// ---- main -------------------------------------------------------------------

async function main() {
  await mkdir(STATIC_BASE, { recursive: true });
  await mkdir(CONTENT_BASE, { recursive: true });

  log("Fetching post index for categories", CATEGORY_IDS, "…");
  const allPosts = [];
  for (const cat of CATEGORY_IDS) {
    const data = await fetchJSON(
      `${API}/posts?categories=${cat}&per_page=100&_embed`,
    );
    log(`  category ${cat}: ${data.length} posts`);
    for (const p of data) allPosts.push(p);
  }

  // Dedupe by id (some posts live in multiple categories)
  const seen = new Set();
  const posts = [];
  for (const p of allPosts) {
    if (seen.has(p.id)) continue;
    seen.add(p.id);
    posts.push(p);
  }
  log(`Total unique posts: ${posts.length}`);

  // Sort by date ascending — gives a natural filename order on disk.
  posts.sort((a, b) => a.date.localeCompare(b.date));

  // Track image filename usage so we can de-dup within a single post.
  const turndown = new TurndownService({
    headingStyle: "atx",
    codeBlockStyle: "fenced",
    bulletListMarker: "-",
    emDelimiter: "_",
  });

  // Don't touch links that already point to /communiques/...
  turndown.addRule("noopLinks", {
    filter: (node) => node.nodeName === "A",
    replacement: (content, node) => {
      const href = node.getAttribute("href") || "";
      return `[${content}](${href})`;
    },
  });

  // Strip WordPress's srcset attribute; we only need a single src.
  turndown.addRule("stripSrcset", {
    filter: (node) => node.nodeName === "IMG",
    replacement: (content, node) => {
      // The actual rewriting is done post-turndown on the markdown string
      // (because we want to control filenames and download them in one place).
      const src = node.getAttribute("src") || "";
      const alt = node.getAttribute("alt") || "";
      return `![${alt}](${src})`;
    },
  });

  const inventoryLines = [];
  let totalImages = 0;
  let totalFeatured = 0;

  for (const post of posts) {
    log(`-- post ${post.id}: ${decodeHtmlEntities(post.title?.rendered || "")}`);

    // Full detail payload (the index call already has _embedded but no body).
    const detail = await fetchJSON(`${API}/posts/${post.id}`);
    const html = detail.content?.rendered || "";
    const excerptHtml = detail.excerpt?.rendered || "";
    const titleRaw = decodeHtmlEntities(detail.title?.rendered || "").trim();
    const date = isoDate(detail.date);
    const slug = decodeSlug(detail.slug);
    const legacyUrl = detail.link;

    // Resolve featured media URL via _embedded on the index call
    // (we already have it cached in `post`).
    let featuredUrl = null;
    const fm = post._embedded?.["wp:featuredmedia"]?.[0];
    if (fm && fm.source_url) {
      featuredUrl = fm.source_url;
    } else if (detail.featured_media && detail.featured_media !== 0) {
      // Fallback: fetch the media object directly.
      try {
        const m = await fetchJSON(`${API}/media/${detail.featured_media}`);
        featuredUrl = m.source_url;
      } catch (e) {
        warn(`  could not resolve featured media ${detail.featured_media}: ${e.message}`);
      }
    }

    const postDir = join(STATIC_BASE, slug);
    await mkdir(postDir, { recursive: true });

    // Build a map source-URL → local relative path.
    // The "source" key is the exact URL string as it appears in the HTML.
    const localFor = new Map();
    const usedNames = new Set();
    const nextFilename = (rawUrl) => {
      const ext = (extname(basenameFromUrl(rawUrl)) || ".jpg").toLowerCase();
      const base = basenameFromUrl(rawUrl)
        .replace(extname(basenameFromUrl(rawUrl)), "")
        .toLowerCase()
        .replace(/[^a-z0-9_-]+/g, "-")
        .replace(/^-+|-+$/g, "")
        .slice(0, 40) || "image";
      let candidate = `${base}${ext}`;
      let i = 1;
      while (usedNames.has(candidate)) {
        candidate = `${base}-${i++}${ext}`;
      }
      usedNames.add(candidate);
      return candidate;
    };

    // 1) Featured image
    let featuredLocal = null;
    if (featuredUrl) {
      const u = trimUrl(featuredUrl);
      const fname = nextFilename(u);
      const dest = join(postDir, fname);
      try {
        await downloadToFile(u, dest);
        featuredLocal = `/communiques/${slug}/${fname}`;
        localFor.set(u, featuredLocal);
        totalFeatured++;
      } catch (e) {
        warn(`  featured image download failed: ${u} — ${e.message}`);
      }
    }

    // Track the path of the featured image so we can dedupe in-body
    // copies of the same file served from a different host.
    let featuredPath = null;
    if (featuredUrl) {
      try {
        featuredPath = new URL(trimUrl(featuredUrl)).pathname;
      } catch {}
    }

    // 2) In-body images — discover all <img src="…"> in the HTML.
    //    The legacy site sometimes emits a space between `=` and the
    //    opening quote (and the quote can be a French guillemet «…»),
    //    so we accept both styles. We also trim the captured URL
    //    because the legacy site occasionally appends a non-breaking
    //    space (U+00A0) inside the attribute value.
    const cleanUrl = (s) => s.replace(/[\s\u00a0]+$/g, "").replace(/^[\s\u00a0]+/g, "");

    const imgRe = /<img\b[^>]*\bsrc=\s*["'«»]([^"'«»]+?)["'«»]/gi;
    let m;
    const bodyImgs = new Set();
    while ((m = imgRe.exec(html)) !== null) {
      bodyImgs.add(cleanUrl(m[1]));
    }
    // Also check srcset (some legacy posts set src but use srcset for sizes)
    const srcsetRe = /<img\b[^>]*\bsrcset=\s*["'«»]([^"'«»]+?)["'«»]/gi;
    while ((m = srcsetRe.exec(html)) !== null) {
      // take the first URL of the srcset
      const first = m[1].split(",")[0]?.trim().split(/\s+/)[0];
      if (first) bodyImgs.add(cleanUrl(first));
    }
    // Divi builder shortcodes embed images as `[et_pb_image src="…"]`
    // — scan those too so we still download them and include the image
    // in the body (via the rewritten URL). The legacy site sometimes
    // serialises attribute quotes as the French guillemets «…», so we
    // accept any of the three styles (and tolerate whitespace between
    // `=` and the opening quote).
    const diviImgRe = /\[et_pb_image[^\]]*\bsrc=\s*["'«»]([^"'«»]+?)["'«»]/gi;
    while ((m = diviImgRe.exec(html)) !== null) {
      bodyImgs.add(cleanUrl(m[1]));
    }
    for (const u of bodyImgs) {
      if (localFor.has(u)) continue; // already handled as featured
      // If this body image points to the same path as the featured one
      // (the legacy CDN serves the same file under two hosts), reuse
      // the featured local path instead of downloading a duplicate.
      let sameAsFeatured = false;
      if (featuredPath && featuredLocal) {
        try {
          if (new URL(trimUrl(u)).pathname === featuredPath) sameAsFeatured = true;
        } catch {}
      }
      if (sameAsFeatured) {
        localFor.set(trimUrl(u), featuredLocal);
        continue;
      }
      const u2 = trimUrl(u);
      const fname = nextFilename(u2);
      const dest = join(postDir, fname);
      try {
        await downloadToFile(u2, dest);
        localFor.set(u2, `/communiques/${slug}/${fname}`);
        totalImages++;
      } catch (e) {
        warn(`  body image download failed: ${u2} — ${e.message}`);
        // Map to a 404 placeholder so the broken reference is at least visible.
        localFor.set(u2, `/communiques/${slug}/_missing_${fname}`);
      }
    }

    // 3) Convert body HTML → Markdown.
    //    Some legacy posts were authored with the Divi builder, so the
    //    body is wrapped in `[et_pb_section][et_pb_row][et_pb_column]
    //    [et_pb_text]…[/et_pb_text]…[/et_pb_column]…[/et_pb_row]…[/et_pb_section]`
    //    shortcodes. We unwrap those so turndown only sees the inner HTML.
    const cleanedHtml = unwrapDiviShortcodes(html);
    let bodyMd = turndown.turndown(cleanedHtml);

    // If the body has no `<img>` tags after unwrapping (e.g. a Divi post
    // that only had an `[et_pb_image src=…]` shortcode with no real text),
    // use the in-body images as the entire body. If the body has no
    // images and no text (a Divi empty post), fall through to the
    // featured-image path below.
    const cleanedHasImg = /<img\b/i.test(cleanedHtml);
    const cleanedHasText = /<p\b|<h[1-6]\b|<blockquote\b|<ul\b|<ol\b/i.test(
      cleanedHtml,
    );
    if (!cleanedHasImg && bodyImgs.size > 0 && !cleanedHasText) {
      // Body is essentially empty — emit each image as the body.
      const lines = [];
      for (const u of bodyImgs) {
        if (localFor.has(trimUrl(u))) {
          lines.push(`![](${localFor.get(trimUrl(u))})`);
        }
      }
      if (lines.length) bodyMd = lines.join("\n\n");
    } else if (!cleanedHasImg && bodyImgs.size > 0) {
      // Body has text but no inline images — append the images at the end.
      const lines = [];
      for (const u of bodyImgs) {
        if (localFor.has(trimUrl(u)))
          lines.push(`![](${localFor.get(trimUrl(u))})`);
      }
      if (lines.length) bodyMd = `${bodyMd}\n\n${lines.join("\n\n")}`;
    }

    // If the post has a featured image that isn't already referenced
    // in the body markdown, prepend it. The acceptance criteria require
    // the featured image to be referenced from the body (the schema has
    // no `image` field, so the reference must be a Markdown image).
    if (featuredLocal) {
      const alreadyReferenced = bodyMd.includes(featuredLocal);
      if (!alreadyReferenced) {
        bodyMd = `![Featured image](${featuredLocal})\n\n${bodyMd}`;
      }
    }
    // Drop empty paragraphs that turndown sometimes leaves from <p></p>
    bodyMd = bodyMd
      .split(/\n{2,}/)
      .map((p) => p.trim())
      .filter((p) => p.length > 0)
      .join("\n\n");

    // 4) Rewrite image URLs to local relative paths.
    //    Order matters: longest URLs first (so a /uploads/x.png isn't
    //    shadowed by an /uploads/ substring match).
    const rewriteEntries = [...localFor.entries()].sort(
      (a, b) => b[0].length - a[0].length,
    );
    for (const [src, local] of rewriteEntries) {
      bodyMd = bodyMd.split(src).join(local);
    }

    // 5) Drop the very first paragraph if it's just a duplicate of the
    //    title (some posts open with a bolded title).  This is best-effort
    //    and only matches when the entire paragraph equals the title.
    const titleNorm = titleRaw.toLowerCase().replace(/\s+/g, " ");
    bodyMd = bodyMd
      .split(/\n{2,}/)
      .filter((p) => {
        const stripped = p
          .replace(/^[\s*_>]+|[\s*_>]+$/g, "")
          .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
          .replace(/[*_`]+/g, "")
          .toLowerCase()
          .replace(/\s+/g, " ")
          .trim();
        return stripped !== titleNorm;
      })
      .join("\n\n");

    // 6) Build frontmatter.
    const description = decodeHtmlEntities(excerptHtml);
    const fLines = ["---"];
    fLines.push(`title: ${yamlString(titleRaw)}`);
    fLines.push(`date: ${date}`);
    if (description) fLines.push(`description: ${yamlString(description)}`);
    fLines.push("---");
    fLines.push("");
    const file = `${fLines.join("\n")}\n${bodyMd}\n`;

    // 7) Write the file. Filename pattern: YYYY-MM-DD-<slug>.md
    const outPath = join(CONTENT_BASE, `${date}-${slug}.md`);
    await writeFile(outPath, file, "utf8");
    log(`  wrote ${outPath} (${file.length} bytes)`);

    // 8) Inventory line. We always include the URL in decoded form to
    //    make it readable; the encoded version is also valid.
    const invPath = `src/content/communiques/${date}-${slug}.md`;
    inventoryLines.push(`- ${legacyUrl} → ${invPath}`);
  }

  // Write / overwrite migration-inventory.md. The list is generated
  // fresh every run from the actual migrated files + legacy URLs, so
  // re-running the script always produces a consistent inventory.
  const invHeader =
    [
      "# Migration inventory",
      "",
      "Mapping of every legacy \"Prises de parole\" entry to its new file in",
      "the `communiques` content collection. One line per entry, of the form",
      "",
      "```",
      "- <legacy URL> → <new file path>",
      "```",
      "",
      "Generated by `scripts/migrate.mjs` from the WordPress REST API on",
      "`urgence-palestine.com`. The list below matches the files actually",
      `present in \`src/content/communiques/\`. Total entries: ${inventoryLines.length}.`,
      "",
    ].join("\n") + "\n";

  const final = invHeader + inventoryLines.join("\n") + "\n";
  await writeFile(INVENTORY, final, "utf8");

  // Final pass: walk the static/communiques directory and remove any
  // file that isn't referenced by a corresponding Markdown file. This
  // is a safety net for earlier runs that may have left stray files
  // behind (e.g. filename collisions where the dedup logic changed).
  // We map each static dir to its .md file via the inventory lines
  // (the directory name is the post's slug, which matches the file-
  // name suffix after the `YYYY-MM-DD-` prefix).
  console.log("");
  log("Cleaning up orphan static image files…");
  let removedOrphans = 0;
  const dirToMd = new Map();
  for (const line of inventoryLines) {
    const m = line.match(/^-\s+.+?\s+(?:→|->)\s+src\/content\/communiques\/(\S+)\s*$/);
    if (!m) continue;
    const fileName = m[1];
    const inner = fileName.match(/^\d{4}-\d{2}-\d{2}-(.+)\.md$/);
    if (inner) dirToMd.set(inner[1], join(CONTENT_BASE, fileName));
  }
  for (const slugDir of await readdir(STATIC_BASE)) {
    const dir = join(STATIC_BASE, slugDir);
    const dirStat = await stat(dir);
    if (!dirStat.isDirectory()) continue;
    const mdPath = dirToMd.get(slugDir);
    if (!mdPath || !existsSync(mdPath)) {
      // No matching markdown — leave the directory alone, it's not
      // part of the migration (could be a hand-authored asset).
      continue;
    }
    const md = await readFile(mdPath, "utf8");
    const expectedPrefix = `/communiques/${slugDir}/`;
    for (const f of await readdir(dir)) {
      const p = join(dir, f);
      const fileStat = await stat(p);
      if (!fileStat.isFile()) continue;
      const ref = expectedPrefix + f;
      if (!md.includes(ref)) {
        await unlink(p);
        removedOrphans++;
        log(`  removed orphan: ${p}`);
      }
    }
  }
  log(`  ${removedOrphans} orphan file(s) removed`);

  log("");
  log(`Done. ${posts.length} posts migrated.`);
  log(`  Featured images: ${totalFeatured}`);
  log(`  Body images:     ${totalImages}`);
  log(`  Inventory:       ${INVENTORY}`);
}

main().catch((e) => {
  err(e.stack || e.message);
  process.exit(1);
});
