/** @type {import('tailwindcss').Config} */
export default {
    content: ['./src/**/*.{astro,html,js,jsx,md,mdx,ts,tsx}'],
    theme: {
        extend: {
            colors: {
                // Palestinian flag palette. Names mirror the brand tokens
                // defined in src/styles/tokens.css so both systems stay in
                // sync. Values are kept in sync with the OKLCH tokens
                // (resolved to sRGB for Tailwind's hex-based utilities).
                palestine: {
                    black: '#000000',
                    white: '#fcfcfc',
                    green: '#239e3a',
                    'green-deep': '#1d7a2c',
                    red: '#e4312b',
                    'red-deep': '#b3231f',
                },
                // Neutral surface tokens reused from the brand palette.
                ink: '#1a1a1a',
                'ink-soft': '#3d3d3d',
                'ink-muted': '#5e5e5e',
                paper: '#fcfcfc',
                'paper-soft': '#f4f4f4',
                'paper-edge': '#e3e3e3',
            },
            fontFamily: {
                // Bold display face for headings, loaded from /fonts/ in
                // src/styles/global.css. Falls back through a stack of
                // condensed/impact fonts if the webfont fails to load.
                display: [
                    '"The Bold Font"',
                    'Boldonse',
                    'Anton',
                    'Oswald',
                    '"Arial Black"',
                    'Impact',
                    'sans-serif',
                ],
                // Body sans-serif, also self-hosted under /fonts/.
                sans: [
                    'Poppins',
                    'Inter',
                    '-apple-system',
                    'BlinkMacSystemFont',
                    '"Segoe UI"',
                    'Roboto',
                    '"Helvetica Neue"',
                    'Arial',
                    'sans-serif',
                ],
            },
        },
    },
    plugins: [],
};
