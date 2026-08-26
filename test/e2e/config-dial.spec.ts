// Tier-1 browser config-dial e2e.
//
// Goal: prove that the bundle ACTUALLY SERVED by the runtime image (after the
// entrypoint renders the sentinel templates) feeds the injected
// SIGNALING_SERVER:SIGNALING_PORT (and, for stream-only, the media port) into
// the streaming client at the browser layer. The bats specs prove the
// entrypoint `sed` is correct; this proves the rendered bundle uses those
// values once a real Chromium boots it. No GPU / Isaac / Kit needed -- the app
// dials a dead test host and we record what it dials.
//
// We DO NOT import anything from @nvidia. Instead we wrap window.WebSocket and
// window.RTCPeerConnection (via addInitScript, before app code runs) to capture
// the constructor arguments the streaming library passes, while still building
// the real objects so the app's normal (failing) connect path proceeds.
//
// Two modes (selected by OWV_MODE):
//   - stream-only: OURS. Asserts the `owv:dial` CustomEvent main.ts dispatches
//     (the stable, primary signal) plus a best-effort WebSocket-URL check.
//   - usd-viewer: BLACK BOX. The upstream web-viewer-sample is built UNMODIFIED
//     (PRD D2), so it emits NO `owv:dial` event. We assert on the WebSocket dial
//     it makes, with a served-asset string-presence fallback.

import { test, expect, type Page } from '@playwright/test';

interface DialRecord {
  ws: string[];
  pc: unknown[];
}

interface DialEvent {
  server: unknown;
  port: unknown;
  mediaPort: unknown;
}

declare global {
  interface Window {
    __OWV_DIALS__: DialRecord;
    __OWV_DIAL_EVENT__: DialEvent | null;
  }
}

const BASE_URL = process.env.OWV_BASE_URL || 'http://127.0.0.1:5174';
const MODE = process.env.OWV_MODE || 'stream-only';
const EXPECT_SERVER = process.env.OWV_EXPECT_SERVER || '';
const EXPECT_PORT = process.env.OWV_EXPECT_PORT || '';
const EXPECT_MEDIA = process.env.OWV_EXPECT_MEDIA; // optional

// Installed BEFORE any app script runs. Records dial targets without blocking
// the real connection attempt (which fails async against the dead test host --
// that is expected). Also captures the owv:dial CustomEvent for stream-only.
async function installDialRecorders(page: Page): Promise<void> {
  await page.addInitScript(() => {
    window.__OWV_DIALS__ = { ws: [], pc: [] };
    window.__OWV_DIAL_EVENT__ = null;

    const RealWebSocket = window.WebSocket;
    // Preserve the real prototype/statics (incl. CONNECTING/OPEN/CLOSING/CLOSED,
    // which the library may read) so it still gets a usable WS.
    const WrappedWebSocket = function (
      this: unknown,
      url: string | URL,
      protocols?: string | string[],
    ) {
      try {
        window.__OWV_DIALS__.ws.push(String(url));
      } catch {
        /* recording must never break the app */
      }
      return new RealWebSocket(url, protocols);
    } as unknown as typeof WebSocket;
    WrappedWebSocket.prototype = RealWebSocket.prototype;
    // Copy the readonly static numeric constants (CONNECTING/OPEN/CLOSING/CLOSED
    // and any others) without tripping TS's read-only check on named props.
    for (const key of Object.getOwnPropertyNames(RealWebSocket)) {
      if (key === 'prototype' || key === 'length' || key === 'name') {
        continue;
      }
      try {
        Object.defineProperty(
          WrappedWebSocket,
          key,
          Object.getOwnPropertyDescriptor(RealWebSocket, key) as PropertyDescriptor,
        );
      } catch {
        /* skip non-redefinable statics */
      }
    }
    window.WebSocket = WrappedWebSocket;

    if (typeof window.RTCPeerConnection !== 'undefined') {
      const RealRTC = window.RTCPeerConnection;
      const WrappedRTC = function (this: unknown, config?: RTCConfiguration) {
        try {
          window.__OWV_DIALS__.pc.push(config ?? null);
        } catch {
          /* recording must never break the app */
        }
        return new RealRTC(config);
      } as unknown as typeof RTCPeerConnection;
      WrappedRTC.prototype = RealRTC.prototype;
      window.RTCPeerConnection = WrappedRTC;
    }

    document.addEventListener('owv:dial', (e: Event) => {
      const detail = (e as CustomEvent).detail as DialEvent;
      window.__OWV_DIAL_EVENT__ = {
        server: detail?.server,
        port: detail?.port,
        mediaPort: detail?.mediaPort,
      };
    });
  });
}

test.beforeEach(() => {
  expect(EXPECT_SERVER, 'OWV_EXPECT_SERVER must be set').not.toBe('');
  expect(EXPECT_PORT, 'OWV_EXPECT_PORT must be set').not.toBe('');
});

test('stream-only dials the injected target', async ({ page }) => {
  test.skip(MODE !== 'stream-only', 'OWV_MODE is not stream-only');

  const pageErrors: string[] = [];
  page.on('pageerror', (err) => pageErrors.push(String(err)));

  await installDialRecorders(page);
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });

  // PRIMARY assertion: the owv:dial CustomEvent (stable, emitted by OUR app).
  await expect
    .poll(() => page.evaluate(() => window.__OWV_DIAL_EVENT__), {
      message: 'owv:dial event was never dispatched',
      timeout: 15_000,
    })
    .not.toBeNull();

  const dial = await page.evaluate(() => window.__OWV_DIAL_EVENT__);
  expect(dial, 'owv:dial detail').not.toBeNull();
  expect(String(dial?.server)).toBe(EXPECT_SERVER);
  expect(String(dial?.port)).toBe(EXPECT_PORT);
  if (EXPECT_MEDIA === undefined || EXPECT_MEDIA === '') {
    // D1: unset MEDIA_PORT renders to null -> mediaPort omitted/null.
    expect(dial?.mediaPort == null).toBe(true);
  } else {
    expect(dial?.mediaPort).toBe(Number(EXPECT_MEDIA));
  }

  // BONUS (best-effort): the streaming library should open a signaling WS to
  // the same server. The lib may dial differently (or not synchronously); log
  // and tolerate -- the event above is the contract, the WS is corroboration.
  const wsUrls = await page.evaluate(() => window.__OWV_DIALS__.ws);
  if (wsUrls.length > 0) {
    const hit = wsUrls.some((u) => u.includes(EXPECT_SERVER));
    if (!hit) {
      // eslint-disable-next-line no-console
      console.log(`[e2e] WS bonus: no WS URL contained ${EXPECT_SERVER}: ${JSON.stringify(wsUrls)}`);
    }
  } else {
    // eslint-disable-next-line no-console
    console.log('[e2e] WS bonus: library opened no WebSocket synchronously (tolerated)');
  }

  // The app must NOT have surfaced a config error (a dead-host connection
  // failure is fine; an invalid/unsubstituted config is not).
  const status = page.locator('#stream-status');
  await expect(status).not.toHaveClass(/error/);
  await expect(status).not.toContainText(/invalid/i);

  // The collector above was registered and then never read, so an uncaught
  // exception in OUR OWN bundle passed this gate silently -- while the sibling
  // usd-viewer test, for the app we do NOT control, asserted it. The dial event
  // is dispatched BEFORE the streaming library is wired, so main.ts could throw
  // while wiring the status callbacks and the primary assertion above would
  // still pass, with #stream-status neither in `error` nor reading `invalid`.
  // Dying against the dead test host is expected and is not an uncaught error:
  // the connect rejection is caught in main.ts.
  expect(pageErrors, `uncaught page errors: ${pageErrors.join(' | ')}`).toEqual([]);
});

test('usd-viewer dials the injected target', async ({ page }) => {
  test.skip(MODE !== 'usd-viewer', 'OWV_MODE is not usd-viewer');

  // BLACK BOX: usd-viewer serves the UPSTREAM web-viewer-sample build UNMODIFIED
  // (PRD D2), so it cannot dispatch the owv:dial event -- we never add code to
  // it. We assert on the raw WebSocket dial the bundle makes, with a served-JS
  // string-presence fallback when the app does not auto-dial within the window.
  const pageErrors: string[] = [];
  page.on('pageerror', (err) => pageErrors.push(String(err)));

  await installDialRecorders(page);
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });

  // The upstream sample does NOT auto-dial: it starts on `Forms.AppOnly` and
  // only reaches `AppStreamer.connect` after a Next click this spec never
  // performs, so this poll has always timed out into the fallback below and the
  // `dialed` branch has always been dead code. The window is kept -- if a
  // future upstream build does auto-dial, the stronger assertion should fire --
  // but it is SHORT: fifteen seconds of guaranteed waiting was being spent on
  // every PR run to reach a branch that cannot be taken, and the fallback is
  // now a complete assertion rather than a partial one.
  let dialed = false;
  try {
    await expect
      .poll(() => page.evaluate(() => window.__OWV_DIALS__.ws.length), {
        message: 'usd-viewer opened no WebSocket within the window',
        timeout: 2_000,
      })
      .toBeGreaterThan(0);
    dialed = true;
  } catch {
    dialed = false;
  }

  if (dialed) {
    const wsUrls = await page.evaluate(() => window.__OWV_DIALS__.ws);
    const hit = wsUrls.some(
      (u) => u.includes(EXPECT_SERVER) && u.includes(EXPECT_PORT),
    );
    expect(
      hit,
      `no WS URL carried ${EXPECT_SERVER}:${EXPECT_PORT}; got ${JSON.stringify(wsUrls)}`,
    ).toBe(true);
  } else {
    // FALLBACK: no auto-dial (the landing screen waits for a click). Prove the
    // SERVED bundle carries BOTH injected values and that BOTH sentinels were
    // rendered away -- i.e. the injection reached the real dist.
    //
    // The port half is not decoration. This is the ONLY per-PR cover usd-viewer
    // has, and before this the fallback checked the server alone: an entrypoint
    // regression that dropped SIGNALING_PORT, or a build that stopped emitting
    // `"__OWV_PORT__"` into the usd-viewer bundle, would have left this test
    // green. It is the same gap that was closed on the stream-only side, where
    // the injected port is now 49177 precisely so it cannot be confused with
    // the 49100 default that every other assertion used to accept.
    const assets = await page.evaluate(async () => {
      const html = await (await fetch('/')).text();
      const srcs = Array.from(html.matchAll(/src="([^"]+\.js)"/g)).map((m) => m[1]);
      const bodies: string[] = [];
      for (const s of srcs) {
        try {
          bodies.push(await (await fetch(s)).text());
        } catch {
          /* skip unreachable asset */
        }
      }
      return bodies.join('\n');
    });
    expect(assets, 'served JS assets fetched').not.toBe('');
    expect(assets.includes(EXPECT_SERVER), `served JS carries ${EXPECT_SERVER}`).toBe(true);
    expect(assets.includes('__OWV_SERVER__'), 'server sentinel was rendered away').toBe(false);
    expect(assets.includes(EXPECT_PORT), `served JS carries ${EXPECT_PORT}`).toBe(true);
    expect(assets.includes('__OWV_PORT__'), 'port sentinel was rendered away').toBe(false);
  }

  expect(pageErrors, `uncaught page errors: ${pageErrors.join(' | ')}`).toEqual([]);
});
