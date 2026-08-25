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
import { join } from 'node:path';

const baseURL = process.env.OWV_BASE_URL || 'http://127.0.0.1:5174';

// Tier B (#48) runs in a container with a host dir bind-mounted for evidence
// (browser trace, failure screenshot). Unset everywhere else -- the per-PR
// tier-1 gate keeps Playwright's default `test-results`, which it never writes
// to on a passing run.
const artifactDir = process.env.OWV_ARTIFACT_DIR || '';

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
  ...(artifactDir ? { outputDir: join(artifactDir, 'playwright') } : {}),
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
      testMatch: ['**/config-dial.spec.ts'],
      use: { ...devices['Desktop Chrome'] },
    },
    // The status-state specs (#62) drive real media through an in-page WebRTC
    // loopback, which needs two Chromium switches. They live in their own
    // project ON PURPOSE: appending launch args to the shared `use` would also
    // change how config-dial's browser starts (a second --disable-features
    // wins over Playwright's default one), and that suite must keep launching
    // byte-identically to before.
    //   --disable-features=WebRtcHideLocalIpsWithMdns: host candidates carry
    //     real local IPs instead of .local names, so the loopback pair does not
    //     depend on mDNS resolution inside the build container.
    //   --autoplay-policy=no-user-gesture-required: no user gesture exists in a
    //     headless run; without it a paused element would never decode a frame.
    {
      name: 'chromium-loopback',
      testMatch: ['**/status-loopback.spec.ts'],
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: {
          args: [
            '--disable-features=WebRtcHideLocalIpsWithMdns',
            '--autoplay-policy=no-user-gesture-required',
          ],
        },
      },
    },
    // Tier B visual acceptance (#48): a REAL Kit producer -> the viewer -> this
    // browser, asserting real frames render. NOT part of the per-PR gate --
    // run-in-image.sh selects the two projects above explicitly, and this one
    // is driven only by run-tier-b.sh on a GPU host.
    //
    // Same two switches as the loopback project, for the same reasons (real
    // local ICE candidates instead of mDNS names inside a container; no user
    // gesture exists headless, so without the autoplay override the element
    // would never decode a frame). Kept in its own project rather than shared
    // with chromium-loopback because the two suites need different projects to
    // be selectable independently, and appending args to the shared `use`
    // would change how config-dial's browser starts.
    //
    // trace/screenshot on failure: the nightly job has no human watching, so a
    // failure must leave behind enough to diagnose it without a rerun.
    {
      name: 'chromium-tier-b',
      testMatch: ['**/tier-b-visual.spec.ts'],
      use: {
        ...devices['Desktop Chrome'],
        trace: 'retain-on-failure',
        screenshot: 'only-on-failure',
        launchOptions: {
          args: [
            '--disable-features=WebRtcHideLocalIpsWithMdns',
            '--autoplay-policy=no-user-gesture-required',
          ],
        },
      },
    },
  ],
});
