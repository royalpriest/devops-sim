import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The Rails API runs on :3000. Proxying keeps everything same-origin in dev.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': 'http://localhost:3000',
      '/cable': { target: 'ws://localhost:3000', ws: true },
    },
  },
})
