import { defineConfig, devices } from '@playwright/test';

// The e2e suite runs against the real binary with the dashboard embedded
// (docs/dashboard.md: budgets and acceptance tests are measured in CI).
// It needs docker-compose.test.yml up and `zig build` done; global setup
// seeds a small dataset through the actual CLI.
const port = 7177;

export default defineConfig({
  testDir: './e2e',
  globalSetup: './e2e/setup.ts',
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    ...devices['Desktop Chrome'],
  },
  webServer: {
    command: `../zig-out/bin/cid admin serve --port ${port}`,
    url: `http://127.0.0.1:${port}/v0/ping`,
    reuseExistingServer: true,
    env: {
      CID_DB: 'host=127.0.0.1 port=5433 user=cid password=cid-test dbname=cid_test',
      CID_S3_ENDPOINT: 'http://127.0.0.1:8333',
      CID_S3_ACCESS_KEY: 'cid-test-key',
      CID_S3_SECRET_KEY: 'cid-test-secret',
      CID_TOKEN: 'e2e-dashboard-token',
    },
  },
});
