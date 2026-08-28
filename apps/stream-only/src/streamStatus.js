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
//
// The CONNECT ATTEMPT is a state of its own too (issue #63). Everything above
// assumes the stream came up at least once; a viewer whose producer never
// answers reaches none of it -- no frame, so no hide() and no watchdog; no
// session, so no `onStop` and no escalation. main.ts used to map the library's
// `onStart` straight onto show(`streaming <server>:<port>`), but `onStart`
// means a connect attempt BEGAN, not that anything is streaming, and it
// re-fires on every session-start retry (observed five times against a dead
// producer). The result was a page reporting a working stream, with no error
// styling, forever. connecting() replaces that: it says the viewer is TRYING
// and arms a bounded window from the attempt, which a real first frame cancels
// through the same hide() path. Same lesson as #58, on a different callback --
// state is derived from observable media, never from what a callback is named.
//
// The latch outranks CLAIMS, not OBSERVATION (issue #73). #63's reasoning above
// is sound and stands; what it over-reached into is the media. hide() cancelled
// the escalation, cleared lossAnnounced and then returned early on `terminal`,
// so a rendered frame -- the strongest evidence available that the stream works
// -- was discarded in favour of a verdict this file had INFERRED from a timer.
// A producer that came up 2 s after the connect window closed therefore left a
// red "no video from the source" permanently on top of a playing picture
// (v0.3.0-rc2 tag run: terminal at 06:19:48.863, frames advancing at
// 06:19:50.997 at 1920x1080 meanLuma 151.99, readout still there at 06:20:21).
// So the terminal state stays latched against everything DERIVED FROM THE
// LIBRARY'S CALLBACKS -- show() from `onStart`, connecting(), stopped(), whose
// unreliability is the reason this state machine exists at all -- and it is
// reopened by exactly one thing: frame progress that has ADVANCED past where it
// stood when the latch closed. "Advanced past" is what keeps a stream that
// never delivers a frame terminal (the #63 case): an element that reports no
// progress at all, or reports the same reading forever, produces no evidence,
// and a bare `playing` event with no frame behind it is a claim like any other.
//
// The same rule, applied to the LIVE state (issue #75). #73 stopped a stale
// verdict from outranking a real frame; it left the mirror image untouched --
// a claim outranking a real frame while the stream is running. Everything
// callback-driven was gated on two booleans, `terminal` and `lossAnnounced`,
// and a recovery clears both, so the next session-start retry walked through
// connecting(), repainted `connecting to <server>:<port>...` on top of a
// playing picture and armed a fresh connect window. Nothing could cancel that
// window: hide() runs off `playing` / `loadeddata`, which fired once when
// playback began and do NOT re-fire while frames keep arriving steadily. So it
// ran its full length and ended in a red `no video from the source` over the
// same working stream, which the #73 recovery watch then withdrew one poll
// later -- and the next retry started it again. Measured in a browser against
// a real WebRTC picture (test/e2e/status-loopback.spec.ts): 20.0 s of false
// `connecting`, ~1.0 s of false terminal, repeating roughly every 30 s, while
// the element decoded ~30 frames a second throughout.
//
// So the readout is now guarded on the OBSERVATION this file already takes --
// framesAdvancingNow(), frame progress past the watchdog's most recent
// reading -- and not on a fourth boolean, which would be one more thing to
// keep in sync with reality and is what the three bugs above were made of.
// connecting() says nothing over a picture that is playing, terminate() draws
// no conclusion against one, and the watchdog withdraws whatever a claim
// managed to write in the gap between two frames, window and all. stopped() is
// deliberately NOT guarded: it is the accelerator (#62) that announces a loss
// sooner than the poll can, and at the instant frames really do stop the last
// reading is usually still moving, so guarding it would cost the acceleration
// it exists for. What it writes is withdrawn a poll later if the picture was
// in fact fine, which is the same rule doing the work from the other side.

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
// Terminal, but a different piece of news (#63): the connect window elapsed
// without a single frame ever rendering, so there is nothing to say ended. What
// the user can act on is different too -- not "wait for the stream you had to
// come back" but "check whether the source is running at all".
const NEVER_STARTED_TEXT =
  'no video from the source -- it never started. Check that it is running, then reload.';
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
 * How long a viewer may sit on the connect readout before the attempt is
 * declared a failure (#63). Armed from the connect attempt, not from a loss,
 * because a stream that never starts reaches no loss trigger at all.
 *
 * Longer than TERMINAL_ESCALATION_MS on purpose: a viewer opened before the Kit
 * app has finished booting is the ordinary case, the library keeps retrying
 * session start meanwhile (`maxReconnects` -> `maxSessionStartRetry`, 20), and
 * declaring failure over a producer that is merely slow to come up would be the
 * #60 mistake in the other direction. It must also outlast the window in which
 * the config-dial e2e dials a DEAD host and asserts `#stream-status` carries no
 * `error` class -- that suite finishes in well under a second per mode, so the
 * margin is large, and a unit spec locks the lower bound.
 *
 * Left at 20 s by #73, deliberately rather than by default. Lengthening it
 * would trade a shorter false message for a slower true one, and #73 changes
 * which side of that trade matters: a window that now ends in a verdict a real
 * frame can WITHDRAW costs, when it fires early, a message that clears itself
 * as soon as the picture arrives -- while every second added to it is a second
 * a genuinely dead producer goes unreported. The rc2 producer's first frame was
 * ~22 s after page load, so the message does still appear briefly against a
 * cold producer; that is the intended remaining cost.
 */
export const CONNECT_ESCALATION_MS = 20_000;

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
 * @param {{terminalDelayMs?: number, connectDelayMs?: number, stallPollMs?: number,
 *   stallSamples?: number, setTimer?: Function, clearTimer?: Function}}
 *   [options]  clock seam for the escalations and the frame-progress watchdog:
 *   injected wholesale by the unit tests so they exercise every timeout path
 *   without any real waiting
 * @returns {{show: (text: string, isError?: boolean) => void, hide: () => void,
 *   connecting: (text: string) => void, stopped: () => void,
 *   terminated: () => void}}
 */
export function createStatusController(statusEl, videoEl, logger = console, options = {}) {
  const {
    terminalDelayMs = TERMINAL_ESCALATION_MS,
    connectDelayMs = CONNECT_ESCALATION_MS,
    stallPollMs = FRAME_STALL_POLL_MS,
    stallSamples = FRAME_STALL_SAMPLES,
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (id) => clearTimeout(id),
  } = options;

  // Once terminal, nothing DERIVED FROM A CALLBACK may quietly clear or
  // downgrade the readout: neither a trailing onStop nor a session-start retry
  // may leave the user with a silent frozen frame again (#56, #63).
  let terminal = false;
  // Frame progress as of the instant the latch closed, or null if the element
  // could not report any (#73). It is the baseline the one permitted way OUT of
  // the terminal state is measured against: media that has advanced past it is
  // observation, and observation outranks a verdict inferred from a timer. Null
  // means no such evidence can exist here, so nothing reopens the state.
  let terminalProgress = null;
  // Pending stopped() -> terminated() escalation, if any (#58).
  let escalation = null;
  // Pending frame-progress sample, if any (#62). Armed by the first rendered
  // frame; the terminal state repurposes it into a recovery watch rather than
  // disarming it (#73), and only an element that reports no progress stops it.
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
    // The terminal state is latched, and show() is how everything else writes
    // the readout -- including a `streaming ...` announcement from a
    // session-start retry, which is what used to resurrect a connection that
    // did not exist (#63). hide() and stopped() have always had this guard;
    // show() not having it was the hole. terminate() writes through it before
    // the latch closes, so the terminal message itself still lands.
    if (terminal) {
      return;
    }
    if (statusEl) {
      statusEl.textContent = text;
      statusEl.classList.toggle('error', isError);
      statusEl.classList.remove(HIDDEN_CLASS);
    }
    (isError ? logger.error : logger.info)(`[stream] ${text}`);
  }

  // Frames on the element have moved past a reading taken earlier. This is the
  // whole of "observed media outranks callback claims" as a function: what
  // differs between its two callers is only WHICH reading they measure against.
  // No baseline (the element cannot report progress) or an unchanged reading is
  // not evidence, which is what keeps a stream that never delivers a frame
  // exactly where it is.
  function framesMovedSince(baseline) {
    if (baseline === null) {
      return false;
    }
    const progress = readFrameProgress(videoEl);
    return progress !== null && progress !== baseline;
  }

  // Evidence allowed to reopen the terminal state (#73): progress past where it
  // stood at the instant the latch closed.
  function framesAdvancedSinceTerminal() {
    return framesMovedSince(terminalProgress);
  }

  // Is there a picture on screen RIGHT NOW (#75)? Progress past the watchdog's
  // most recent reading -- which is never more than one poll old, and is taken
  // from the element rather than remembered from anything a callback said. A
  // claim does not speak over this, and no verdict is drawn against it.
  //
  // It is a point sample and cannot be otherwise: a boolean "the stream is
  // live" would be a fourth thing to keep in sync with reality, and the three
  // bugs before this one were all made of exactly that. Two consequences are
  // accepted deliberately. A retry landing in the gap between two frames sees
  // nothing move and is let through -- the next sample withdraws what it wrote
  // (see sampleFrameProgress). And an element whose counter RESETS -- handed a
  // new stream, or having its media torn out from under it -- reads as moved,
  // which errs towards saying nothing; the very next sample re-baselines, so a
  // genuinely dead element is back to arming its window one poll later.
  function framesAdvancingNow() {
    return framesMovedSince(lastProgress);
  }

  function hide() {
    // A rendered frame is the proof that the stream is alive, so it also
    // disarms any pending producer-loss escalation (#58). This runs before the
    // terminal guard so a stale timer can never outlive its cancellation.
    cancelEscalation();
    lossAnnounced = false;
    if (terminal) {
      if (!framesAdvancedSinceTerminal()) {
        return;
      }
      // The frames this controller declared missing did arrive, so the verdict
      // is withdrawn entirely -- error styling and all -- and the machine is
      // live again (#73). Silently: the user is looking at a working picture
      // and does not need to be told about a verdict that turned out wrong.
      terminal = false;
      terminalProgress = null;
      if (statusEl) {
        statusEl.classList.remove('error');
      }
    }
    if (statusEl) {
      statusEl.classList.add(HIDDEN_CLASS);
    }
  }

  // A connect attempt began (#63). This is what main.ts hands the library's
  // `onStart`, and what it calls once itself before connecting at all, so the
  // window is armed even if `onStart` never fires. The readout says the viewer
  // is trying -- it cannot know more than that until a frame renders -- and the
  // window bounds the trying: if nothing has rendered when it elapses, the
  // attempt is declared failed rather than left claiming success.
  function connecting(text) {
    // Nothing to add over a loss that has already been announced (or latched):
    // an attempt that has produced no picture is not news over a state derived
    // from real media, and its escalation is already armed and must not be
    // pushed back.
    if (terminal || lossAnnounced) {
      return;
    }
    // Nothing to add over a picture that is PLAYING either (#75). `onStart`
    // re-fires on every session-start retry, and after a recovery both flags
    // above are false again, so this is the whole of what stood between a
    // retry and a `connecting to ...` readout on top of a working stream --
    // plus a fresh window whose only possible ending was a false verdict.
    if (framesAdvancingNow()) {
      return;
    }
    show(text);
    // Armed once, from the FIRST attempt. `onStart` re-fires on every
    // session-start retry, so re-arming here would move the deadline out by a
    // whole window each time -- i.e. back to never.
    if (escalation === null) {
      escalation = setTimer(() => {
        escalation = null;
        terminate(NEVER_STARTED_TEXT);
      }, connectDelayMs);
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

  // Latch the readout on an actionable error. Two windows end here (#58, #63)
  // with different news -- a stream that ended vs. one that never started --
  // so the copy is the argument; everything else about being terminal is the
  // same. show() runs before the latch closes, which is the one write that is
  // allowed through it.
  function terminate(text) {
    // A verdict is a conclusion ABOUT the media, so the media outranks it too
    // (#75). Both windows that end here are armed by claims -- a connect
    // attempt or an `onStop` -- and a claim that turned out to be wrong must
    // not be allowed to paint an error over a picture that is playing. The
    // readout goes away instead, which is what a live picture means, and the
    // machine stays live: if the frames really do stop later, the watchdog
    // announces and escalates from scratch.
    if (framesAdvancingNow()) {
      hide();
      return;
    }
    cancelEscalation();
    show(text, true);
    terminal = true;
    // What the watchdog is watching for changes here; it does not stop (#73).
    // Until now it was looking for a stall, and there is no stall left to find.
    // From now on the only transition available is OUT -- frame progress moving
    // past this instant's reading -- and the poll is how a stream that comes
    // back is noticed when no video event announces it (after a stall long
    // enough to escalate, `playing` does not necessarily re-fire). An element
    // that cannot report progress can never produce that evidence, so for it
    // there really is nothing left to watch and the sampler stops.
    terminalProgress = readFrameProgress(videoEl);
    if (terminalProgress === null) {
      cancelSampler();
    } else {
      scheduleSample();
    }
  }

  // The stream is over for good: the escalation window elapsed with no frame
  // (the only path this library build actually reaches -- see the header note;
  // the loss it escalates may have been reported by onStop or noticed by the
  // watchdog), or the library surprised us by invoking onTerminate after all.
  function terminated() {
    terminate(TERMINATED_TEXT);
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
    const progress = readFrameProgress(videoEl);
    if (progress === null) {
      return; // the element stopped reporting: fall back to onStop, stop polling
    }
    if (terminal) {
      // The recovery watch (#73). Nothing escalates from here -- the state is
      // already terminal -- so the only reading that means anything is one that
      // has moved. hide() re-checks it and un-latches on it; armWatchdog() then
      // re-baselines the ordinary stall watch on the stream that is now
      // running. A picture that stays frozen just keeps the watch going.
      if (progress !== terminalProgress) {
        hide();
        armWatchdog();
      } else {
        scheduleSample();
      }
      return;
    }
    if (progress !== lastProgress) {
      lastProgress = progress;
      stillSamples = 0;
      // The picture moved, so whatever the readout says is out of date: a loss
      // someone announced (`onStop` or this watchdog), or a connect attempt a
      // session-start retry re-announced in the gap between two frames (#75).
      // hide() clears the text AND disarms whatever window came with it, which
      // is what a `playing` event would have done if it re-fired -- and it does
      // not re-fire while frames simply keep arriving, which is exactly how a
      // spurious window used to survive all the way to a false verdict.
      hide();
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

  return { show, hide, connecting, stopped, terminated };
}
