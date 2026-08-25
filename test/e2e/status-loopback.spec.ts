// Tier-1 browser status-state e2e, driven by an in-page WebRTC loopback (#62).
//
// Goal: stop needing a human in front of a browser to know the #stream-status
// states are right. Two of the four fixes in the #53 / #56 / #58 / #60 run were
// caught ONLY by someone watching the page, because nothing in CI could reach
// the states: the unit specs drive fake elements (a `classList` backed by a
// Set, a video stub with emit()), which can prove the controller's logic but
// never that the real stylesheet hides anything or that the error colour
// applies; and config-dial.spec.ts runs a real browser but against a DEAD host,
// so no frame ever renders and no loss state is ever entered.
//
// The missing ingredient is real media, and it does not need a producer. A
// canvas `captureStream()` piped through a local RTCPeerConnection pair into
// the page's own #remote-video produces REAL `loadeddata` / `playing` events on
// the REAL element, with real decoded frames behind them -- no GPU, no Isaac,
// no Kit, no server. (WebRTC samples: content/capture/canvas-pc.)
//
// What that buys, in a real browser:
//   - frames arrive  -> the readout is genuinely invisible (real CSS)
//   - frames stall   -> the recoverable state, in its real colour and wording
//   - stall persists -> the terminal state, distinguishable and latched
//
// The last two only became reachable with #62's frame-progress watchdog: the
// loss states used to be entered solely from the library's `onStop`, which a
// test cannot make the library call. Driving them from observable media is what
// makes the whole state machine testable here.
//
// STILL NOT COVERED (deliberately): that a real Kit produces a real, non-black
// picture. That needs a real producer and stays with Tier B (#48, isaac#223,
// isaac#173). The loopback proves the viewer's reaction to media, not the media.
import { test, expect, type Page } from '@playwright/test';

const BASE_URL = process.env.OWV_BASE_URL || 'http://127.0.0.1:5174';
const MODE = process.env.OWV_MODE || 'stream-only';

// The two colours index.html actually declares for #stream-status: the base
// grey and the `.error` red. Asserting the computed values is the point -- a
// class-membership check (all the unit specs can do) would have passed just as
// happily if the stylesheet had never shipped.
const BASE_COLOR = 'rgb(139, 148, 158)'; // #8b949e
const ERROR_COLOR = 'rgb(248, 81, 73)'; // #f85149

// Wall-clock budget for the states the app derives from its own timers:
// ~5 s of stalled frames to announce the recoverable state, then
// TERMINAL_ESCALATION_MS (15 s) to escalate. Kept as generous single values
// rather than mirrored constants -- this spec asserts the OBSERVED behaviour,
// not the app's numbers.
const RECOVERABLE_TIMEOUT_MS = 15_000;
const TERMINAL_TIMEOUT_MS = 30_000;
// The never-connected case (#63) has no media at all: the page is left dialing
// the dead test host and the app's own connect window (CONNECT_ESCALATION_MS,
// 20 s) is what ends the wait. Generous, for the same reason as the two above.
const NEVER_STARTED_TIMEOUT_MS = 45_000;

interface Loopback {
  sender: RTCRtpSender;
  track: MediaStreamTrack;
  timer: number;
}

declare global {
  interface Window {
    __OWV_LOOPBACK__?: Loopback;
  }
}

/**
 * Build the in-page loopback and point #remote-video at its receiving end.
 * Non-trickle ICE (offer/answer exchanged only once gathering has completed),
 * so there is no candidate-before-remote-description race to flake on.
 */
async function startLoopback(page: Page): Promise<void> {
  await page.evaluate(async () => {
    // Replacing an earlier loopback (the latch check builds a second one).
    if (window.__OWV_LOOPBACK__) {
      window.clearInterval(window.__OWV_LOOPBACK__.timer);
    }
    const canvas = document.createElement('canvas');
    canvas.width = 320;
    canvas.height = 240;
    const ctx = canvas.getContext('2d') as CanvasRenderingContext2D;
    let tick = 0;
    // Every repaint is a new captured frame; the hue keeps changing so the
    // encoder always has something to send.
    const paint = (): void => {
      tick += 1;
      ctx.fillStyle = `hsl(${(tick * 13) % 360}, 90%, 45%)`;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    };
    paint();
    const timer = window.setInterval(paint, 33);

    const stream = canvas.captureStream(30);
    const track = stream.getVideoTracks()[0];
    const pc1 = new RTCPeerConnection();
    const pc2 = new RTCPeerConnection();
    const gathered = (pc: RTCPeerConnection): Promise<void> =>
      new Promise((resolve) => {
        if (pc.iceGatheringState === 'complete') {
          resolve();
          return;
        }
        pc.addEventListener('icegatheringstatechange', () => {
          if (pc.iceGatheringState === 'complete') {
            resolve();
          }
        });
      });
    const inbound = new Promise<MediaStreamTrack>((resolve) => {
      pc2.addEventListener('track', (e) => resolve(e.track));
    });

    const sender = pc1.addTrack(track, stream);
    await pc1.setLocalDescription(await pc1.createOffer());
    await gathered(pc1);
    await pc2.setRemoteDescription(pc1.localDescription as RTCSessionDescription);
    await pc2.setLocalDescription(await pc2.createAnswer());
    await gathered(pc2);
    await pc1.setRemoteDescription(pc2.localDescription as RTCSessionDescription);

    const video = document.getElementById('remote-video') as HTMLVideoElement;
    video.srcObject = new MediaStream([await inbound]);
    try {
      await video.play();
    } catch {
      /* the element is already autoplay + video-only; a rejection is harmless */
    }
    window.__OWV_LOOPBACK__ = { sender, track, timer };
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

/** Wait until the loopback is actually delivering frames to the element. */
async function expectFramesFlowing(page: Page): Promise<void> {
  await expect
    .poll(() => framesRendered(page), {
      message: 'the WebRTC loopback never delivered a frame to #remote-video',
      timeout: 20_000,
    })
    .toBeGreaterThan(0);
}

/**
 * Cut the media off at the sender without tearing anything down: the canvas
 * keeps painting and the peer connection stays up, but no frame reaches the
 * element any more -- exactly what a producer that stops rendering looks like
 * from the page's side, and reversible (unlike track.stop()).
 */
function stallFrames(page: Page): Promise<void> {
  return page.evaluate(() => window.__OWV_LOOPBACK__?.sender.replaceTrack(null));
}

function resumeFrames(page: Page): Promise<void> {
  return page.evaluate(() =>
    window.__OWV_LOOPBACK__?.sender.replaceTrack(window.__OWV_LOOPBACK__.track),
  );
}

function statusColor(page: Page): Promise<string> {
  return page.evaluate(
    () => getComputedStyle(document.getElementById('stream-status') as HTMLElement).color,
  );
}

function statusDisplay(page: Page): Promise<string> {
  return page.evaluate(
    () => getComputedStyle(document.getElementById('stream-status') as HTMLElement).display,
  );
}

test.beforeEach(async ({ page }) => {
  test.skip(MODE !== 'stream-only', 'the loopback drives OUR app; usd-viewer is black-box');
  // Setting up the loopback plus waiting for the first decoded frame does not
  // fit the shared 30 s default; the states derived from the app's own timers
  // raise it further per test.
  test.setTimeout(60_000);
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
});

test('the initial readout is visible and carries the stylesheet base styling', async ({
  page,
}) => {
  const status = page.locator('#stream-status');
  await expect(status).toBeVisible();
  // Either the static placeholder in index.html or the dial readout the app
  // writes at DOMContentLoaded -- which one has landed by now is a race, and
  // #63 is the reason it no longer matters: both say the viewer is TRYING.
  // What must never appear before a frame is a claim that it is streaming.
  await expect(status).toHaveText(/^connecting/i);
  await expect(status).not.toContainText(/streaming/i);
  await expect(status).not.toHaveClass(/error/);
  expect(await statusDisplay(page)).not.toBe('none');
  expect(await statusColor(page)).toBe(BASE_COLOR);
});

// The #63 case, and the one no browser test covered: the producer is not there
// at all. No frame ever renders, so nothing hides the readout and the watchdog
// never arms; no session ever starts, so the library's `onStop` never fires and
// the #58 escalation was never armed either. The page used to sit on
// `streaming <server>:<port>` -- styled as success -- indefinitely.
test('a viewer whose producer never answers stops claiming a connection (#63)', async ({
  page,
}) => {
  test.setTimeout(90_000);
  const status = page.locator('#stream-status');

  // Deliberately NO loopback: this is the served app dialing the dead test
  // host, exactly as a viewer opened against a Kit app that is not running.
  await expect(status).toBeVisible();
  await expect(status).toContainText(/connecting to/i);
  await expect(status).not.toContainText(/streaming/i);
  await expect(status).not.toHaveClass(/error/);

  // The connect window elapses with no picture: an actionable readout, in the
  // real error colour, instead of a permanent false success.
  await expect(status).toContainText(/no video/i, { timeout: NEVER_STARTED_TIMEOUT_MS });
  await expect(status).toContainText(/reload/i);
  await expect(status).not.toContainText(/streaming|waiting|reconnect/i);
  await expect(status).toHaveClass(/error/);
  expect(await statusColor(page)).toBe(ERROR_COLOR);
});

test('real frames hide the readout through the real stylesheet (#53)', async ({ page }) => {
  const status = page.locator('#stream-status');
  await expect(status).toBeVisible();

  await startLoopback(page);
  await expectFramesFlowing(page);

  // The proof #53 never had: not "the hidden class is in a Set", but that the
  // element the user looks at is actually gone from the page.
  await expect(status).toBeHidden();
  expect(await statusDisplay(page)).toBe('none');
});

test('stalled frames announce the recoverable state, resumed frames clear it (#60, #62)', async ({
  page,
}) => {
  test.setTimeout(90_000);
  const status = page.locator('#stream-status');
  await startLoopback(page);
  await expectFramesFlowing(page);
  await expect(status).toBeHidden();

  await stallFrames(page);

  await expect(status).toBeVisible({ timeout: RECOVERABLE_TIMEOUT_MS });
  await expect(status).toContainText(/waiting for frames/i);
  // Recoverable, so still the base styling -- not the error red (#57), and no
  // claim that anything is reconnecting (#60): nothing does.
  await expect(status).not.toHaveClass(/error/);
  await expect(status).not.toContainText(/reconnect/i);
  expect(await statusColor(page)).toBe(BASE_COLOR);

  await resumeFrames(page);

  // A stream that comes back clears the readout again, same as the first frame
  // ever did (#53) -- the watchdog must not leave a stale message over a live
  // picture.
  await expect(status).toBeHidden({ timeout: RECOVERABLE_TIMEOUT_MS });
  expect(await statusDisplay(page)).toBe('none');
});

test('an unrecovered stall escalates to a distinct terminal state, which a real stream then clears (#57, #58, #62, #73)', async ({
  page,
}) => {
  test.setTimeout(120_000);
  const status = page.locator('#stream-status');
  await startLoopback(page);
  await expectFramesFlowing(page);
  await expect(status).toBeHidden();

  await stallFrames(page);

  await expect(status).toContainText(/waiting for frames/i, {
    timeout: RECOVERABLE_TIMEOUT_MS,
  });
  const recoverableColor = await statusColor(page);

  // Nothing came back inside the escalation window: the producer is declared
  // gone. This is the state #58 shipped unreachable -- no human, no GPU and no
  // library callback involved in getting here.
  await expect(status).toContainText(/source is gone/i, { timeout: TERMINAL_TIMEOUT_MS });
  await expect(status).toContainText(/reload/i);
  await expect(status).not.toContainText(/reconnect|waiting/i);
  await expect(status).toHaveClass(/error/);

  const terminalColor = await statusColor(page);
  expect(terminalColor).toBe(ERROR_COLOR);
  // Distinguishable at a glance, which is the whole reason the terminal state
  // is a separate state rather than a longer wait.
  expect(terminalColor).not.toBe(recoverableColor);

  // Nothing has come back, so nothing may clear it: the state holds on its own
  // for as long as the picture stays frozen. This is the half of #57 that is
  // still true after #73 -- the readout does not time out, drift or get talked
  // out of itself by the library's retries.
  await page.waitForTimeout(3_000);
  await expect(status).toBeVisible();
  await expect(status).toContainText(/source is gone/i);
  await expect(status).toHaveClass(/error/);

  // And then real frames arrive again (#73). This used to assert the opposite
  // -- that a whole new stream, with the loadeddata / playing events that
  // normally clear the readout, could not clear it -- which is the defect
  // v0.3.0-rc2 hit: a red error over a picture that was visibly playing. The
  // latch outranks the library's CLAIMS, not the media itself.
  //
  // It is a NEW loopback rather than a resumed one on purpose: putting the
  // original track back after it had been cut for the entire escalation window
  // did not restart decoding in the element (observed, not assumed -- the frame
  // counter stayed at zero for 20 s). Handing the page a fresh stream is also
  // the case that actually occurs.
  await startLoopback(page);
  await expectFramesFlowing(page);

  await expect(status).toBeHidden({ timeout: RECOVERABLE_TIMEOUT_MS });
  expect(await statusDisplay(page)).toBe('none');
});

// The exact shape of the v0.3.0-rc2 failure, at browser level: the producer is
// not there when the page loads, the app's connect window (#63) elapses and
// declares the attempt failed -- and THEN the producer starts delivering. The
// picture was never in doubt in that run (1920x1080, meanLuma 151.99); only the
// readout was wrong, and it was wrong permanently.
//
// This is the class the loopback harness exists for: real frames on the real
// element, after a real escalation on the app's own clock, with no GPU, no Kit
// and no Tier B runner involved.
test('a producer that starts after the connect window has elapsed clears the readout (#73)', async ({
  page,
}) => {
  test.setTimeout(120_000);
  const status = page.locator('#stream-status');

  // No loopback yet: the served app is dialing the dead test host, so the
  // connect window runs out exactly as it did on the tag run.
  await expect(status).toContainText(/no video/i, { timeout: NEVER_STARTED_TIMEOUT_MS });
  await expect(status).toHaveClass(/error/);
  expect(await statusColor(page)).toBe(ERROR_COLOR);

  // The stream starts late. Nothing else changes -- no reload, no retry driven
  // from the test, just media arriving on the element.
  await startLoopback(page);
  await expectFramesFlowing(page);

  await expect(status).toBeHidden({ timeout: RECOVERABLE_TIMEOUT_MS });
  expect(await statusDisplay(page)).toBe('none');
});
