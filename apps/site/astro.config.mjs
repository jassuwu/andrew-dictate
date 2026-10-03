// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  // og cards and canonical links need absolute urls; this is where they come from
  site: 'https://dictate.jass.gg',
  // astro's dev toolbar sits at the bottom centre, which is where the lamp is
  devToolbar: { enabled: false },
  vite: {
    plugins: [tailwindcss()]
  }
});