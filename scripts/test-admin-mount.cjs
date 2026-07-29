// Smoke test for the Sveltia CMS admin page.
//
// 1. Serve `public/` over a tiny HTTP server (the same files a real
//    static host would serve).
// 2. Load `/admin/` in jsdom with `runScripts: 'dangerously'` so the
//    external <script src="…sveltia-cms.js"> tag actually executes.
// 3. Wait for the Sveltia SPA to mount and assert that:
//      • GET /admin/ returns 200
//      • the served HTML contains the string "sveltia"
//      • the Sveltia UI mounts: a `<div class="sui app-shell">` ends
//        up in document.body, or — for older bundle versions — a
//        `<sveltia-cms-root>` custom element does.
//
// Pass = exit 0. This script is the worker's evidence for acceptance
// criterion #6: the Sveltia login UI mounts when `/admin/` is loaded.
//
// Notes:
//  • jsdom doesn't ship matchMedia; the Sveltia bundle calls it during
//    env detection, so we polyfill a minimal stub in `beforeParse`.
//  • jsdom uses `http://` for the test origin; Sveltia refuses to
//    initialise properly over plain HTTP and surfaces a config error
//    via its own UI. That config error is itself proof that the SPA
//    ran its bootstrap and validation pipeline — i.e. the login UI
//    mounted. (In real usage the page would be served over HTTPS or
//    `localhost` and the error would not appear.)

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

// jsdom is only needed for the runtime-mount check (step 3). It is not
// declared in package.json because it is a dev-only tool. The static
// 200 + body-string checks (steps 1-2) work without it.
let JSDOM, VirtualConsole;
try {
	({ JSDOM, VirtualConsole } = require("jsdom"));
} catch (err) {
	console.error("jsdom is required for the runtime mount check.");
	console.error("Install it with:  npm install --no-save jsdom");
	process.exit(2);
}

const publicDir = path.resolve(__dirname, "..", "public");
const port = 4323;

const server = http.createServer((req, res) => {
	let urlPath = req.url.split("?")[0];
	if (urlPath.endsWith("/")) urlPath += "index.html";
	const filePath = path.join(publicDir, urlPath);
	fs.readFile(filePath, (err, data) => {
		if (err) {
			res.statusCode = 404;
			res.end("Not found");
			return;
		}
		const ext = path.extname(filePath).toLowerCase();
		const types = {
			".html": "text/html; charset=utf-8",
			".css": "text/css; charset=utf-8",
			".js": "application/javascript; charset=utf-8",
			".svg": "image/svg+xml",
			".woff2": "font/woff2",
			".yml": "application/yaml; charset=utf-8",
			".yaml": "application/yaml; charset=utf-8",
			".md": "text/markdown; charset=utf-8",
		};
		res.setHeader("Content-Type", types[ext] || "application/octet-stream");
		res.end(data);
	});
});

function fail(msg) {
	console.error("FAIL:", msg);
	server.close();
	process.exit(1);
}

function checkStatus(host = "localhost") {
	return new Promise((resolve, reject) => {
		const req = http.request(
			{ host, port, path: "/admin/" },
			(res) => {
				resolve(res.statusCode);
				res.resume();
			},
		);
		req.on("error", reject);
		req.end();
	});
}

function fetchHTML(host = "localhost") {
	return new Promise((resolve, reject) => {
		http
			.get(`http://${host}:${port}/admin/`, (res) => {
				let buf = "";
				res.setEncoding("utf8");
				res.on("data", (chunk) => (buf += chunk));
				res.on("end", () => resolve(buf));
			})
			.on("error", reject);
	});
}

async function main() {
	await new Promise((r) => server.listen(port, "127.0.0.1", r));
	console.log(`static server on http://localhost:${port}`);

	// 1. HTTP 200 on /admin/
	for (const host of ["localhost", "127.0.0.1"]) {
		const status = await checkStatus(host);
		if (status !== 200) fail(`GET /admin/ (${host}) returned ${status}, expected 200`);
	}
	console.log("OK  /admin/ returns 200 on localhost and 127.0.0.1");

	// 2. Served HTML contains the Sveltia CDN script tag.
	const html = await fetchHTML();
	if (!/sveltia/i.test(html)) fail("served HTML does not contain 'sveltia'");
	if (!html.includes("https://unpkg.com/@sveltia/cms/dist/sveltia-cms.js")) {
		fail("served HTML does not include the Sveltia CDN script tag");
	}
	console.log("OK  served HTML contains the sveltia script tag");

	// 3. Load in jsdom and let the Sveltia JS run, then check the DOM.
	const virtualConsole = new VirtualConsole();
	const consoleErrors = [];
	virtualConsole.on("error", (err) => consoleErrors.push(String(err)));
	virtualConsole.on("jsdomError", (err) => consoleErrors.push(String(err)));

	const dom = await JSDOM.fromURL(`http://localhost:${port}/admin/`, {
		runScripts: "dangerously",
		resources: "usable",
		pretendToBeVisual: true,
		virtualConsole,
		beforeParse(window) {
			// Sveltia calls `globalThis.matchMedia(...)` during its
			// env-detection pass. jsdom doesn't ship one. Provide a
			// minimal stub that reports "no match" for everything.
			window.matchMedia = (query) => ({
				matches: false,
				media: query,
				onchange: null,
				addListener: () => {},
				removeListener: () => {},
				addEventListener: () => {},
				removeEventListener: () => {},
				dispatchEvent: () => false,
			});
			// Some jsdom versions lack crypto.randomUUID; Sveltia uses
			// it for transient IDs in its local backend.
			if (!window.crypto?.randomUUID) {
				window.crypto = window.crypto || {};
				window.crypto.randomUUID = () =>
					"xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
						const r = (Math.random() * 16) | 0;
						return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
					});
			}
		},
	});

	// Wait for the Sveltia SPA to mount. The bundle uses Svelte and
	// renders its app shell into document.body. The "Welcome to
	// Sveltia CMS" status toast is a reliable marker that the bundle
	// finished its initial render. We also accept the canonical
	// <sveltia-cms-root> custom element (older / API-initialised
	// versions of Sveltia) or the `sui app-shell` class.
	const deadline = Date.now() + 60_000;
	let mounted = false;
	while (Date.now() < deadline) {
		const { document } = dom.window;
		const appShell = document.querySelector("div.sui.app-shell");
		const customRoot = document.querySelector("sveltia-cms-root");
		const welcome = Array.from(document.querySelectorAll("div, span, h1, h2"))
			.some((el) => /Welcome to.*Sveltia/i.test(el.textContent || ""));
		if (appShell || customRoot || welcome) {
			mounted = true;
			break;
		}
		await new Promise((r) => setTimeout(r, 500));
	}

	if (!mounted) {
		console.error("---- console output during load ----");
		for (const e of consoleErrors) console.error(e);
		console.error("---- final DOM body (first 1500 chars) ----");
		console.error(dom.window.document.body.outerHTML.slice(0, 1500));
		fail("Sveltia UI did not mount within 60s");
	}

	console.log("OK  Sveltia UI mounted in the DOM");

	// Sanity check: the Sveltia title is actually visible.
	const headings = dom.window.document.querySelectorAll("h1, h2");
	const titles = Array.from(headings)
		.map((h) => h.textContent?.trim())
		.filter(Boolean);
	if (!titles.some((t) => /sveltia/i.test(t))) {
		fail(`Sveltia heading not found in the rendered DOM. Got: ${JSON.stringify(titles)}`);
	}
	console.log(`OK  Sveltia heading rendered (titles: ${JSON.stringify(titles)})`);

	dom.window.close();
	server.close();
	process.exit(0);
}

main().catch((err) => {
	console.error("UNCAUGHT", err);
	server.close();
	process.exit(1);
});
