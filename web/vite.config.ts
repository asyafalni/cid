import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Dev proxies /v0 to a running `cid admin serve`; production is the same
// origin because the build is embedded in the server binary.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/v0': 'http://127.0.0.1:7070',
    },
  },
});
