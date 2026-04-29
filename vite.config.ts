import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Minimal Vite config. The dev server runs on 5173 by default; preview is used
// for the `npm start` entrypoint that App Service invokes.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173
  },
  preview: {
    port: 8080,
    host: true
  }
});
