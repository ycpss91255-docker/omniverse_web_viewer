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
// It also owns the producer-loss transitions (issue #56): stopped() is what
// main.ts hands to the streaming library's `onStop` handler, so a producer that
// dies mid-session says so on screen instead of leaving a silent frozen frame.
// It takes no argument on purpose -- the library's message payload for that
// handler is not verifiable from this repo, so it is treated as a bare signal.
//
// The terminal state is derived HERE, not received (issue #58). #56/#57 reached
// terminated() only from the library's `onTerminate` handler; THIS LIBRARY BUILD
// NEVER INVOKES IT. Evidence, from the bundle actually shipped in the runtime
// image (/app/stream-only/dist/assets/omniverse-webrtc-streaming-library-*.js):
// `onTerminate` occurs exactly 4 times -- twice as the error-code enum name
// `SessionTerminatedByAnotherClient`, once inside the matching error message
// string, and once as the null entry in the defaults object
// (`onUpdate:null,onStart:null,onStop:null,onTerminate:null,...`). There is no
// call site, while `onStart` (52), `onUpdate` (13) and `onStop` (7, with a real
// `onStopResult.bind(this)` dispatch) all have one. Confirmed live too: with the
// Kit producer SIGKILLed the viewer stayed on the recoverable message forever.
// So: stopped() arms a bounded escalation timer and, if no frame renders inside
// that window, escalates to terminated() locally. Do not wire the terminal state
// back to `onTerminate` on the assumption that it fires -- re-run the grep first.

// display:none toggle lives in index.html CSS (`#stream-status.hidden`).
const HIDDEN_CLASS = 'hidden';
// Recoverable: the stream may still come back, and a frame that renders inside
// the escalation window hides the readout again.
const STOPPED_TEXT = 'stream stopped -- reconnecting...';
// Terminal: the escalation window elapsed with no frame, so the producer is
// treated as gone. Only a reload can recover, so this stays on screen as an
// error.
const TERMINATED_TEXT = 'stream ended -- the source is gone. Reload once it is back.';
// First real frame: `playing` covers (re)start after buffering/reconnect;
// `loadeddata` is the belt-and-suspenders first-frame signal. hide() is
// idempotent, so firing both (or repeatedly) is harmless.
const VIDEO_READY_EVENTS = ['playing', 'loadeddata'];

/**
 * How long a stopped stream may stay "reconnecting" before it is declared gone
 * (#58). Chosen as a compromise: long enough that a stream which does come back
 * clears the readout on its own (and, incidentally, far longer than the window
 * in which the config-dial e2e asserts `#stream-status` carries no `error`
 * class while dialing a dead host), short enough that a user staring at a dead
 * viewer is told to reload rather than left waiting indefinitely.
 */
export const TERMINAL_ESCALATION_MS = 15_000;

/**
 * @param {{textContent: string, classList: {toggle: Function, add: Function,
 *   remove: Function}} | null} statusEl  the #stream-status element
 * @param {{addEventListener: Function} | null} videoEl  the #remote-video element
 * @param {{info: Function, error: Function}} [logger=console]  injectable for tests
 * @param {{terminalDelayMs?: number, setTimer?: Function, clearTimer?: Function}}
 *   [options]  escalation clock seam: injected wholesale by the unit tests so
 *   they exercise the timeout path without any real waiting
 * @returns {{show: (text: string, isError?: boolean) => void, hide: () => void,
 *   stopped: () => void, terminated: () => void}}
 */
export function createStatusController(statusEl, videoEl, logger = console, options = {}) {
  const {
    terminalDelayMs = TERMINAL_ESCALATION_MS,
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (id) => clearTimeout(id),
  } = options;

  // Once terminal, nothing may quietly clear or downgrade the readout: neither
  // a trailing onStop nor a stray video event may leave the user with a silent
  // frozen frame again (#56).
  let terminal = false;
  // Pending stopped() -> terminated() escalation, if any (#58).
  let escalation = null;

  function cancelEscalation() {
    if (escalation !== null) {
      clearTimer(escalation);
      escalation = null;
    }
  }

  function show(text, isError = false) {
    if (statusEl) {
      statusEl.textContent = text;
      statusEl.classList.toggle('error', isError);
      statusEl.classList.remove(HIDDEN_CLASS);
    }
    (isError ? logger.error : logger.info)(`[stream] ${text}`);
  }

  function hide() {
    // A rendered frame is the proof that the stream is alive, so it also
    // disarms any pending producer-loss escalation (#58). This runs before the
    // terminal guard so a stale timer can never outlive its cancellation.
    cancelEscalation();
    if (terminal) {
      return;
    }
    if (statusEl) {
      statusEl.classList.add(HIDDEN_CLASS);
    }
  }

  // The stream ended and may still come back: say so, and arm the escalation.
  // Whichever happens first wins -- a rendered frame calls hide() and cancels
  // it, or the window elapses and we declare the producer gone ourselves (#58).
  function stopped() {
    if (terminal) {
      return;
    }
    show(STOPPED_TEXT);
    cancelEscalation(); // a repeated stop restarts the window, never stacks
    escalation = setTimer(() => {
      escalation = null;
      terminated();
    }, terminalDelayMs);
  }

  // The stream is over for good: the escalation window elapsed with no frame
  // (the only path this library build actually reaches -- see the header note),
  // or the library surprised us by invoking onTerminate after all.
  function terminated() {
    cancelEscalation();
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
