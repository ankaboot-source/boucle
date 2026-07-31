// @ts-check
import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';

// https://astro.build/config
export default defineConfig({
    outDir: 'public',
    publicDir: 'static',
    // 301 redirects emitted by the static build. The site is SSG (no
    // SSR adapter), so `Astro.redirect(...)` in a page module can't
    // produce an HTTP redirect — these mappings are emitted as
    // `_redirects` / `_headers`-equivalent files by Astro at build time.
    redirects: {
        // /mobilisation/ → /right-to-resist/ (rename of the bucket
        // landing page; per-entry URLs at /mobilisation/<slug>/ are
        // intentionally kept unchanged).
        '/mobilisation': '/right-to-resist',
    },
    i18n: {
        defaultLocale: 'fr',
        locales: ['fr'],
        routing: {
            prefixDefaultLocale: false,
        },
    },
    integrations: [tailwind()],
});
