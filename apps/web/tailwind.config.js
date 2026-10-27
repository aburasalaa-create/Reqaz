/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: { sans: ['"Noto Sans"', '"Noto Sans Arabic"', 'system-ui', 'sans-serif'] },
      colors: {
        brand: { 50: '#eef5fb', 100: '#d5e6f4', 500: '#1f6fb2', 600: '#185d97', 700: '#0f4c81', 800: '#0b3a63', 900: '#082a48' },
      },
    },
  },
  plugins: [],
};
