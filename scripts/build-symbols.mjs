/* eslint-disable no-console */
/**
 * Build the 9 hand-drawn brand symbols and rasterize them to PNG.
 *
 * Why this script exists:
 *  - Acceptance criteria require raster (non-<svg>) images in /static/symbols/.
 *  - The hand-drawn look is best authored as SVG paths, then exported to PNG
 *    via sharp so the deployed page contains zero <svg> brand marks.
 *
 * Run: `node scripts/build-symbols.mjs`
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const outDir = path.join(root, "static", "symbols");
await fs.mkdir(outDir, { recursive: true });

const SIZE = 512;

/* ---------------------------------------------------------------------------
 * Shared SVG helpers — every symbol sits on a 512×512 transparent canvas so
 * the rasterized PNG can be dropped into a layout without further sizing.
 * -------------------------------------------------------------------------- */

const wrap = (inner, { ink = "#101010", paper = "transparent" } = {}) => `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}">
  <defs>
    <!-- Slight "wobble" filter that gives the ink a hand-drawn feel. -->
    <filter id="wobble" x="-5%" y="-5%" width="110%" height="110%">
      <feTurbulence type="fractalNoise" baseFrequency="0.022" numOctaves="2" seed="7"/>
      <feDisplacementMap in="SourceGraphic" scale="2.2"/>
    </filter>
    <!-- Paper grain that lifts the black ink off pure-flat. -->
    <filter id="paper" x="0%" y="0%" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="3"/>
      <feColorMatrix values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 0.06 0"/>
    </filter>
  </defs>
  <rect width="${SIZE}" height="${SIZE}" fill="${paper}"/>
  <g stroke="${ink}" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" fill="none" filter="url(#wobble)">
    ${inner}
  </g>
  <rect width="${SIZE}" height="${SIZE}" filter="url(#paper)"/>
</svg>`;

/* Hatching helper for shading. */
const hatch = (x, y, w, h, gap = 9, angle = -30) => {
	const lines = [];
	const rad = (angle * Math.PI) / 180;
	const dx = Math.cos(rad);
	const dy = Math.sin(rad);
	const nx = -dy;
	const ny = dx;
	for (let i = -h; i < w + h; i += gap) {
		const cx = x + dx * i;
		const cy = y + dy * i;
		lines.push(
			`<line x1="${(cx + nx * -h).toFixed(1)}" y1="${(cy + ny * -h).toFixed(1)}" x2="${(cx + nx * h).toFixed(1)}" y2="${(cy + ny * h).toFixed(1)}" stroke-width="1.4" opacity="0.55"/>`,
		);
	}
	return lines.join("");
};

/* ---------------------------------------------------------------------------
 * 1. Antique key — old Palestinian house key, the symbol of return.
 *    Bow with a quatrefoil, long shaft, ward with a small cross.
 * -------------------------------------------------------------------------- */
const key = `
  <!-- bow (head) -->
  <circle cx="370" cy="200" r="58" stroke-width="3.2"/>
  <circle cx="370" cy="200" r="40" stroke-width="2.4" opacity="0.6"/>
  <!-- inner cross detail -->
  <path d="M355 180 L385 220 M385 180 L355 220" stroke-width="2.2" opacity="0.5"/>
  <!-- shaft -->
  <path d="M312 200 L120 200"/>
  <!-- teeth / ward -->
  <path d="M180 200 L180 232 L210 232 L210 218 L235 218 L235 240 L200 240"/>
  <!-- key tip dot -->
  <circle cx="125" cy="200" r="6" fill="currentColor" stroke="none" opacity="0.6"/>
`;

/* ---------------------------------------------------------------------------
 * 2. Pomegranate — fruit split open showing seeds.
 * -------------------------------------------------------------------------- */
const pomegranate = `
  <!-- crown -->
  <path d="M230 110 L256 88 L282 110 L268 110 L256 96 L244 110 Z"/>
  <!-- body -->
  <path d="M256 130
           C 160 130 130 230 150 320
           C 165 380 200 410 256 410
           C 312 410 347 380 362 320
           C 382 230 352 130 256 130 Z"/>
  <!-- crack -->
  <path d="M256 150 L252 240 L260 320 L254 400" stroke-width="2.4" opacity="0.7"/>
  <!-- inner chambers -->
  <path d="M200 240 C 220 230 250 240 256 260" stroke-width="1.6" opacity="0.5"/>
  <path d="M312 240 C 292 230 262 240 256 260" stroke-width="1.6" opacity="0.5"/>
  <!-- seeds -->
  ${Array.from({ length: 14 })
		.map(() => {
			const a = Math.random() * Math.PI * 2;
			const r = 30 + Math.random() * 55;
			const cx = 256 + Math.cos(a) * r;
			const cy = 320 + Math.sin(a) * (r * 0.85);
			return `<circle cx="${cx.toFixed(0)}" cy="${cy.toFixed(0)}" r="6" fill="#101010" stroke="none" opacity="0.85"/>`;
		})
		.join("")}
  <!-- shading -->
  ${hatch(160, 280, 90, 120, 10, -35)}
`;

/* ---------------------------------------------------------------------------
 * 3. Olive oil — small amphora/jug with a single drop, sprig of olives.
 * -------------------------------------------------------------------------- */
const oliveOil = `
  <!-- sprig behind -->
  <path d="M120 200 C 160 220 200 240 240 260" stroke-width="2"/>
  <path d="M150 195 L168 220 M180 205 L198 230 M210 220 L228 245" stroke-width="1.6"/>
  <ellipse cx="146" cy="196" rx="9" ry="5" transform="rotate(-20 146 196)"/>
  <ellipse cx="174" cy="206" rx="9" ry="5" transform="rotate(-25 174 206)"/>
  <!-- amphora -->
  <path d="M260 150
           L260 170
           C 230 180 220 210 220 240
           L220 360
           C 220 395 240 410 256 410
           C 272 410 292 395 292 360
           L292 240
           C 292 210 282 180 252 170
           L252 150 Z"/>
  <!-- handles -->
  <path d="M220 220 C 200 230 200 260 222 268"/>
  <path d="M292 220 C 312 230 312 260 290 268"/>
  <!-- neck band -->
  <path d="M232 180 L280 180" stroke-width="1.6"/>
  <path d="M232 200 L280 200" stroke-width="1.6"/>
  <!-- oil drop -->
  <path d="M256 70
           C 240 90 240 110 256 120
           C 272 110 272 90 256 70 Z" fill="#101010" stroke="#101010" stroke-width="2.2"/>
  <!-- shading -->
  ${hatch(228, 260, 56, 130, 9, 40)}
`;

/* ---------------------------------------------------------------------------
 * 4. Keffieh — folded scarf with the fishnet pattern and a绳 (agal).
 * -------------------------------------------------------------------------- */
const keffieh = `
  <!-- main folded triangle -->
  <path d="M110 380
           L256 90
           L402 380
           L320 380
           L256 240
           L192 380 Z"/>
  <!-- cross stitches (simplified fishnet) -->
  <path d="M150 360 L362 360 M170 320 L342 320 M195 280 L317 280 M220 240 L292 240" stroke-width="1.2" opacity="0.45"/>
  <path d="M125 350 L387 350 M145 310 L367 310 M170 270 L342 270" stroke-width="1.2" opacity="0.45" stroke-dasharray="3 5"/>
  <!-- olive-leaf pattern simplified as small marks -->
  ${Array.from({ length: 6 })
		.map((_, i) => {
			const cx = 180 + i * 35;
			const cy = 345;
			return `<path d="M${cx} ${cy} l6 -8 l-6 -4 Z" stroke-width="1.4" opacity="0.5"/>`;
		})
		.join("")}
  <!-- agal (cord) draped over the top -->
  <path d="M150 130
           C 200 100 312 100 362 130
           C 360 150 320 160 256 160
           C 192 160 152 150 150 130 Z" fill="#101010" stroke="#101010" stroke-width="2.2"/>
  <!-- agal tassels -->
  <path d="M150 130 L138 180 M362 130 L374 180 M256 110 L256 60" stroke-width="2"/>
  <path d="M138 180 L130 200 M374 180 L382 200 M256 60 L256 80" stroke-width="2"/>
  <!-- fold shading -->
  ${hatch(220, 260, 80, 80, 8, 25)}
`;

/* ---------------------------------------------------------------------------
 * 5. Souimanga (Palestine Sunbird) — small, iridescent-looking bird perched
 *    on an olive branch, body in profile, long curved beak.
 * -------------------------------------------------------------------------- */
const sunbird = `
  <!-- branch -->
  <path d="M60 380 C 180 360 320 360 460 380" stroke-width="3"/>
  <path d="M120 372 L138 392 M200 365 L218 385 M300 363 L318 383 M380 365 L398 385" stroke-width="1.6"/>
  <!-- leaves -->
  <path d="M138 392 c -10 -8 -8 -22 6 -28 c 4 8 0 22 -6 28 Z"/>
  <path d="M218 385 c -10 -8 -8 -22 6 -28 c 4 8 0 22 -6 28 Z"/>
  <path d="M318 383 c -10 -8 -8 -22 6 -28 c 4 8 0 22 -6 28 Z"/>
  <path d="M398 385 c -10 -8 -8 -22 6 -28 c 4 8 0 22 -6 28 Z"/>
  <!-- tail -->
  <path d="M120 240
           C 150 230 180 250 210 280
           L 240 320
           L 200 310
           L 170 280 Z" fill="#101010" stroke="#101010"/>
  <!-- body -->
  <path d="M180 290
           C 220 240 320 230 360 270
           C 380 290 360 320 320 330
           C 270 340 200 330 180 290 Z" fill="#101010" stroke="#101010"/>
  <!-- wing -->
  <path d="M250 290
           C 280 270 320 270 340 290
           C 330 310 290 320 250 310 Z" stroke-width="2.2" fill="none"/>
  <!-- head -->
  <circle cx="368" cy="252" r="22" fill="#101010" stroke="#101010"/>
  <!-- beak (long, curved, down) -->
  <path d="M388 256
           C 410 260 426 280 432 304
           C 422 306 408 296 396 286
           C 392 278 388 268 388 256 Z" fill="#101010" stroke="#101010"/>
  <!-- eye highlight -->
  <circle cx="372" cy="248" r="2.5" fill="#ffffff" stroke="none"/>
  <!-- legs -->
  <path d="M300 330 L300 360 M300 360 L292 370 M300 360 L308 370"/>
  <path d="M280 330 L280 360 M280 360 L272 370 M280 360 L288 370"/>
  <!-- chest mark -->
  <path d="M310 290 c 4 8 4 18 0 24" stroke="#ffffff" stroke-width="2" opacity="0.8"/>
`;

/* ---------------------------------------------------------------------------
 * 6. Poppy (corn poppy) — single flower with the classic dark center.
 * -------------------------------------------------------------------------- */
const poppy = `
  <!-- stem -->
  <path d="M256 250 C 250 320 250 380 256 460" stroke-width="3"/>
  <!-- leaves on stem -->
  <path d="M256 350 C 220 340 200 360 200 380 C 230 380 250 360 256 350"/>
  <path d="M256 400 C 290 390 312 410 314 430 C 284 432 262 412 256 400"/>
  <!-- four petals -->
  <path d="M256 200
           C 200 160 160 200 180 250
           C 220 250 250 230 256 200 Z"/>
  <path d="M256 200
           C 312 160 352 200 332 250
           C 292 250 262 230 256 200 Z"/>
  <path d="M180 250
           C 150 290 200 330 240 310
           C 240 280 220 260 200 252
           C 190 250 184 250 180 250 Z"/>
  <path d="M332 250
           C 362 290 312 330 272 310
           C 272 280 292 260 312 252
           C 322 250 328 250 332 250 Z"/>
  <!-- center pod -->
  <ellipse cx="256" cy="252" rx="22" ry="18" fill="#101010" stroke="#101010"/>
  <!-- stamen lines -->
  <path d="M240 240 L228 230 M272 240 L284 230 M256 232 L256 220 M240 264 L228 274 M272 264 L284 274" stroke-width="1.4" opacity="0.7"/>
`;

/* ---------------------------------------------------------------------------
 * 7. Al-Quds (Jerusalem) — a stylised city dome with minarets under a sun.
 *    The dome represents the Dome of the Rock; minarets echo the Old City
 *    skyline. A subtle olive wreath frames the scene.
 * -------------------------------------------------------------------------- */
const alquds = `
  <!-- sun -->
  <circle cx="256" cy="120" r="42" stroke-width="2.4" opacity="0.65"/>
  <circle cx="256" cy="120" r="56" stroke-width="1.4" opacity="0.4" stroke-dasharray="2 6"/>
  <!-- ground line -->
  <path d="M70 400 L442 400" stroke-width="2.4"/>
  <!-- left minaret -->
  <path d="M120 400 L120 240 L130 240 L130 220 L116 220 L116 200 L134 200 L134 220 L120 220 Z"/>
  <path d="M120 196 L120 180 M134 196 L134 180" stroke-width="1.6"/>
  <!-- right minaret -->
  <path d="M392 400 L392 240 L402 240 L402 220 L388 220 L388 200 L406 200 L406 220 L392 220 Z"/>
  <path d="M392 196 L392 180 M406 196 L406 180" stroke-width="1.6"/>
  <!-- base building -->
  <path d="M150 400 L150 320 L362 320 L362 400" stroke-width="2.6"/>
  <path d="M150 350 L362 350" stroke-width="1.6" opacity="0.5"/>
  <!-- arched windows -->
  <path d="M178 380 L178 360 C 178 348 196 348 196 360 L196 380" stroke-width="1.6"/>
  <path d="M218 380 L218 360 C 218 348 236 348 236 360 L236 380" stroke-width="1.6"/>
  <path d="M276 380 L276 360 C 276 348 294 348 294 360 L294 380" stroke-width="1.6"/>
  <path d="M316 380 L316 360 C 316 348 334 348 334 360 L334 380" stroke-width="1.6"/>
  <!-- drum (cylinder under dome) -->
  <path d="M198 320 L198 240 L314 240 L314 320"/>
  <!-- arch windows on drum -->
  <path d="M222 300 L222 280 C 222 268 240 268 240 280 L240 300" stroke-width="1.6"/>
  <path d="M272 300 L272 280 C 272 268 290 268 290 280 L290 300" stroke-width="1.6"/>
  <!-- dome -->
  <path d="M198 240
           C 198 180 314 180 314 240"/>
  <!-- crescent finial -->
  <path d="M256 170
           C 240 150 240 130 256 122
           C 248 134 248 152 256 170 Z" fill="#101010" stroke="#101010" stroke-width="1.6"/>
  <path d="M256 130 L256 158" stroke-width="1.4" opacity="0.6"/>
  <!-- wreath hint -->
  <path d="M88 408 C 120 460 200 480 256 478" stroke-width="1.6" opacity="0.5"/>
  <path d="M424 408 C 392 460 312 480 256 478" stroke-width="1.6" opacity="0.5"/>
  <path d="M104 416 L112 432 M140 444 L146 462 M180 466 L184 482 M220 478 L222 494" stroke-width="1.2" opacity="0.45"/>
  <path d="M408 416 L400 432 M372 444 L366 462 M332 466 L328 482 M292 478 L290 494" stroke-width="1.2" opacity="0.45"/>
`;

/* ---------------------------------------------------------------------------
 * 8. Al-Aqsa — silhouette of the Al-Aqsa Mosque: rectangular prayer hall with
 *    a lead-sheeted lead dome and a tall minaret, on a small hill base.
 * -------------------------------------------------------------------------- */
const alaqsa = `
  <!-- hill base -->
  <path d="M60 420 C 160 400 360 400 452 420" stroke-width="2.4"/>
  <path d="M70 420 L442 420" stroke-width="1.6" opacity="0.4"/>
  <!-- main hall (rectangular) -->
  <path d="M150 420 L150 270 L362 270 L362 420" stroke-width="2.8"/>
  <!-- roof line -->
  <path d="M150 270 L362 270" stroke-width="2.4"/>
  <!-- arched windows row -->
  ${[0, 1, 2, 3, 4, 5]
		.map(
			(i) =>
				`<path d="M${170 + i * 34} 400 L${170 + i * 34} 372 C ${170 + i * 34} 360 ${190 + i * 34} 360 ${190 + i * 34} 372 L${190 + i * 34} 400" stroke-width="1.6"/>`,
		)
		.join("")}
  <!-- drum -->
  <path d="M212 270 L212 218 L300 218 L300 270"/>
  <!-- dome -->
  <path d="M212 218
           C 212 168 300 168 300 218"/>
  <!-- dome ribs -->
  <path d="M256 174 L256 218 M234 192 L232 218 M278 192 L280 218" stroke-width="1.2" opacity="0.55"/>
  <!-- finial crescent -->
  <path d="M256 156
           C 244 142 244 128 256 122
           C 252 130 252 144 256 156 Z" fill="#101010" stroke="#101010" stroke-width="1.4"/>
  <!-- left minaret (short) -->
  <path d="M110 420 L110 290 L122 290 L122 274 L108 274 L108 260 L124 260 L124 274 L110 274 Z"/>
  <path d="M116 256 L116 246 M118 246 L116 234 L120 234 L118 246" stroke-width="1.4"/>
  <!-- right minaret (tall) -->
  <path d="M396 420 L396 220 L410 220 L410 200 L394 200 L394 180 L412 180 L412 200 L396 200 Z"/>
  <path d="M404 174 L404 156 M406 156 L404 142 L408 142 L406 156" stroke-width="1.6"/>
  <!-- crescent on tall minaret -->
  <path d="M403 138 C 396 130 396 120 403 116 C 400 122 400 132 403 138 Z" fill="#101010" stroke="#101010" stroke-width="1.2"/>
  <!-- door arch -->
  <path d="M236 420 L236 372 C 236 358 276 358 276 372 L276 420" stroke-width="1.6"/>
  <!-- shading hatch on hall -->
  ${hatch(150, 300, 100, 100, 8, 30)}
`;

/* ---------------------------------------------------------------------------
 * 9. Orange (Jaffa orange) — a whole fruit with a leaf and a small slice.
 * -------------------------------------------------------------------------- */
const orange = `
  <!-- whole orange -->
  <circle cx="300" cy="280" r="120" stroke-width="3.2"/>
  <!-- texture dimples (small circles) -->
  ${Array.from({ length: 36 })
		.map(() => {
			const a = Math.random() * Math.PI * 2;
			const r = Math.random() * 100;
			const cx = 300 + Math.cos(a) * r;
			const cy = 280 + Math.sin(a) * r * 0.95;
			return `<circle cx="${cx.toFixed(0)}" cy="${cy.toFixed(0)}" r="2.2" stroke-width="1.2" opacity="0.5"/>`;
		})
		.join("")}
  <!-- stem mark -->
  <path d="M300 160 L300 140" stroke-width="2.4"/>
  <!-- leaf -->
  <path d="M300 140
           C 340 110 380 120 396 150
           C 360 160 320 150 300 140 Z"/>
  <path d="M300 140 C 340 130 370 140 390 148" stroke-width="1.4" opacity="0.6"/>
  <!-- small slice (bottom-left) -->
  <path d="M120 380
           A 60 60 0 0 1 220 410
           L 180 432
           A 60 60 0 0 0 120 380 Z"/>
  <path d="M170 380 A 60 60 0 0 1 200 410" stroke-width="1.4" opacity="0.5"/>
  <!-- segments lines on slice -->
  <path d="M138 388 L172 426 M168 384 L188 422 M196 396 L208 418" stroke-width="1.2" opacity="0.55"/>
`;

/* ---------------------------------------------------------------------------
 * Render every symbol to PNG.
 * -------------------------------------------------------------------------- */

const symbols = [
	{ name: "antique-key", label: "Clef antique", svg: wrap(key) },
	{ name: "pomegranate", label: "Grenade", svg: wrap(pomegranate) },
	{ name: "olive-oil", label: "Huile d'olive", svg: wrap(oliveOil) },
	{ name: "keffieh", label: "Keffieh", svg: wrap(keffieh) },
	{ name: "sunbird", label: "Souimanga", svg: wrap(sunbird) },
	{ name: "poppy", label: "Coquelicot", svg: wrap(poppy) },
	{ name: "al-quds", label: "Al-Quds", svg: wrap(alquds) },
	{ name: "al-aqsa", label: "Al-Aqsa", svg: wrap(alaqsa) },
	{ name: "orange", label: "Orange", svg: wrap(orange) },
];

for (const sym of symbols) {
	const buf = Buffer.from(sym.svg, "utf8");
	const png = await sharp(buf, { density: 144 })
		.resize(SIZE, SIZE, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
		.png({ compressionLevel: 9 })
		.toBuffer();
	const out = path.join(outDir, `${sym.name}.png`);
	await fs.writeFile(out, png);
	console.log(`✓ ${sym.name}.png  (${png.length} bytes)`);
}

console.log(`\nWrote ${symbols.length} symbols to ${path.relative(root, outDir)}/`);
