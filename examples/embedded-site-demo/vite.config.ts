import { defineConfig } from 'vite';

// Stream-only demo. No React / bootstrap; the only runtime dependency is the
// streaming library, bundled normally. Dev + preview default to 8080 so the
// example never collides with the main viewer on 5173.
export default defineConfig({
  server: { port: 8080, host: true },
  preview: { port: 8080, host: true },
});
