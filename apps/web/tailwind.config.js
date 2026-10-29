/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      // Reqaz brand: Circe/Room are licensed fonts, so the app uses Jost (open licence, same geometric style) and Noto Sans Arabic.
      fontFamily: { sans: ['Jost', '"Noto Sans Arabic"', 'system-ui', 'sans-serif'] },
      colors: {
        // Reqaz palette (brand guideline): gold #C1A287, sand #E7E2DA, grey Pantone 424 C #6D6968, Pantone 425 C #58595B.
        brand: { 50: '#f6f3ef', 100: '#e7e2da', 500: '#c1a287', 600: '#a8876b', 700: '#58595b', 800: '#434447', 900: '#1c1c1d' },
        gold: '#c1a287', sand: '#e7e2da', ink: '#58595b',
      },
    },
  },
  plugins: [],
};
