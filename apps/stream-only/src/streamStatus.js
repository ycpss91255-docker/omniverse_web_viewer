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
//
// It also owns the producer-loss transitions (issue #56): stopped() and
// terminated() are what main.ts hands to the streaming library's `onStop` /
// `onTerminate` handlers, so a producer that dies mid-session says so on
// screen instead of leaving a silent frozen frame. They take no argument on
// purpose -- the library's message payload for those two handlers is not
// verifiable from this repo, so they are treated as bare signals.

// display:none toggle lives in index.html CSS (`#stream-status.hidden`).
const HIDDEN_CLASS = 'hidden';
// Recoverable: the library keeps retrying (buildStreamConfig maxReconnects: 20)
// and a successful reconnect renders a frame, which hides the readout again.
const STOPPED_TEXT = 'stream stopped -- reconnecting...';
// Terminal: the library gave up (or the session was ended). Only a reload can
// recover, so this stays on screen as an error.
const TERMINATED_TEXT = 'stream ended -- the source is gone. Reload once it is back.';
// First real frame: `playing` covers (re)start after buffering/reconnect;
// `loadeddata` is the belt-and-suspenders first-frame signal. hide() is
// idempotent, so firing both (or repeatedly) is harmless.
const VIDEO_READY_EVENTS = ['playing', 'loadeddata'];

/**
 * @param {{textContent: string, classList: {toggle: Function, add: Function,
 *   remove: Function}} | null} statusEl  the #stream-status element
 * @param {{addEventListener: Function} | null} videoEl  the #remote-video element
 * @param {{info: Function, error: Function}} [logger=console]  injectable for tests
 * @returns {{show: (text: string, isError?: boolean) => void, hide: () => void,
 *   stopped: () => void, terminated: () => void}}
 */
export function createStatusController(statusEl, videoEl, logger = console) {
  // Once terminal, nothing may quietly clear or downgrade the readout: neither
  // a trailing onStop nor a stray video event may leave the user with a silent
  // frozen frame again (#56).
  let terminal = false;

  function show(text, isError = false) {
    if (statusEl) {
      statusEl.textContent = text;
      statusEl.classList.toggle('error', isError);
      statusEl.classList.remove(HIDDEN_CLASS);
    }
    (isError ? logger.error : logger.info)(`[stream] ${text}`);
  }

  function hide() {
    if (terminal) {
      return;
    }
    if (statusEl) {
      statusEl.classList.add(HIDDEN_CLASS);
    }
  }

  // The stream ended but the library is still retrying: say so, and let the
  // next rendered frame clear it again on a successful reconnect.
  function stopped() {
    if (terminal) {
      return;
    }
    show(STOPPED_TEXT);
  }

  // The stream is over for good (reconnects exhausted / session terminated).
  function terminated() {
    show(TERMINATED_TEXT, true);
    terminal = true;
  }

  if (videoEl && typeof videoEl.addEventListener === 'function') {
    for (const ev of VIDEO_READY_EVENTS) {
      videoEl.addEventListener(ev, hide);
    }
  }

  return { show, hide, stopped, terminated };
}
