// One warm palette and the system font. The second block maps the shared transaction dialogs' color names onto it.
const cream = '#fbf6ec', paper = '#fffdf8', crust = '#e8dcc6', ink = '#2a211a', muted = '#6f6253', tomato = '#b93a0d'
const system = ['ui-rounded', 'system-ui', '-apple-system', '"Segoe UI"', 'sans-serif']

const config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: cream, card: paper, line: crust, ink, muted, accent: tomato,
        amber: '#f5b942', teal: '#f5b942', err: '#b3261e',
        bone: paper,
        smoke: { 75: cream, 200: crust, 300: crust, 500: muted, 600: muted, 700: ink },
        grey: { 25: cream, 900: ink },
        bluebs: { 25: '#fdf0e3', 50: '#fbe4cf', 100: '#f8d6b8', 500: tomato, 600: tomato, 700: '#99300b', 800: '#7a2609' },
        melon: { 400: '#f5b942' },
        split: { 50: '#fdecea', 800: '#b3261e' },
      },
      fontFamily: { sans: system, beatrice: system, 'agrandir-wide': system, agrandir: system },
    },
  },
  plugins: [],
}

export default config
