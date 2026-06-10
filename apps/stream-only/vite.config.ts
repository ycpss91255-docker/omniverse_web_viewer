import { defineConfig } from 'vite';

// Full-screen stream-only viewer. The only runtime dependency is the streaming
// library (via stream-core), bundled normally. Dev/preview default to 5173 to
// match the container SERVE_PORT default.
export default defineConfig({
  server: { port: 5173, host: true },
  preview: { port: 5173, host: true },
});
