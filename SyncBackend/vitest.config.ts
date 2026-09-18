import { defineConfig } from 'vitest/config';
import { cloudflareTest } from '@cloudflare/vitest-pool-workers';
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' }, remoteBindings: false })],
  test: { testTimeout: 30000, hookTimeout: 30000, fileParallelism: false }
});
