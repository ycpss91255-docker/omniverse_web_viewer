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
//
// The ENTRY to the loss states is derived here too (issue #62). Until then the
// only way in was the library's `onStop`, which is the same failure mode one
// step removed: a single opaque callback deciding whether the user is ever told
// anything (and, being the library's, unreachable from any browser test -- the
// loss states could not be exercised in CI at all). The controller now also
// polls frame progress on the video element, the thing the user actually
// experiences, and announces the same recoverable state when it stalls.
// `onStop` is kept as an ACCELERATOR -- it fires sooner than the poll can -- not
// as the sole trigger; whichever notices first announces, and the other is
// suppressed by `lossAnnounced` so the escalation is never re-armed.

// display:none toggle lives in index.html CSS (`#stream-status.hidden`).
const HIDDEN_CLASS = 'hidden';
// Recoverable: the stream may still come back, and a frame that renders inside
// the escalation window hides the readout again. It deliberately does NOT say
// "reconnecting" (issue #60): nothing reconnects. `maxReconnects` reaches the
// library as `maxSessionStartRetry` and is consumed only by the session-START
// retry decision, so a producer that dies AFTER the stream is up is never
// reconnected to -- the old wording promised a recovery that could not happen
// for the whole escalation window. What IS true, either way, is that the viewer
// is waiting to see whether frames resume; if none do, the escalation below
// replaces this with the actionable terminal message.
const STOPPED_TEXT = 'stream stopped -- waiting for frames to resume...';
// Terminal: the escalation window elapsed with no frame, so the producer is
// treated as gone. Only a reload can recover, so this stays on screen as an
// error.
const TERMINATED_TEXT = 'stream ended -- the source is gone. Reload once it is back.';
// First real frame: `playing` covers (re)start after buffering/reconnect;
// `loadeddata` is the belt-and-suspenders first-frame signal. hide() is
// idempotent, so firing both (or repeatedly) is harmless.
const VIDEO_READY_EVENTS = ['playing', 'loadeddata'];

/**
 * How long a stopped stream may stay in the waiting state before it is declared gone
 * (#58). Chosen as a compromise: long enough that a stream which does come back
 * clears the readout on its own (and, incidentally, far longer than the window
 * in which the config-dial e2e asserts `#stream-status` carries no `error`
 * class while dialing a dead host), short enough that a user staring at a dead
 * viewer is told to reload rather than left waiting indefinitely.
 */
export const TERMINAL_ESCALATION_MS = 15_000;

/**
 * How often the frame-progress watchdog samples the video element, and how many
 * consecutive samples without progress mean the producer is gone (#62).
 *
 * The product is the tolerance for a frozen picture. It is deliberately several
 * seconds: WebRTC hiccups of a second or two are ordinary, and announcing a
 * producer loss over a stream that is merely stuttering would be worse than
 * saying nothing. It also stays well inside TERMINAL_ESCALATION_MS, so the
 * first state a user sees is still the recoverable one.
 *
 * The residual assumption is that a live producer keeps delivering frames even
 * when its scene is static -- true for Kit, which encodes its render loop at a
 * target frame rate rather than on scene change. If a future producer sends
 * only on change, this window is what would have to grow.
 */
export const FRAME_STALL_POLL_MS = 1_000;
export const FRAME_STALL_SAMPLES = 5;

/**
 * Frame progress as a single monotonic number, or null if this element cannot
 * report any. `totalVideoFrames` is the direct signal (decoded frame count, and
 * it is what a MediaStream-backed element exposes); `currentTime` is the
 * fallback, which for a live stream advances with the last rendered frame.
 * Returning null is what disables the watchdog for the DOM-free unit fakes and
 * for anything else that is not a real video element.
 * @param {{getVideoPlaybackQuality?: Function, currentTime?: number} | null} el
 * @returns {number | null}
 */
function readFrameProgress(el) {
  if (!el) {
    return null;
  }
  if (typeof el.getVideoPlaybackQuality === 'function') {
    const quality = el.getVideoPlaybackQuality();
    if (quality && typeof quality.totalVideoFrames === 'number') {
      return quality.totalVideoFrames;
    }
  }
  return typeof el.currentTime === 'number' ? el.currentTime : null;
}

/**
 * @param {{textContent: string, classList: {toggle: Function, add: Function,
 *   remove: Function}} | null} statusEl  the #stream-status element
 * @param {{addEventListener: Function} | null} videoEl  the #remote-video element
 * @param {{info: Function, error: Function}} [logger=console]  injectable for tests
 * @param {{terminalDelayMs?: number, stallPollMs?: number, stallSamples?: number,
 *   setTimer?: Function, clearTimer?: Function}}
 *   [options]  clock seam for the escalation and the frame-progress watchdog:
 *   injected wholesale by the unit tests so they exercise both timeout paths
 *   without any real waiting
 * @returns {{show: (text: string, isError?: boolean) => void, hide: () => void,
 *   stopped: () => void, terminated: () => void}}
 */
export function createStatusController(statusEl, videoEl, logger = console, options = {}) {
  const {
    terminalDelayMs = TERMINAL_ESCALATION_MS,
    stallPollMs = FRAME_STALL_POLL_MS,
    stallSamples = FRAME_STALL_SAMPLES,
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (id) => clearTimeout(id),
  } = options;

  // Once terminal, nothing may quietly clear or downgrade the readout: neither
  // a trailing onStop nor a stray video event may leave the user with a silent
  // frozen frame again (#56).
  let terminal = false;
  // Pending stopped() -> terminated() escalation, if any (#58).
  let escalation = null;
  // Pending frame-progress sample, if any (#62). Armed by the first rendered
  // frame, disarmed for good by the terminal state.
  let sampler = null;
  // Last frame-progress reading and how many consecutive samples have matched
  // it (#62).
  let lastProgress = null;
  let stillSamples = 0;
  // Whether a producer loss has already been announced -- by the library's
  // onStop or by the watchdog, whichever noticed first. It stops the two
  // triggers from announcing the same loss twice (and, more importantly, from
  // re-arming the escalation and pushing the terminal state back), and it is
  // what tells a resumed frame that there is a readout to clear (#62).
  let lossAnnounced = false;

  function cancelEscalation() {
    if (escalation !== null) {
      clearTimer(escalation);
      escalation = null;
    }
  }

  function cancelSampler() {
    if (sampler !== null) {
      clearTimer(sampler);
      sampler = null;
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
    lossAnnounced = false;
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
    lossAnnounced = true;
    cancelEscalation(); // a repeated stop restarts the window, never stacks
    escalation = setTimer(() => {
      escalation = null;
      terminated();
    }, terminalDelayMs);
  }

  // The stream is over for good: the escalation window elapsed with no frame
  // (the only path this library build actually reaches -- see the header note;
  // the loss it escalates may have been reported by onStop or noticed by the
  // watchdog), or the library surprised us by invoking onTerminate after all.
  function terminated() {
    cancelEscalation();
    // Nothing left to watch for: the state is latched, so a frame that turns up
    // afterwards must not clear it and there is no reason to keep sampling.
    cancelSampler();
    show(TERMINATED_TEXT, true);
    terminal = true;
  }

  // --- frame-progress watchdog (#62) ---------------------------------------
  // The library's onStop is not the only way into the loss states any more.
  // Frames that stop arriving are the loss, as far as the user is concerned,
  // and they are observable from here -- unlike a third-party callback, whose
  // sibling onTerminate turned out never to fire at all (#58). onStop is kept
  // as an accelerator: it announces sooner than the poll can, and the
  // lossAnnounced guard means whichever notices first is the one that speaks.

  function scheduleSample() {
    cancelSampler();
    sampler = setTimer(sampleFrameProgress, stallPollMs);
  }

  // Arm (or re-baseline) the watchdog. Called on every rendered frame, so a
  // stream that recovers starts a fresh window. Only a video element that can
  // report progress is watched: for anything else -- including the DOM-free
  // unit fakes -- onStop stays the sole trigger, exactly as before #62.
  function armWatchdog() {
    if (terminal) {
      return;
    }
    const progress = readFrameProgress(videoEl);
    if (progress === null) {
      return;
    }
    lastProgress = progress;
    stillSamples = 0;
    scheduleSample();
  }

  function sampleFrameProgress() {
    sampler = null;
    if (terminal) {
      return;
    }
    const progress = readFrameProgress(videoEl);
    if (progress === null) {
      return; // the element stopped reporting: fall back to onStop, stop polling
    }
    if (progress !== lastProgress) {
      lastProgress = progress;
      stillSamples = 0;
      if (lossAnnounced) {
        hide(); // frames are back -- the same recovery a `playing` event drives
      }
    } else if (!lossAnnounced) {
      stillSamples += 1;
      if (stillSamples >= stallSamples) {
        stopped();
      }
    }
    scheduleSample();
  }

  if (videoEl && typeof videoEl.addEventListener === 'function') {
    for (const ev of VIDEO_READY_EVENTS) {
      videoEl.addEventListener(ev, () => {
        hide();
        armWatchdog();
      });
    }
  }

  return { show, hide, stopped, terminated };
}
