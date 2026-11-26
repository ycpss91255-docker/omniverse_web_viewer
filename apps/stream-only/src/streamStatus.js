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
// terminated() only from the library's `onTerminate` handler, and the 5.x build
// NEVER INVOKED IT: in that bundle
// (/app/stream-only/dist/assets/omniverse-webrtc-streaming-library-*.js)
// `onTerminate` occurred exactly 4 times -- twice as the error-code enum name
// `SessionTerminatedByAnotherClient`, once inside the matching error message
// string, and once as the null entry in the defaults object
// (`onUpdate:null,onStart:null,onStop:null,onTerminate:null,...`) -- no call
// site at all, while `onStart` (52), `onUpdate` (13) and `onStop` (7, with a
// real `onStopResult.bind(this)` dispatch) all had one. Confirmed live too:
// with the Kit producer SIGKILLed the viewer stayed on the recoverable message
// forever.
//
// That instruction said to re-run the grep before trusting the callback again.
// #98 did, against `ov-web-rtc` 6.8.2 (`ov-web-rtc-*.js`), and it has changed:
// `onTerminate` is registered via `attachCallbacks({...onTerminate...})` and has
// TWO real invocation sites, both dispatching `action: TERMINATE`.
//
// The design does NOT move onto it. Two reasons, and the first is the durable
// one: state derived from the picture the user is actually looking at does not
// depend on which library build is underneath, which is the whole lesson of
// #58/#62/#63. The second is evidentiary -- a call site in a bundle is not an
// observation that the callback fires in THIS failure mode (a producer dying
// mid-session), and that has not been watched on a real host yet. So
// stopped() still arms a bounded escalation timer and escalates locally if no
// frame renders inside the window. If `onTerminate` is ever observed firing
// against a real dying producer, the place for it is the ACCELERATOR role
// `onStop` already has -- never the sole trigger.
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
//
// The verdicts wait for the library (issue #101). Both escalation windows
// existed because nothing could report whether the streaming library had
// stopped trying, so they GUESSED -- and #98 sized the reconnect budget to fit
// inside them as "6 x ~2 s is ~12 s". Measured against ov-web-rtc 6.8.2 the
// guess was out by a factor of four to seven: each attempt costs ~10 s of an
// internal sign-in timeout that no public config field reaches, so the connect
// window declared "it never started" at 20 s while the library dialed on until
// 49 s (a refused port) or 83 s (a black-holed host). Telling a user to reload
// while the library is still trying is precisely the kind of untrue statement
// this file exists to refuse.
//
// The library does say so now: `onStreamStatusChange` (6.7.0) reports STOPPED
// only once every reconnect attempt is exhausted, and stream-core passes that
// single status on as gaveUp(). So:
//   - gaveUp() declares at once, with whichever verdict the pending window
//     would have declared -- the fact replaces the guess and nothing else
//     changes. With no window pending, a frame did render (that is what
//     cancels the connect window) and no loss had been announced yet: the
//     stream started, so what ended is the stream.
//   - both windows stay, as CEILINGS, for a library that never says anything.
//   - every verdict also stops the library, through the injected `abandon`.
//     When the library got there first that is harmless; when a ceiling did,
//     it is what makes the verdict true rather than merely announced. Either
//     way "terminal" implies "nothing is still trying", as a property of this
//     state machine rather than of which callback happened to arrive first.
// gaveUp() is a claim like any other and passes the same media guard as every
// verdict (#75): a picture that is playing outranks it, and stopping the
// library then would take that picture away, so `abandon` is not called.

// display:none toggle lives in index.html CSS (`#stream-status.hidden`).
const HIDDEN_CLASS = 'hidden';
// Recoverable: the stream may still come back, and a frame that renders inside
// the escalation window hides the readout again. It says "reconnecting" because
// under `@nvidia/ov-web-rtc` 6.x that is what the library is actually doing
// (#98) -- `maxReconnects` is a real attempt budget there, spaced by
// `reconnectDelay`.
//
// #60 refused this word and was right to at the time: the 5.x library passed
// `maxReconnects` through as `maxSessionStartRetry`, consumed only by the
// session-START decision, so a producer that died after the stream was up was
// never reconnected to and the word promised a recovery that could not happen.
// The migration reversed that premise rather than making it inconvenient.
//
// It stays up for as long as the library is still trying, and the terminal
// message below replaces it only once the library has stopped (#101) -- which
// is what keeps both honest. #98 tried to guarantee that ordering by sizing the
// reconnect budget to fit inside a 15 s window; measured, the budget did not
// fit, so the ordering is now taken from the library itself.
const STOPPED_TEXT = 'stream stopped -- reconnecting...';
// Terminal: the library has stopped trying and no frame came back (#101), so
// the producer is gone. Only a reload can recover, so this stays on screen as
// an error.
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
 * The ceiling on the recoverable state (#58, #101): how long a stopped stream
 * may wait for the library's own verdict before this controller gives one.
 *
 * It used to BE the verdict -- 15 s, a compromise between letting a stream
 * come back on its own and not leaving a user staring at a dead picture -- and
 * #101 measured the library still retrying for up to a minute after it fired.
 * The verdict now comes from the library's STOPPED (gaveUp()). This bounds only
 * a library that never sends one, and when it fires it stops the library as it
 * declares, so even this path cannot announce something still being attempted.
 *
 * So it has to OUTLAST the library's budget, or it becomes the trigger again
 * and cuts short a recovery the library could still make. With maxReconnects 5
 * that budget measures at ~37 s (refused port) and ~71 s (black-holed host); a
 * unit spec locks the ceiling above the larger. It also still outlasts the
 * window in which the config-dial e2e asserts `#stream-status` carries no
 * `error` class while dialing a dead host, by a wide margin.
 */
export const TERMINAL_ESCALATION_MS = 120_000;

/**
 * The ceiling on a connect attempt that never produces a frame (#63, #101).
 * Armed from the attempt, not from a loss, because a stream that never starts
 * reaches no loss trigger at all.
 *
 * Like TERMINAL_ESCALATION_MS it used to be the verdict -- 20 s -- and it is
 * the one #101 caught in the act: "it never started" at 20 s while the library
 * dialed on until 83 s. The verdict now waits for the library's STOPPED; this
 * bounds only a library that never sends one, stops it as it declares, and
 * outlasts the measured budget for the same reason as the ceiling above.
 *
 * #98 left a question open here: what 6.x does against a producer that never
 * answers had to be re-established by watching, not by reading the bundle.
 * #101 is that observation (a real browser against a refused port and a
 * black-holed host). #73's trade -- whether a window that fires early costs
 * more than one that fires late -- no longer applies, because neither window
 * decides when the verdict lands in the ordinary case: the rc2 producer that
 * came up ~22 s after page load now finds the library still trying, and the
 * readout still, truthfully, connecting.
 *
 * It must also outlast the window in which the config-dial e2e dials a DEAD
 * host and asserts `#stream-status` carries no `error` class -- that suite
 * finishes in well under a second per mode, and a unit spec locks the lower
 * bound.
 */
export const CONNECT_ESCALATION_MS = 120_000;

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
 *   stallSamples?: number, setTimer?: Function, clearTimer?: Function,
 *   abandon?: Function}}
 *   [options]  clock seam for the escalations and the frame-progress watchdog:
 *   injected wholesale by the unit tests so they exercise every timeout path
 *   without any real waiting. `abandon` stops the streaming library; it is
 *   called once, when a verdict latches (#101)
 * @returns {{show: (text: string, isError?: boolean) => void, hide: () => void,
 *   connecting: (text: string) => void, stopped: () => void,
 *   terminated: () => void, gaveUp: () => void}}
 */
export function createStatusController(statusEl, videoEl, logger = console, options = {}) {
  const {
    terminalDelayMs = TERMINAL_ESCALATION_MS,
    connectDelayMs = CONNECT_ESCALATION_MS,
    stallPollMs = FRAME_STALL_POLL_MS,
    stallSamples = FRAME_STALL_SAMPLES,
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (id) => clearTimeout(id),
    abandon = () => {},
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
  // Pending escalation ceiling, if any (#58, #63), and the verdict it would
  // declare. The verdict is kept beside the timer because gaveUp() (#101)
  // replaces the window's guess with the library's own word -- and the window
  // is what knows whether the stream had ever started.
  let escalation = null;
  let escalationVerdict = null;
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
    escalationVerdict = null;
  }

  // Arm a ceiling that declares `verdict` if the library has not concluded by
  // the time `ms` elapses.
  function armEscalation(verdict, ms) {
    escalationVerdict = verdict;
    escalation = setTimer(() => {
      escalation = null;
      escalationVerdict = null;
      terminate(verdict);
    }, ms);
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
      armEscalation(NEVER_STARTED_TEXT, connectDelayMs);
    }
  }

  // The stream ended and may still come back: say so, and arm the ceiling.
  // Whichever happens first wins -- a rendered frame calls hide() and cancels
  // it, the library reports that it has stopped trying (gaveUp(), #101), or
  // the ceiling elapses with the library silent and we conclude for it (#58).
  function stopped() {
    if (terminal) {
      return;
    }
    show(STOPPED_TEXT);
    lossAnnounced = true;
    cancelEscalation(); // a repeated stop restarts the window, never stacks
    armEscalation(TERMINATED_TEXT, terminalDelayMs);
  }

  // The library has stopped trying (#101): its own STOPPED, which it reports
  // only once every reconnect attempt is exhausted. It replaces whichever
  // window was guessing at this moment with the moment itself, and declares
  // what that window would have. No window pending means a frame did render
  // -- that is what cancels the connect window -- and no loss had been
  // announced yet: the stream started, so what ended is the stream.
  function gaveUp() {
    if (terminal) {
      return;
    }
    terminate(escalationVerdict ?? TERMINATED_TEXT);
  }

  // Latch the readout on an actionable error. Two windows end here (#58, #63)
  // with different news -- a stream that ended vs. one that never started --
  // and so does the library's own verdict (#101); the copy is the argument,
  // and everything else about being terminal is the same. show() runs before
  // the latch closes, which is the one write that is allowed through it.
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
    const wasTerminal = terminal;
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
    // A verdict is only true if nothing is still trying, so it stops the
    // library (#101): harmless when the library's own STOPPED got here first,
    // and what makes a ceiling's verdict true when the library said nothing.
    // Once per latch, and only AFTER it has closed, so anything the library
    // calls back with while it stops finds the state already terminal.
    if (!wasTerminal) {
      abandon();
    }
  }

  // The library's `onTerminate` (see the header note: 6.8.2 has call sites,
  // not yet observed firing against a dying producer). The ordinary ways to the
  // same verdict are gaveUp() and the loss ceiling; this is kept for the case
  // the library reports a termination before either.
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

  return { show, hide, connecting, stopped, terminated, gaveUp };
}
