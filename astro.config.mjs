// @ts-check
import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';

// https://astro.build/config
export default defineConfig({
    outDir: 'public',
    publicDir: 'static',
    i18n: {
        defaultLocale: 'fr',
        locales: ['fr'],
        routing: {
            prefixDefaultLocale: false,
        },
    },
    integrations: [tailwind()],
});
