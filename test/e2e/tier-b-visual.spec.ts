// Tier B visual acceptance -- a REAL Kit producer, the real viewer, real frames (#48).
//
// This is the last piece of "CI proves there is actually a picture, so a human
// never has to look at the browser again". Everything below Tier B stops one
// step short of that claim:
//   - the bats specs prove the entrypoint renders the right values;
//   - config-dial.spec.ts proves the booted bundle DIALS them (dead host);
//   - status-loopback.spec.ts proves the viewer REACTS correctly to media, but
//     the media is a canvas the spec itself paints -- it proves the reaction,
//     not the picture.
// Here the media comes from `ghcr.io/ycpss91255-docker/isaac-stream-source`
// (isaac#223 / isaac PR #243): a pinned Kit streaming experience rendering a
// deterministic scene -- DomeLight + DistantLight over a 12x12 procedurally
// built checkerboard floor, fixed camera, RTX auto-exposure disabled -- chosen
// precisely so a connecting browser always gets a NON-BLACK frame. A black
// frame here is therefore a real failure, not scene luck.
//
// The five things asserted, in order, against ONE session in ONE test:
//   1. an RTCPeerConnection reaches connectionState 'connected'
//   2. a remote track arrives
//   3. #remote-video reports videoWidth > 0 and decodes frames
//   4. a frame sampled off the element is NOT BLACK
//   5. the readout clears itself because a real picture rendered -- the same
//      #53 code path status-loopback drives with a synthetic stream, here
//      closed against a real one.
// One test rather than five is a hard requirement, not a preference; see the
// comment above the test for what happened when they were five.
//
// SCOPE: `stream-only` ONLY, deliberately. Issue #48's acceptance criteria ask
// for both viewer modes, which is wrong against an Isaac-family producer: #18
// established that the `usd-viewer` app (the upstream web-viewer-sample, built
// UNMODIFIED per D2) only works with the kit-app-template USD Viewer and blanks
// against Isaac Sim / other Kit apps BY DESIGN. Asserting a picture there would
// fail forever, so `usd-viewer` keeps its existing config-dial level of cover.
//
// WHERE IT RUNS: never per-PR and never on a hosted runner. `run-tier-b.sh`
// drives it inside the `e2e-test` image against a producer container on a GPU
// host; `script/ci/tier_b_visual_e2e.sh` orchestrates both. Its own Playwright
// project (`chromium-tier-b`) so the Chromium switches it needs cannot change
// how the per-PR suites launch.
import { test, expect, type Page } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const BASE_URL = process.env.OWV_BASE_URL || 'http://127.0.0.1:5174';
const ARTIFACT_DIR = process.env.OWV_ARTIFACT_DIR || '';

// Kit is already up and its scene built before the browser starts (the
// orchestrator waits for the producer's own scene-ready marker), so these
// windows cover the signaling handshake plus the first encoded frame, not an
// Isaac boot.
const CONNECT_TIMEOUT_MS = 120_000;
const FRAME_TIMEOUT_MS = 120_000;

// Bounded session warm-up, for a REPRODUCIBLE producer-side defect: the FIRST
// WebRTC session against a freshly booted producer never delivers video. Held
// one producer up and connected three browsers to it in sequence:
//   attempt 1: videoWidth stayed 0 for 60 s, 0 decoded frames, 22 session-start
//              retries from the library
//   attempt 2: 3461 frames in 60 s, 1920x1080, mean luma 152.3
//   attempt 3: 3525 frames in 60 s, 1920x1080, mean luma 152.3
// Same producer, same flags, only the ordinal differs -- and it is the same
// family isaac#233 opened ("a Kit that boots, opens the signaling socket, and
// then dies the moment a real client attaches"). Filed upstream; tracked in the
// PR. So the single test below reloads -- each reload is a NEW session --
// until frames actually flow, then asserts against that session.
//
// This CANNOT hide a real regression: a producer that never delivers a picture
// exhausts the attempts and fails that test, which IS the whole gate. It only
// declines to call the known first-session defect a viewer bug. Every attempt
// is logged so a run that suddenly needs more of them is visible.
//
// (The warm-up was a `beforeAll` fixture over five specs once; it is now inline
// in one test, for the reason recorded above the test itself -- this page
// cannot hold a live WebRTC session across test boundaries.)
const MAX_SESSION_ATTEMPTS = 4;
const SESSION_ATTEMPT_TIMEOUT_MS = 30_000;
// Gap between the two frame-counter reads that decide whether frames are
// ADVANCING rather than merely present. One second is far longer than a 60 fps
// inter-frame gap, so a live stream always moves the counter across it.
const FRAME_PROGRESS_SAMPLE_MS = 1_000;

// Non-black thresholds, on 0..255 Rec.709 luma. Deliberately loose: the point
// is "a picture arrived", not "the picture is exactly the reference scene", and
// an over-tight threshold would make a codec keyframe delay look like a bug.
// The lit checkerboard covers most of the frame, so a genuine render clears all
// three by a wide margin while a black or single-flat-colour frame clears none.
const MIN_MEAN_LUMA = 8;
const MIN_MAX_LUMA = 32;
const MIN_BRIGHT_FRACTION = 0.1;
const BRIGHT_PIXEL_LUMA = 16;
// Width the frame is downscaled to before it is read back. See sampleFrame:
// reading a full 1080p frame back on the main thread is enough to break the
// stream being measured.
const SAMPLE_WIDTH = 320;
// Poll interval for the frame sampler, for the same reason. Playwright's
// default ramp starts at 100 ms, which is far more often than a "has a picture
// arrived yet" question needs and hard enough on a headless decoder to change
// the answer.
const SAMPLE_INTERVAL_MS = 1_000;

interface PeerRecord {
  states: string[];
  tracks: number;
  connected: boolean;
}

interface FrameStats {
  width: number;
  height: number;
  meanLuma: number;
  maxLuma: number;
  brightFraction: number;
  sampled: number;
}

declare global {
  interface Window {
    __OWV_TIERB__: PeerRecord;
  }
}

/**
 * Record what the streaming library's peer connection actually does.
 *
 * Installed via addInitScript, so it is in place before any app script runs.
 * The library owns the RTCPeerConnection and exposes none of it, so the only
 * honest way to assert "the peer connection reached connected and a remote
 * track arrived" is to observe the constructor. The real object is still built
 * and returned untouched -- this observes, it does not substitute.
 */
async function installPeerRecorder(page: Page): Promise<void> {
  await page.addInitScript(() => {
    window.__OWV_TIERB__ = { states: [], tracks: 0, connected: false };

    const RealRTC = window.RTCPeerConnection;
    const WrappedRTC = function (this: unknown, config?: RTCConfiguration) {
      const pc = new RealRTC(config);
      const note = (): void => {
        try {
          window.__OWV_TIERB__.states.push(pc.connectionState);
          if (pc.connectionState === 'connected') {
            window.__OWV_TIERB__.connected = true;
          }
        } catch {
          /* recording must never break the app */
        }
      };
      pc.addEventListener('connectionstatechange', note);
      pc.addEventListener('track', () => {
        try {
          window.__OWV_TIERB__.tracks += 1;
        } catch {
          /* recording must never break the app */
        }
      });
      note();
      return pc;
    } as unknown as typeof RTCPeerConnection;
    WrappedRTC.prototype = RealRTC.prototype;
    // Carry the statics (generateCertificate and friends) so the library can
    // still reach anything it reads off the constructor.
    for (const key of Object.getOwnPropertyNames(RealRTC)) {
      if (key === 'prototype' || key === 'length' || key === 'name') {
        continue;
      }
      try {
        Object.defineProperty(
          WrappedRTC,
          key,
          Object.getOwnPropertyDescriptor(RealRTC, key) as PropertyDescriptor,
        );
      } catch {
        /* skip non-redefinable statics */
      }
    }
    window.RTCPeerConnection = WrappedRTC;
  });
}

/** Decoded frames delivered to #remote-video so far. */
function framesRendered(page: Page): Promise<number> {
  return page.evaluate(() => {
    const video = document.getElementById('remote-video') as HTMLVideoElement;
    return typeof video.getVideoPlaybackQuality === 'function'
      ? video.getVideoPlaybackQuality().totalVideoFrames
      : 0;
  });
}

/**
 * Sample the CURRENT picture off #remote-video and reduce it to luma stats.
 *
 * drawImage from a MediaStream-backed element does not taint the canvas (no
 * origin is involved), so getImageData is readable.
 *
 * The picture is DOWNSCALED to SAMPLE_WIDTH before the read, and that is not a
 * micro-optimisation -- it is required for the test to be non-destructive.
 * Kit negotiates 1920x1080; reading that back is an ~8 MB getImageData per
 * sample, on the main thread, in a headless browser whose GL is SwiftShader.
 * Polling it at Playwright's default ramp (from 100 ms) starved the decode
 * pipeline until the streaming library gave up with `Stream disconnected from
 * server, FrameGrabFailed.` -- the harness killed the very stream it was
 * measuring, and then correctly reported black frames. Observed, twice, before
 * this downscale and the 1 s poll interval below. drawImage does the scaling
 * on the way in, so the read is ~230 KB and the luma statistics are unchanged
 * for a "is there a picture" question. `width`/`height` are still reported from
 * the SOURCE video so the stats say what actually arrived.
 */
function sampleFrame(page: Page): Promise<FrameStats> {
  return page.evaluate(
    ({ brightPixelLuma, sampleWidth }) => {
      const video = document.getElementById('remote-video') as HTMLVideoElement;
      const empty = {
        width: video.videoWidth,
        height: video.videoHeight,
        meanLuma: 0,
        maxLuma: 0,
        brightFraction: 0,
        sampled: 0,
      };
      if (video.videoWidth === 0 || video.videoHeight === 0) {
        return empty;
      }
      const canvas = document.createElement('canvas');
      canvas.width = Math.min(sampleWidth, video.videoWidth);
      canvas.height = Math.max(
        1,
        Math.round((canvas.width * video.videoHeight) / video.videoWidth),
      );
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      if (!ctx) {
        return empty;
      }
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
      let sum = 0;
      let bright = 0;
      let max = 0;
      let sampled = 0;
      // Every 7th pixel: prime, so a checkerboard cannot alias onto only its
      // dark squares, and still thousands of samples at this size.
      for (let i = 0; i < data.length; i += 4 * 7) {
        const luma = 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
        sum += luma;
        sampled += 1;
        if (luma > brightPixelLuma) {
          bright += 1;
        }
        if (luma > max) {
          max = luma;
        }
      }
      return {
        width: video.videoWidth,
        height: video.videoHeight,
        meanLuma: sampled === 0 ? 0 : sum / sampled,
        maxLuma: max,
        brightFraction: sampled === 0 ? 0 : bright / sampled,
        sampled,
      };
    },
    { brightPixelLuma: BRIGHT_PIXEL_LUMA, sampleWidth: SAMPLE_WIDTH },
  );
}

/** Persist evidence a human (or a CI artifact browser) can look at afterwards. */
function saveArtifact(name: string, body: string | Buffer): void {
  if (!ARTIFACT_DIR) {
    return;
  }
  try {
    mkdirSync(ARTIFACT_DIR, { recursive: true });
    writeFileSync(join(ARTIFACT_DIR, name), body);
  } catch (err) {
    // Evidence is a nice-to-have; never fail the acceptance over a mount.
    // eslint-disable-next-line no-console
    console.log(`[tier-b] could not write ${name}: ${String(err)}`);
  }
}


/**
 * Wait until #remote-video is decoding frames that KEEP ADVANCING.
 *
 * "totalVideoFrames > 0" is not enough and the distinction is the whole point
 * of this issue: a session that delivers exactly one frame and then freezes
 * satisfies it, and a frozen frame is the false green Tier B exists to
 * eliminate. Observed here -- one decoded frame, then seven consecutive
 * byte-identical samples, then the session died. So this requires the counter
 * to move between two reads.
 */
async function framesAdvancing(page: Page, windowMs: number): Promise<boolean> {
  const deadline = Date.now() + windowMs;
  let previous = await framesRendered(page);
  while (Date.now() < deadline) {
    await page.waitForTimeout(FRAME_PROGRESS_SAMPLE_MS);
    const current = await framesRendered(page);
    if (current > previous && previous > 0) {
      return true;
    }
    previous = current;
  }
  return false;
}

// ONE test that owns ONE session from connect to teardown, deliberately.
//
// This started as five specs in a describe.serial sharing a page built in
// beforeAll, which reads better but does not work: the stream froze after a
// single frame every time, while a standalone single-test probe against the
// same producer, same image and same flags streamed 3500 frames at 1920x1080
// with a mean luma of 152 for a full minute. Whatever the test runner does
// around test boundaries, this page cannot hold a live WebRTC session across
// them -- so the structure that demonstrably holds a stream is the one used,
// and the five assertions live inside it in order. Nothing was weakened to get
// here: every threshold is what it was, and the picture assertion is still the
// one that decides the run.
test('a real Kit producer renders a real, non-black picture in a real browser', async ({
  browser,
}) => {
  test.setTimeout(
    MAX_SESSION_ATTEMPTS * SESSION_ATTEMPT_TIMEOUT_MS + FRAME_TIMEOUT_MS + 120_000,
  );

  const page = await browser.newPage();
  // Forward only what a failure report needs. The streaming library emits a
  // JSON line per signaling message -- thousands of them -- and piping that
  // firehose across CDP is both unreadable and more main-thread work on a page
  // whose decode budget is the thing under test.
  page.on('console', (msg) => {
    const text = msg.text();
    if (msg.type() === 'error' || /\[stream\]|FrameGrab|Terminated|disconnect/i.test(text)) {
      // eslint-disable-next-line no-console
      console.log(`[tier-b][page:${msg.type()}] ${text.slice(0, 300)}`);
    }
  });
  await installPeerRecorder(page);

  try {
    // --- Session warm-up (bounded, logged) ---------------------------------
    // addInitScript re-runs on every navigation, so each attempt starts with a
    // clean recorder and everything asserted below belongs to the session that
    // actually carried a picture.
    let flowing = false;
    for (let attempt = 1; attempt <= MAX_SESSION_ATTEMPTS && !flowing; attempt += 1) {
      await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
      flowing = await framesAdvancing(page, SESSION_ATTEMPT_TIMEOUT_MS);
      // eslint-disable-next-line no-console
      console.log(
        `[tier-b] session attempt ${attempt}/${MAX_SESSION_ATTEMPTS}: ` +
          `${flowing ? 'frames advancing' : 'no advancing frames, reloading'}`,
      );
    }
    expect(
      flowing,
      `no session delivered ADVANCING frames in ${MAX_SESSION_ATTEMPTS} attempts of ` +
        `${SESSION_ATTEMPT_TIMEOUT_MS} ms -- the producer is not streaming a picture`,
    ).toBe(true);

    // --- 1. the library's peer connection reached `connected` --------------
    await expect
      .poll(() => page.evaluate(() => window.__OWV_TIERB__.connected), {
        message:
          'no RTCPeerConnection reached connectionState "connected" -- the ' +
          'browser never completed the WebRTC handshake with the producer',
        timeout: CONNECT_TIMEOUT_MS,
      })
      .toBe(true);

    const record = await page.evaluate(() => window.__OWV_TIERB__);
    // eslint-disable-next-line no-console
    console.log(`[tier-b] connectionState sequence: ${record.states.join(' -> ')}`);
    expect(record.states, 'observed connection states').toContain('connected');

    // --- 2. a remote track arrived from the producer -----------------------
    await expect
      .poll(() => page.evaluate(() => window.__OWV_TIERB__.tracks), {
        message: 'the peer connection never received a remote track',
        timeout: 60_000,
      })
      .toBeGreaterThan(0);

    // --- 3. the element has real dimensions and is decoding ----------------
    await expect
      .poll(
        () =>
          page.evaluate(
            () => (document.getElementById('remote-video') as HTMLVideoElement).videoWidth,
          ),
        {
          message: 'video.videoWidth stayed 0 -- no decoded video reached the element',
          timeout: FRAME_TIMEOUT_MS,
        },
      )
      .toBeGreaterThan(0);

    await expect
      .poll(() => framesRendered(page), {
        message: '#remote-video never decoded a frame',
        timeout: 60_000,
      })
      .toBeGreaterThan(0);

    // --- 4. the frame is NOT BLACK -- the assertion the issue exists for ----
    let stats: FrameStats = {
      width: 0,
      height: 0,
      meanLuma: 0,
      maxLuma: 0,
      brightFraction: 0,
      sampled: 0,
    };
    // Poll rather than sample once: a decoded frame can legitimately land
    // before the first keyframe has painted anything. Every sample is logged --
    // when this fails at 3am the question is always "black, or no frame at all,
    // or did the stream die first", and the sequence of readings answers it
    // without a rerun.
    await expect
      .poll(
        async () => {
          stats = await sampleFrame(page);
          // eslint-disable-next-line no-console
          console.log(`[tier-b] sample: ${JSON.stringify(stats)}`);
          return stats.meanLuma >= MIN_MEAN_LUMA && stats.maxLuma >= MIN_MAX_LUMA;
        },
        {
          message:
            'every sampled frame was black -- a browser connected and decoded ' +
            'video, but no picture was in it',
          timeout: FRAME_TIMEOUT_MS,
          intervals: [SAMPLE_INTERVAL_MS],
        },
      )
      .toBe(true);

    // eslint-disable-next-line no-console
    console.log(`[tier-b] frame stats: ${JSON.stringify(stats)}`);
    saveArtifact('tier-b-frame-stats.json', JSON.stringify(stats, null, 2));
    saveArtifact('tier-b-frame.png', await page.screenshot({ fullPage: false }));

    expect(stats.width, 'sampled frame width').toBeGreaterThan(0);
    expect(stats.height, 'sampled frame height').toBeGreaterThan(0);
    expect(stats.meanLuma, 'mean luma of the sampled frame').toBeGreaterThanOrEqual(
      MIN_MEAN_LUMA,
    );
    expect(stats.maxLuma, 'brightest sampled pixel').toBeGreaterThanOrEqual(MIN_MAX_LUMA);
    expect(
      stats.brightFraction,
      'fraction of sampled pixels above the black floor',
    ).toBeGreaterThanOrEqual(MIN_BRIGHT_FRACTION);

    // --- 5. the readout cleared because a REAL picture rendered (#53) ------
    const status = page.locator('#stream-status');
    await expect(status).toBeHidden({ timeout: 30_000 });
    expect(
      await page.evaluate(
        () => getComputedStyle(document.getElementById('stream-status') as HTMLElement).display,
      ),
    ).toBe('none');
  } finally {
    await page.close();
  }
});
