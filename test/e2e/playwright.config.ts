// Playwright config for the tier-1 browser config-dial e2e.
//
// No `webServer`: the Docker `e2e-test` stage already renders + serves the REAL
// runtime dist via the entrypoint (see test/e2e/run-in-image.sh); this config
// only drives Chromium against the URL passed in OWV_BASE_URL. The app dials a
// dead test host, so the WebRTC/WebSocket connection fails asynchronously --
// that is EXPECTED and is not a harness failure (the specs assert the *dial
// intent*, not a successful connection). Timeouts are kept modest so a missing
// dial fails fast rather than hanging the build.
import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.OWV_BASE_URL || 'http://127.0.0.1:5174';

export default defineConfig({
  testDir: '.',
  testMatch: ['**/*.spec.ts'],
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 1,
  reporter: [['list']],
  timeout: 30_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL,
    headless: true,
    // The connection to the dead test host fails async; ignore those network
    // errors at the navigation level (we assert dial intent, not load success).
    ignoreHTTPSErrors: true,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
