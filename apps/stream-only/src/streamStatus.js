// streamStatus -- the #stream-status show/hide state machine, extracted from
// main.ts (DOM glue) so it unit-tests with plain `node --test` and fake element
// objects (no jsdom), matching resolveTarget.js / stream-core.
//
// Why it exists (issue #53): the stream-only viewer set #stream-status to
// "streaming <server>:<port>" on connect and never cleared it, so the
// connect-time confirmation persisted as a centered caption on top of the live
// video. The readout is meant to be a TRANSIENT "connecting / connected to X"
// message, not a permanent overlay. This controller hides it once the remote
// video is actually rendering -- keyed off the first `playing` / `loadeddata`
// event on the video element rather than the opaque streaming-library message
// shape -- and re-shows it (via show()) on error / reconnect.

// display:none toggle lives in index.html CSS (`#stream-status.hidden`).
const HIDDEN_CLASS = 'hidden';
// First real frame: `playing` covers (re)start after buffering/reconnect;
// `loadeddata` is the belt-and-suspenders first-frame signal. hide() is
// idempotent, so firing both (or repeatedly) is harmless.
const VIDEO_READY_EVENTS = ['playing', 'loadeddata'];

/**
 * @param {{textContent: string, classList: {toggle: Function, add: Function,
 *   remove: Function}} | null} statusEl  the #stream-status element
 * @param {{addEventListener: Function} | null} videoEl  the #remote-video element
 * @param {{info: Function, error: Function}} [logger=console]  injectable for tests
 * @returns {{show: (text: string, isError?: boolean) => void, hide: () => void}}
 */
export function createStatusController(statusEl, videoEl, logger = console) {
  function show(text, isError = false) {
    if (statusEl) {
      statusEl.textContent = text;
      statusEl.classList.toggle('error', isError);
      statusEl.classList.remove(HIDDEN_CLASS);
    }
    (isError ? logger.error : logger.info)(`[stream] ${text}`);
  }

  function hide() {
    if (statusEl) {
      statusEl.classList.add(HIDDEN_CLASS);
    }
  }

  if (videoEl && typeof videoEl.addEventListener === 'function') {
    for (const ev of VIDEO_READY_EVENTS) {
      videoEl.addEventListener(ev, hide);
    }
  }

  return { show, hide };
}
