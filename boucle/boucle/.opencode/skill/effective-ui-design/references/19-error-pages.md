# Error Pages and Offline States

Design patterns for error pages, HTTP status pages, and offline fallbacks that keep users oriented and moving forward.

Error pages are a lower-priority topic in most projects — until a user hits one. A well-designed error page prevents abandonment, maintains trust, and gives people a clear path back to useful content. A poorly designed one creates a dead end that loses visitors permanently.

## Error Page Anatomy

Every error page — regardless of status code — should contain the same structural elements.

**Required elements:**
- Clear heading stating what happened in plain language (not just a status code)
- Brief explanation of why the user might be seeing this page
- Primary action to move forward (link to homepage, search box, or retry button)
- Site navigation (header, footer, or at minimum key links)
- Consistent branding (same logo, colours, fonts as the rest of the site)

**Recommended elements:**
- Search box connected to the site's search engine
- Links to popular or recent content
- Contact or support link for persistent issues

**Structure example:**
```html
<main>
  <h1>Page not found</h1>
  <p>The page you're looking for doesn't exist or has been moved.</p>

  <form role="search" action="/search" method="get">
    <label for="search-input">Search this site</label>
    <input type="search" id="search-input" name="q">
    <button type="submit">Search</button>
  </form>

  <nav aria-label="Suggested pages">
    <h2>Popular pages</h2>
    <ul>
      <li><a href="/">Homepage</a></li>
      <li><a href="/products">Products</a></li>
      <li><a href="/contact">Contact us</a></li>
    </ul>
  </nav>
</main>
```

Sources: [NN/g — Error-Message Guidelines](https://www.nngroup.com/articles/error-message-guidelines/), [NN/g — Improving the Dreaded 404 Error Message](https://www.nngroup.com/articles/improving-dreaded-404-error-message/)

## 404 Not Found Pages

The most common error page users encounter. The goal is to acknowledge the problem and immediately offer alternative paths.

### Messaging

- State clearly that the page was not found — do not just show "404"
- Never blame the user ("You typed the wrong URL") — use neutral language ("This page doesn't exist or has been moved")
- Avoid overly technical language ("HTTP 404", "Resource not found on this server")
- Be specific when possible: if the URL is close to a valid page, suggest the correct one

**Good examples:**
- "We can't find the page you're looking for."
- "This page doesn't exist. It may have been moved or deleted."

**Bad examples:**
- "404"
- "Error: The requested resource could not be located on this server."
- "Oops! You seem to be lost!" (condescending)

### Search Functionality

A search box is the single most valuable element on a 404 page. It transforms a dead end into a starting point.

- Place the search box prominently, not buried below the fold
- Pre-populate the search field with keywords extracted from the failed URL when possible
- Connect it to the site's actual search engine, not a third-party search
- Make the search input large enough to be immediately noticeable

### Navigation and Links

- Always include a link back to the homepage
- List 4-6 popular or high-value pages (most visited, key product categories, recent content)
- If the site has clear sections, show top-level navigation categories
- If analytics data is available, show links based on what users most commonly look for after hitting a 404

### URL Spelling Correction

NN/g research found that implementing URL spelling correction (suggesting similar valid URLs) reduced 404 errors by at least 40% on tested sites. When a URL is close to a valid path, show a clickable suggestion: "Did you mean /products instead of /prodcts?"

Sources: [NN/g — Improving the Dreaded 404 Error Message](https://www.nngroup.com/articles/improving-dreaded-404-error-message/), [UXPin — 404 Page Best Practices](https://www.uxpin.com/studio/blog/404-page-best-practices/), [IxDF — How to Design Great 404 Error Pages](https://www.interaction-design.org/literature/article/how-to-design-great-404-error-pages)

## 500 Server Error Pages

Server errors mean the application itself may be broken. The error page must function independently of everything that might have failed.

### Static HTML Requirement

The most critical rule for 500 pages: **they must be completely self-contained static HTML files with zero server-side dependencies.**

- Inline all CSS — do not rely on external stylesheets that the server may fail to deliver
- Inline all JavaScript (if any) — do not depend on bundled assets
- Do not use server-side templating, database calls, or API requests
- Do not load web fonts from external services (use system fonts or inline a minimal subset)
- Do not rely on a CDN that might also be down
- Store the file where the web server (Nginx, Apache) can serve it directly, bypassing the application layer

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Something went wrong</title>
  <style>
    /* All styles inlined — no external dependencies */
    body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; color: #1a1a1a; }
    h1 { font-size: 1.5rem; }
    a { color: #0055d4; }
  </style>
</head>
<body>
  <main>
    <h1>Something went wrong</h1>
    <p>We're having technical difficulties. Our team has been notified and is working on it.</p>
    <p>Try <a href="/">returning to the homepage</a> or refreshing the page in a few minutes.</p>
  </main>
</body>
</html>
```

### Messaging

- Acknowledge the problem honestly: "Something went wrong on our end"
- Do not expose technical details (stack traces, error codes, server names)
- Provide retry guidance: "Try again in a few minutes"
- If the issue is known (planned maintenance), say when it will be resolved
- Include a link to a status page if one exists
- Offer alternative contact methods (email, phone) for urgent needs

### What Not to Do

- Do not show raw server error output or stack traces
- Do not require JavaScript to render the page
- Do not load the error page through the same application pipeline that just crashed
- Do not promise an exact resolution time unless you are certain

Sources: [Serpstat — How to Create a 500 Error Page Template](https://serpstat.com/blog/how-to-create-a-500-error-page/), [Medium — How to Design Better Error Pages](https://medium.com/design-ideas-thoughts/designing-error-pages-8d82e16e3472)

## Offline Pages (Service Worker Fallback)

When users lose their network connection, the browser shows a generic "No internet" page. With a service worker, you can replace this with a branded, helpful offline page.

### Implementation

**Register the service worker** from your main page:
```javascript
window.addEventListener("load", () => {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/service-worker.js");
  }
});
```

**Pre-cache the offline page** during the service worker install event:
```javascript
const CACHE_NAME = "offline-v1";

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.add("/offline.html"))
  );
});
```

**Serve it when navigation fails:**
```javascript
self.addEventListener("fetch", (event) => {
  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request).catch(() =>
        caches.match("/offline.html")
      )
    );
  }
});
```

### Self-Contained HTML

The offline page must be completely self-contained because no network requests will succeed:

- Inline all CSS and JavaScript
- Do not reference external images, fonts, or scripts
- Use SVG for any illustrations (inline, not linked)
- Keep the file size small — it is cached on every visit

### Messaging and Functionality

- State clearly that the user is offline: "You're not connected to the internet"
- Provide a retry mechanism: a manual "Try again" button and/or automatic reconnection
- Listen for the `online` event to reload automatically when connectivity returns
- If the app caches content, indicate what is available offline vs what requires a connection
- Consider showing recently viewed or cached pages as navigation options

```javascript
// Auto-reload when connection returns
window.addEventListener("online", () => {
  window.location.reload();
});

// Manual retry with polling
document.getElementById("retry").addEventListener("click", () => {
  fetch("/").then(() => window.location.reload())
    .catch(() => { /* still offline, show message */ });
});
```

### Progressive Enhancement

- If the app uses a service worker for broader caching (not just the offline page), indicate which content is cached and available
- Mark cached content visually so users understand what is fresh vs potentially stale
- For content-heavy sites, consider caching the last few visited pages for offline reading

Sources: [web.dev — Create an Offline Fallback Page](https://web.dev/articles/offline-fallback-page), [Chrome Developers — Managing Fallback Responses with Workbox](https://developer.chrome.com/docs/workbox/managing-fallback-responses/)

## HTTP Status Codes Designers Should Know

Not every status code needs a custom page, but designers and developers should understand what users experience for each.

### Redirects (3xx) — No Custom Page Needed

| Code | Name | What happens |
|------|------|-------------|
| 301 | Moved Permanently | URL has permanently changed. Browser automatically redirects. Update all internal links. Search engines transfer ranking to the new URL. |
| 302 | Found | Temporary redirect. Browser goes to the new URL but bookmarks and search engines keep the original. Use for A/B tests, geo-routing, or temporary moves. |
| 307 | Temporary Redirect | Like 302 but guarantees the HTTP method does not change (important for POST requests). |
| 308 | Permanent Redirect | Like 301 but guarantees the HTTP method does not change. |

Redirects are invisible to users — no error page is shown. They matter for SEO and for developers maintaining correct link structures.

### Client Errors (4xx) — User-Facing Pages

| Code | Name | When to show a custom page | User-facing message |
|------|------|---------------------------|-------------------|
| 400 | Bad Request | Rarely — usually caused by malformed requests from code, not users | "Something went wrong with your request. Try going back and trying again." |
| 401 | Unauthorised | Yes — redirect to login or show a login prompt | "You need to sign in to view this page." |
| 403 | Forbidden | Yes — the user is authenticated but lacks permission | "You don't have permission to access this page. Contact your administrator if you think this is a mistake." |
| 404 | Not Found | Always — the most common user-facing error | See 404 section above. |
| 410 | Gone | Yes — content was intentionally and permanently removed | "This content has been removed. It is no longer available." Unlike 404, this signals the removal was deliberate. |
| 429 | Too Many Requests | Sometimes — for rate-limited APIs or aggressive crawlers | "You've made too many requests. Please wait a moment and try again." |

### Server Errors (5xx) — Operational Pages

| Code | Name | When to show a custom page | User-facing message |
|------|------|---------------------------|-------------------|
| 500 | Internal Server Error | Always — generic server failure | See 500 section above. |
| 502 | Bad Gateway | Yes — upstream service is down | "We're having trouble connecting to our services. Please try again in a moment." |
| 503 | Service Unavailable | Yes — planned maintenance or overload | "We're temporarily down for maintenance. We expect to be back by [time]." Include `Retry-After` header. |
| 504 | Gateway Timeout | Yes — upstream service is too slow | "The page took too long to load. Please try again." |

### Key Distinctions

- **401 vs 403**: 401 means "who are you?" (not authenticated). 403 means "I know who you are, but you can't access this" (not authorised). Show a login form for 401; show a permission message for 403.
- **404 vs 410**: 404 means "we don't know this URL." 410 means "this used to exist but was deliberately removed." 410 tells search engines to de-index the URL faster.
- **500 vs 503**: 500 means something broke unexpectedly. 503 means the service is intentionally unavailable (maintenance) or temporarily overloaded. 503 should include a `Retry-After` header.

Source: [MDN — HTTP Response Status Codes](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status)

## Accessibility

Error pages are visited by all users, including those using assistive technologies. They must meet the same accessibility standards as every other page.

### Heading Structure

- Use a single `<h1>` that clearly states the error condition
- Use `<h2>` elements for subsections (search, suggested links, support options)
- Do not skip heading levels — screen reader users navigate by headings to orient themselves
- Do not use headings purely for visual styling

### Descriptive Text

- Write error descriptions in plain language — avoid jargon and technical codes
- Do not rely solely on colour or icons to communicate the error state
- Ensure sufficient colour contrast (minimum 4.5:1 for body text, 3:1 for large text per WCAG 2.1 AA)
- Provide text alternatives for any illustrative images or icons

### Functional Navigation

- All links must have descriptive, unique link text (not "Click here")
- The search form must have a visible, associated `<label>`
- Interactive elements (buttons, links, form fields) must be keyboard-accessible
- Focus order must be logical — ideally the primary action receives focus or is near the top
- Error pages must work without JavaScript (especially 500 and offline pages)

### Language and Page Title

- Set the `lang` attribute on `<html>`
- Set a descriptive `<title>` that includes the error state: "Page not found — Site Name"
- The page title is the first thing screen readers announce — make it immediately informative

### ARIA Considerations

- Use `role="search"` on the search form landmark
- Use `aria-label="Suggested pages"` or similar on navigation sections to distinguish them from the main site navigation
- Do not use `role="alert"` on the entire page — it is not a dynamic notification, it is a full page

Sources: [W3C WAI — Page Structure: Headings](https://www.w3.org/WAI/tutorials/page-structure/headings/), [W3C WAI — Form Notifications](https://www.w3.org/WAI/tutorials/forms/notifications/), [The A11Y Project — Accessible Heading Structure](https://www.a11yproject.com/posts/how-to-accessible-heading-structure/)

## Common Mistakes

### Generic Messages
Showing only "404" or "Error" with no explanation. Users who are not web-savvy do not know what HTTP status codes mean. Always translate the code into a plain-language explanation.

### Dead-End Pages
Error pages with no links, no search, no navigation — just a message. Users have nowhere to go except the browser's back button (which they may not think to use) or closing the tab entirely.

### Humour Over Helpfulness
Clever illustrations and jokes are fine as secondary decoration, but they must not replace functional content. A witty 404 page that offers no search box, no links, and no way forward is still a dead end. Humour is also subjective — what amuses one user frustrates another, especially if they are in a hurry or encountering the error repeatedly.

### Broken Styling
Error pages that depend on the same CSS/JS pipeline as the rest of the site. When the server is down (500), those assets are unavailable too, producing an unstyled or blank page. Always test error pages with assets blocked.

### Missing Site Navigation
Removing the header, footer, or sidebar from error pages. Users lose their sense of place within the site. Keep the standard navigation structure intact, especially on 404 pages.

### Exposing Technical Details
Showing stack traces, server paths, database errors, or internal IP addresses on error pages. This is both a usability failure (users cannot act on this information) and a security risk.

### No Mobile Consideration
Error pages that are not responsive. Users on mobile devices encounter errors at the same rate as desktop users. Ensure error pages work at all viewport sizes.

### Auto-Redirecting Too Quickly
Some sites auto-redirect from error pages to the homepage after a few seconds. This disorients users, removes their ability to read the message, and creates accessibility problems for slow readers and screen reader users.

Sources: [NN/g — Error-Message Guidelines](https://www.nngroup.com/articles/error-message-guidelines/), [NN/g — Hostile Patterns in Error Messages](https://www.nngroup.com/articles/hostile-error-messages/), [CXL — Error Messages: Best Practices and Common Mistakes](https://cxl.com/blog/error-messages/), [Smashing Magazine — Designing Better Error Messages UX](https://www.smashingmagazine.com/2022/08/error-messages-ux-design/)

## When Custom Error Pages Matter Most

Not all sites need the same level of error page investment. Prioritise custom error pages based on impact:

**High priority:**
- E-commerce sites — a 404 on a product page means lost revenue. Include search, category links, and similar products.
- Content-heavy sites (news, documentation, blogs) — content moves, URLs change, and inbound links break frequently. Search and related content are essential.
- SaaS applications — users behind a login encountering errors need clear guidance on whether the issue is on their end or yours, and how to get support.

**Medium priority:**
- Marketing sites — fewer pages, fewer broken links, but a branded 404 still maintains professionalism.
- Portfolio sites — a custom 404 demonstrates attention to detail.

**Lower priority (but still worth doing):**
- Internal tools — users are more technical and tolerant, but a helpful error page still saves support requests.
- Single-page applications — most errors are handled in-app, but the server should still have fallback HTML for when the SPA itself fails to load.

**Always implement:**
- A custom 404 page (every site gets mistyped URLs and broken inbound links)
- A static 500 page (every server can fail)
- An offline page if the site uses a service worker
