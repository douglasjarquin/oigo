import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://douglasjarquin.github.io/oigo',
  base: '/oigo',
  output: 'static',
  build: {
    format: 'directory',
  },
});
