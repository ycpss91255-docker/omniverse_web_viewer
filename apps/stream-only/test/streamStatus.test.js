// Unit tests for createStatusController (node --test, DOM-free). The status and
// video elements are injected as fakes, so this runs without jsdom / Vite / the
// @nvidia registry -- same dependency-free pattern as resolveTarget.test.js.
//
// The controller owns the #stream-status show/hide state: show(text) writes the
// transient readout and makes it visible; once the remote video is actually
// rendering (first `playing` / `loadeddata` event) the readout hides so the
// connect-time "streaming ..." confirmation stops obscuring the viewport
// (issue #53). Re-showing on error/reconnect un-hides it again.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createStatusController,
  TERMINAL_ESCALATION_MS,
  CONNECT_ESCALATION_MS,
  FRAME_STALL_POLL_MS,
  FRAME_STALL_SAMPLES,
} from '../src/streamStatus.js';

function fakeStatusEl() {
  const classes = new Set();
  return {
    textContent: '',
    classList: {
      toggle(cls, on) {
        if (on) classes.add(cls);
        else classes.delete(cls);
      },
      add(cls) {
        classes.add(cls);
      },
      remove(cls) {
        classes.delete(cls);
      },
      contains(cls) {
        return classes.has(cls);
      },
    },
  };
}

function fakeVideoEl() {
  const listeners = {};
  return {
    addEventListener(type, fn) {
      (listeners[type] ||= []).push(fn);
    },
    emit(type) {
      for (const fn of listeners[type] || []) fn();
    },
  };
}

// A video element that CAN report frame progress -- i.e. the part of the real
// HTMLVideoElement surface the media watchdog samples (#62). The plain
// fakeVideoEl() above deliberately reports none, which is exactly what keeps
// every spec written before #62 free of the watchdog (see the first #62 spec).
function fakeStreamingVideoEl() {
  const listeners = {};
  let frames = 0;
  return {
    addEventListener(type, fn) {
      (listeners[type] ||= []).push(fn);
    },
    emit(type) {
      for (const fn of listeners[type] || []) fn();
    },
    getVideoPlaybackQuality() {
      return { totalVideoFrames: frames };
    },
    // One more decoded frame reached the element.
    renderFrame() {
      frames += 1;
    },
  };
}

// Deterministic stand-in for setTimeout/clearTimeout. Every spec that reaches
// stopped() MUST inject it: stopped() arms the producer-loss escalation (#58),
// and a real timer would both slow the run down by the whole window and keep
// the node test process alive waiting for it. Nothing here waits.
function fakeClock() {
  let nextId = 0;
  const timers = new Map();
  return {
    setTimer(fn, ms) {
      const id = ++nextId;
      timers.set(id, { fn, ms });
      return id;
    },
    clearTimer(id) {
      timers.delete(id);
    },
    // Everything currently armed, as {id, fn, ms} records.
    get pending() {
      return [...timers.entries()].map(([id, t]) => ({ id, ...t }));
    },
    // Run (and clear) everything armed, i.e. "the window elapsed".
    fire() {
      const due = [...timers.values()];
      timers.clear();
      for (const t of due) t.fn();
    },
    // Run (and clear) only the timers armed with `ms`. The watchdog poll and
    // the escalation use different delays, so a #62 spec can advance one
    // without the other -- "frames kept stalling for another second" is not
    // the same event as "the escalation window elapsed".
    fireEvery(ms) {
      const due = [...timers.entries()].filter(([, t]) => t.ms === ms);
      for (const [id] of due) timers.delete(id);
      for (const [, t] of due) t.fn();
    },
  };
}

// Deliberately not the production default, so a spec asserting on it cannot
// pass by accident if the default changes.
const FAKE_DELAY_MS = 12_345;

function clockOptions(clock, terminalDelayMs = FAKE_DELAY_MS) {
  return {
    terminalDelayMs,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  };
}

// Connect-attempt window (#63), likewise deliberately not the production
// default and deliberately different from FAKE_DELAY_MS, so a spec can tell the
// two escalations apart by the delay a timer was armed with.
const FAKE_CONNECT_MS = 9_876;

function connectOptions(clock) {
  return { ...clockOptions(clock), connectDelayMs: FAKE_CONNECT_MS };
}

// Watchdog knobs (#62), likewise deliberately not the production defaults.
const FAKE_POLL_MS = 250;
const FAKE_SAMPLES = 3;

function watchdogOptions(clock) {
  return {
    ...clockOptions(clock),
    stallPollMs: FAKE_POLL_MS,
    stallSamples: FAKE_SAMPLES,
  };
}

// Both windows plus the watchdog knobs, which is what the recovery specs (#73)
// need: a terminal state produced by the CONNECT window, and a video element
// whose frame progress can then advance past where it stood when that state
// latched.
function recoveryOptions(clock) {
  return { ...watchdogOptions(clock), connectDelayMs: FAKE_CONNECT_MS };
}

// "Another `stallPollMs` elapsed", n times.
function pollTimes(clock, n) {
  for (let i = 0; i < n; i += 1) {
    clock.fireEvery(FAKE_POLL_MS);
  }
}

const silentLogger = { info() {}, error() {} };

test('show writes the text and leaves the readout visible', () => {
  const statusEl = fakeStatusEl();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger);
  ctl.show('streaming 1.2.3.4:49100');
  assert.equal(statusEl.textContent, 'streaming 1.2.3.4:49100');
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('show(text, true) sets the error class', () => {
  const statusEl = fakeStatusEl();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger);
  ctl.show('connection failed', true);
  assert.equal(statusEl.classList.contains('error'), true);
});

test('the readout hides once the video starts playing (issue #53)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger);
  ctl.show('streaming 1.2.3.4:49100');
  assert.equal(statusEl.classList.contains('hidden'), false);
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), true);
});

test('loadeddata also hides the readout (first-frame fallback)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  createStatusController(statusEl, videoEl, silentLogger);
  videoEl.emit('loadeddata');
  assert.equal(statusEl.classList.contains('hidden'), true);
});

test('re-showing after a hide makes the readout visible again (reconnect/error)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger);
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), true);
  ctl.show('connection failed', true);
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
});

test('show routes to logger.info, error to logger.error', () => {
  const calls = [];
  const logger = {
    info: (m) => calls.push(['info', m]),
    error: (m) => calls.push(['error', m]),
  };
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), logger);
  ctl.show('up');
  ctl.show('down', true);
  assert.deepEqual(calls, [
    ['info', '[stream] up'],
    ['error', '[stream] down'],
  ]);
});

test('tolerates a null status element and a null video element', () => {
  const ctl = createStatusController(null, null, silentLogger);
  assert.doesNotThrow(() => ctl.show('anything'));
  assert.doesNotThrow(() => ctl.hide());
});

// --- producer disappearing mid-session (issue #56) ------------------------
// stopped() / terminated() are the DOM-free mapping of the streaming library's
// two unused lifecycle handlers (onStop / onTerminate) onto the readout, so a
// dead producer stops being a silent frozen frame. They take no arguments: the
// library's message payload for those two handlers is not verifiable from this
// repo (the upstream sample only console.logs it), so they are treated as bare
// signals. (onTerminate turned out never to fire at all -- see the #58 block
// below; terminated() is now reached from the escalation timer instead.)

test('stopped() re-shows the readout as a recoverable, waiting state (#56, #60)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, clockOptions(fakeClock()));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.emit('playing'); // normal stream: readout cleared
  assert.equal(statusEl.classList.contains('hidden'), true);

  ctl.stopped(); // producer went away mid-session
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.match(statusEl.textContent, /stopped/i);
  // It describes what the viewer is doing -- waiting to see whether frames
  // resume -- and nothing more (#60).
  assert.match(statusEl.textContent, /waiting/i);
  // Recoverable, not terminal: the stream may still come back inside the
  // escalation window (#58), so no error class yet.
  assert.equal(statusEl.classList.contains('error'), false);
});

// The recoverable copy used to read "stream stopped -- reconnecting...", which
// was false: `maxReconnects` reaches the library as `maxSessionStartRetry` and
// is consumed only by the session-START retry decision, so a producer that dies
// after the stream is up is never reconnected to. The message promised a
// recovery that could not happen, for the whole ~15 s before the terminal state
// (#59) replaced it. Locked as a regression: no claim of an automatic reconnect
// in either producer-loss state.
test('no producer-loss state claims a reconnect is under way (#60)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger, clockOptions(clock));

  ctl.stopped();
  assert.doesNotMatch(statusEl.textContent, /reconnect/i);

  clock.fire(); // escalated to the terminal state
  assert.doesNotMatch(statusEl.textContent, /reconnect/i);
});

test('terminated() shows a distinct terminal state (#56)', () => {
  const statusEl = fakeStatusEl();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger);
  ctl.terminated();
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.match(statusEl.textContent, /ended|gone/i);
  // Distinct from the recoverable copy: no reconnect claim (#60), no waiting.
  assert.doesNotMatch(statusEl.textContent, /reconnect|waiting/i);
});

test('the terminal state is sticky: a later stopped() does not downgrade it (#56)', () => {
  const statusEl = fakeStatusEl();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger);
  ctl.terminated();
  const terminalText = statusEl.textContent;
  ctl.stopped();
  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.equal(statusEl.classList.contains('hidden'), false);
});

test('a stray video event does not clear the terminal state (#56)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger);
  ctl.terminated();
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), false);
});

test('stopped() logs as info, terminated() logs as error (#56)', () => {
  const calls = [];
  const logger = {
    info: (m) => calls.push(['info', m]),
    error: (m) => calls.push(['error', m]),
  };
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), logger, clockOptions(fakeClock()));
  ctl.stopped();
  ctl.terminated();
  assert.deepEqual(
    calls.map(([level]) => level),
    ['info', 'error'],
  );
});

test('a normal stream is unchanged by the #56 wiring: first frame still clears (#53)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger);
  // Exactly the happy path main.ts drives: connect -> onStart -> first frame.
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.emit('loadeddata');
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('lifecycle transitions tolerate null status / video elements (#56)', () => {
  const ctl = createStatusController(null, null, silentLogger, clockOptions(fakeClock()));
  assert.doesNotThrow(() => ctl.stopped());
  assert.doesNotThrow(() => ctl.terminated());
});

// --- deriving the terminal state locally (issue #58) -----------------------
// #56/#57 reached terminated() only from the library's `onTerminate` handler.
// That handler is never invoked by this library build (grep of the shipped
// /app/stream-only/dist/assets/omniverse-webrtc-streaming-library-*.js: the
// name occurs only as an error-code enum, an error string, and the null entry
// of the defaults object -- no call site), so the terminal state was
// unreachable and a dead producer sat on "reconnecting..." forever.
//
// The controller now derives it: stopped() arms a bounded escalation timer and
// the next rendered frame (the #53 hide path) disarms it. The timer is
// injected (fakeClock / clockOptions, defined with the other fakes at the top),
// so these specs never wait on a real clock.

test('nothing is armed before a stop: show() alone schedules no escalation (#58)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), silentLogger, clockOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  assert.equal(clock.pending.length, 0);
});

test('stopped() arms the escalation timer with the injected delay (#58)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), silentLogger, clockOptions(clock));
  ctl.stopped();
  assert.equal(clock.pending.length, 1);
  assert.equal(clock.pending[0].ms, FAKE_DELAY_MS);
});

test('escalate-on-timeout: no frame within the window reaches the terminal state, with no onTerminate (#58)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, clockOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.emit('playing'); // live stream, readout cleared
  ctl.stopped(); // producer died
  assert.equal(statusEl.classList.contains('error'), false);

  clock.fire(); // the window elapsed with no new frame

  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.match(statusEl.textContent, /ended|gone/i);
  assert.doesNotMatch(statusEl.textContent, /reconnect|waiting/i);
});

test('cancel-on-recovery: a frame after stopped() disarms the escalation and clears the readout (#53, #58)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, clockOptions(clock));
  ctl.stopped();
  assert.equal(clock.pending.length, 1);

  videoEl.emit('playing'); // the stream came back

  assert.equal(clock.pending.length, 0);
  assert.equal(statusEl.classList.contains('hidden'), true);

  clock.fire(); // a stale timer must not resurrect the terminal state
  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('a stop after a recovery re-arms the escalation (#58)', () => {
  const videoEl = fakeVideoEl();
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), videoEl, silentLogger, clockOptions(clock));
  ctl.stopped();
  videoEl.emit('playing');
  assert.equal(clock.pending.length, 0);
  ctl.stopped();
  assert.equal(clock.pending.length, 1);
});

test('repeated stopped() keeps exactly one escalation armed (#58)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), silentLogger, clockOptions(clock));
  ctl.stopped();
  ctl.stopped();
  ctl.stopped();
  assert.equal(clock.pending.length, 1);
});

test('the escalated terminal state is latched: a later stopped() neither downgrades it nor re-arms (#57, #58)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger, clockOptions(clock));
  ctl.stopped();
  clock.fire();
  const terminalText = statusEl.textContent;

  ctl.stopped();

  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.equal(clock.pending.length, 0);
});

test('a stray video event does not clear the escalated terminal state (#57, #58)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, clockOptions(clock));
  ctl.stopped();
  clock.fire();
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
});

test('terminated() disarms a pending escalation (no second transition) (#58)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), silentLogger, clockOptions(clock));
  ctl.stopped();
  ctl.terminated();
  assert.equal(clock.pending.length, 0);
});

test('the escalation logs the terminal state as an error (#58)', () => {
  const calls = [];
  const logger = {
    info: (m) => calls.push(['info', m]),
    error: (m) => calls.push(['error', m]),
  };
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), logger, clockOptions(clock));
  ctl.stopped();
  clock.fire();
  assert.deepEqual(
    calls.map(([level]) => level),
    ['info', 'error'],
  );
});

test('the escalation tolerates null status / video elements (#58)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(null, null, silentLogger, clockOptions(clock));
  assert.doesNotThrow(() => ctl.stopped());
  assert.doesNotThrow(() => clock.fire());
});

// The default delay is asserted as a value only -- deliberately WITHOUT calling
// stopped(), which would arm a real setTimeout and hold the test runner open.
// The lower bound is what keeps the config-dial e2e (test/e2e/config-dial.spec.ts,
// which asserts #stream-status carries no `error` class while dialing a dead
// host) unaffected by this escalation.
test('the default escalation delay is exported and outlasts the e2e assertion window (#58)', () => {
  assert.equal(typeof TERMINAL_ESCALATION_MS, 'number');
  assert.ok(TERMINAL_ESCALATION_MS >= 10_000, `too short: ${TERMINAL_ESCALATION_MS}`);
});

// --- producer loss detected from the media itself (issue #62) --------------
// Everything above reaches the loss states only through stopped(), i.e. only
// through the library's `onStop` callback. That is the #58 failure mode one
// step removed: an opaque third-party callback is the SOLE trigger, so if it
// stops firing (as `onTerminate` already did) the states become unreachable --
// and unreachable in a browser test too, since no test can make the library
// call it.
//
// So the controller now also watches the thing the user actually experiences:
// frame progress on the video element. Frames that stop advancing for
// `stallSamples` consecutive `stallPollMs` polls announce the SAME recoverable
// state, which then escalates through the SAME #58 timer to the SAME latched
// terminal state. `onStop` is kept as an accelerator (it announces sooner than
// the poll can), never as the only way in.
//
// The watchdog only arms once a frame has actually rendered AND the element can
// report progress, which is what keeps a dead-host page (config-dial e2e: no
// frames, ever) and every pre-#62 spec above untouched.

test('a video element that reports no frame progress never arms the watchdog (#62)', () => {
  const clock = fakeClock();
  const videoEl = fakeVideoEl(); // no getVideoPlaybackQuality / currentTime
  const ctl = createStatusController(fakeStatusEl(), videoEl, silentLogger, watchdogOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.emit('playing');
  assert.equal(clock.pending.length, 0);
});

test('the watchdog arms on the first rendered frame, not before (#62)', () => {
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(fakeStatusEl(), videoEl, silentLogger, watchdogOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  // Nothing rendered yet (the dead-host case): the viewer is still connecting,
  // so a stalled picture is not a producer that went away.
  assert.equal(clock.pending.length, 0);

  videoEl.renderFrame();
  videoEl.emit('playing');

  assert.deepEqual(
    clock.pending.map((t) => t.ms),
    [FAKE_POLL_MS],
  );
});

test('frames that keep arriving never announce a loss (#62)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, watchdogOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.renderFrame();
  videoEl.emit('playing');

  for (let i = 0; i < FAKE_SAMPLES * 4; i += 1) {
    videoEl.renderFrame();
    pollTimes(clock, 1);
  }

  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('frames that stop arriving announce the recoverable state, with no onStop (#62)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, watchdogOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.renderFrame();
  videoEl.emit('playing');

  pollTimes(clock, FAKE_SAMPLES - 1); // still inside the tolerance
  assert.equal(statusEl.classList.contains('hidden'), true);

  pollTimes(clock, 1); // the stall is now long enough to mean something

  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.match(statusEl.textContent, /stopped/i);
  assert.match(statusEl.textContent, /waiting/i);
  // Recoverable, not terminal, and no reconnect claim (#57, #60).
  assert.equal(statusEl.classList.contains('error'), false);
  assert.doesNotMatch(statusEl.textContent, /reconnect/i);
  // ... and it armed the ordinary #58 escalation, not some second mechanism.
  assert.equal(clock.pending.filter((t) => t.ms === FAKE_DELAY_MS).length, 1);
});

test('resumed frames clear a media-detected loss and disarm the escalation (#53, #62)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, watchdogOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.renderFrame();
  videoEl.emit('playing');
  pollTimes(clock, FAKE_SAMPLES);
  assert.equal(statusEl.classList.contains('hidden'), false);

  videoEl.renderFrame(); // the picture came back
  pollTimes(clock, 1);

  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
  assert.equal(clock.pending.filter((t) => t.ms === FAKE_DELAY_MS).length, 0);
});

test('a media-detected stall escalates to the same terminal state (#58, #62)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, watchdogOptions(clock));
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.renderFrame();
  videoEl.emit('playing');
  pollTimes(clock, FAKE_SAMPLES);

  clock.fireEvery(FAKE_DELAY_MS); // the escalation window elapsed, still no frame

  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.match(statusEl.textContent, /ended|gone/i);
  assert.doesNotMatch(statusEl.textContent, /reconnect|waiting/i);
});

test('onStop stays an accelerator: a stall after it neither re-announces nor re-arms (#62)', () => {
  const calls = [];
  const logger = {
    info: (m) => calls.push(['info', m]),
    error: (m) => calls.push(['error', m]),
  };
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(fakeStatusEl(), videoEl, logger, watchdogOptions(clock));
  videoEl.renderFrame();
  videoEl.emit('playing');

  ctl.stopped(); // the library got there first
  const armed = clock.pending.find((t) => t.ms === FAKE_DELAY_MS);
  calls.length = 0;

  pollTimes(clock, FAKE_SAMPLES * 2); // the watchdog now sees the same stall

  assert.deepEqual(calls, []); // announced once, by whoever noticed first
  const still = clock.pending.filter((t) => t.ms === FAKE_DELAY_MS);
  assert.equal(still.length, 1);
  // Same timer, so the terminal state still lands one window after the FIRST
  // signal -- a watchdog that re-armed would push it back indefinitely.
  assert.equal(still[0].id, armed.id);
});

// This spec used to assert the opposite of its second half -- that frames after
// the terminal state could not clear it, and that no poll was left running.
// That was the #73 defect, written down: see the #73 block at the end of this
// file for why observed media outranks the verdict a timer produced.
test('the terminal state keeps a recovery watch: a frozen picture holds it, advancing frames clear it (#62, #73)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  // No handle needed: everything below is driven through the element and the
  // clock, which is the point -- no caller announced this loss, and no caller
  // clears it either.
  createStatusController(statusEl, videoEl, silentLogger, watchdogOptions(clock));
  videoEl.renderFrame();
  videoEl.emit('playing');
  pollTimes(clock, FAKE_SAMPLES);
  clock.fireEvery(FAKE_DELAY_MS);
  const terminalText = statusEl.textContent;

  // The poll survives the transition, because there is still something worth
  // watching for -- but what it watches for is now a recovery, not a stall.
  assert.deepEqual(
    clock.pending.map((t) => t.ms),
    [FAKE_POLL_MS],
  );

  // The picture is still frozen: the watch finds nothing and the terminal state
  // is exactly where it was, poll after poll.
  pollTimes(clock, FAKE_SAMPLES * 2);
  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);

  // Frames advance again. No video event is involved here on purpose: after a
  // stall long enough to escalate, `playing` does not necessarily re-fire, so
  // the watchdog has to be able to notice the recovery on its own.
  videoEl.renderFrame();
  pollTimes(clock, 1);

  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('the exported stall window is long enough to ride out a brief hiccup (#62)', () => {
  assert.equal(typeof FRAME_STALL_POLL_MS, 'number');
  assert.equal(typeof FRAME_STALL_SAMPLES, 'number');
  // A frozen picture is only news once it has been frozen for a while: too
  // short and an ordinary hiccup shows a producer-loss readout over a stream
  // that is fine.
  assert.ok(
    FRAME_STALL_POLL_MS * FRAME_STALL_SAMPLES >= 3_000,
    `stall window too short: ${FRAME_STALL_POLL_MS} x ${FRAME_STALL_SAMPLES}`,
  );
  // And it must stay well inside the escalation window, so the state the user
  // sees first is still the recoverable one.
  assert.ok(
    FRAME_STALL_POLL_MS * FRAME_STALL_SAMPLES < TERMINAL_ESCALATION_MS,
    'the stall window must not outlast the escalation window',
  );
});

// --- a stream that never starts (issue #63) --------------------------------
// Everything above assumes the stream came up at least once: the loss states
// are entered from onStop or from frames that stop advancing, and the #53 hide
// needs a frame. A viewer pointed at a producer that never answers reaches none
// of them -- no frame, so no hide and no watchdog; no session, so no onStop and
// no escalation -- and the app used to leave it on `streaming <server>:<port>`
// forever, because it treated the library's `onStart` as success. `onStart`
// only means a connect attempt BEGAN, and it re-fires on every session-start
// retry (observed five times against a dead producer), which also let a retry
// overwrite the latched terminal state through the one method that had no
// terminal guard: show().
//
// So the controller now takes the connect attempt as a state of its own:
// connecting(text) says the viewer is TRYING and arms the same kind of bounded
// window, from the attempt rather than from a loss. A real first frame cancels
// it exactly as it cancels the #58 escalation; nothing else does.

test('connecting() shows the attempting readout and arms a bounded window (#63)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger, connectOptions(clock));

  ctl.connecting('connecting to 1.2.3.4:49100...');

  assert.equal(statusEl.textContent, 'connecting to 1.2.3.4:49100...');
  assert.equal(statusEl.classList.contains('hidden'), false);
  // Trying is not failing: no error styling while the window is open (#57).
  assert.equal(statusEl.classList.contains('error'), false);
  assert.deepEqual(
    clock.pending.map((t) => t.ms),
    [FAKE_CONNECT_MS],
  );
});

test('never-connected: the connect window elapsing reaches an actionable state (#63)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger, connectOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');

  clock.fire(); // the window elapsed and not one frame ever rendered

  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
  // Actionable: it names what is wrong and what to do about it.
  assert.match(statusEl.textContent, /no video/i);
  assert.match(statusEl.textContent, /reload/i);
  // And it does not claim a stream, a recovery or a reconnect (#60).
  assert.doesNotMatch(statusEl.textContent, /streaming|waiting|reconnect/i);
});

test('the never-started state is distinct from the mid-session terminal one (#63)', () => {
  const neverStartedEl = fakeStatusEl();
  const clock = fakeClock();
  const neverStarted = createStatusController(
    neverStartedEl,
    fakeVideoEl(),
    silentLogger,
    connectOptions(clock),
  );
  neverStarted.connecting('connecting to 1.2.3.4:49100...');
  clock.fire();

  const midSessionEl = fakeStatusEl();
  createStatusController(midSessionEl, fakeVideoEl(), silentLogger).terminated();

  // Both are terminal errors, but they are not the same news: nothing ended
  // when nothing ever started, and the user's next move differs (check that the
  // producer is running at all, vs. wait for the one that died to come back).
  assert.notEqual(neverStartedEl.textContent, midSessionEl.textContent);
  assert.doesNotMatch(neverStartedEl.textContent, /ended/i);
});

test('a first frame cancels the connect escalation and clears the readout (#53, #63)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, connectOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');
  assert.equal(clock.pending.length, 1);

  videoEl.emit('playing'); // the stream really did come up

  assert.equal(clock.pending.length, 0);
  assert.equal(statusEl.classList.contains('hidden'), true);

  clock.fire(); // a stale timer must not declare a live stream dead
  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('session-start retries do not push the connect deadline back (#63)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), silentLogger, connectOptions(clock));

  // `onStart` re-fires on every session-start retry (five times, against a
  // producer that was never there). Re-arming on each would move the deadline
  // out by a whole window every time -- i.e. back to never.
  ctl.connecting('connecting to 1.2.3.4:49100...');
  const armed = clock.pending[0];
  ctl.connecting('connecting to 1.2.3.4:49100...');
  ctl.connecting('connecting to 1.2.3.4:49100...');

  assert.equal(clock.pending.length, 1);
  assert.equal(clock.pending[0].id, armed.id);
});

test('show() cannot overwrite the terminal state (#63)', () => {
  const statusEl = fakeStatusEl();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger);
  ctl.terminated();
  const terminalText = statusEl.textContent;

  ctl.show('streaming 1.2.3.4:49100'); // a retry re-announcing a dead stream

  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.equal(statusEl.classList.contains('hidden'), false);
});

test('connecting() after the terminal state is ignored (#63)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger, connectOptions(clock));
  ctl.terminated();
  const terminalText = statusEl.textContent;

  ctl.connecting('connecting to 1.2.3.4:49100...');

  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.equal(clock.pending.length, 0);
});

test('a connect retry does not overwrite an announced producer loss (#63)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger, connectOptions(clock));
  ctl.stopped(); // the producer went away mid-session
  const armed = clock.pending[0];

  ctl.connecting('connecting to 1.2.3.4:49100...');

  // The loss state owns the readout until a frame clears it or it escalates:
  // an attempt that has produced no picture is not news over a loss that has.
  assert.match(statusEl.textContent, /waiting/i);
  assert.equal(clock.pending.length, 1);
  assert.equal(clock.pending[0].id, armed.id);
  assert.equal(clock.pending[0].ms, FAKE_DELAY_MS);
});

test('the connect escalation tolerates null status / video elements (#63)', () => {
  const clock = fakeClock();
  const ctl = createStatusController(null, null, silentLogger, connectOptions(clock));
  assert.doesNotThrow(() => ctl.connecting('connecting to 1.2.3.4:49100...'));
  assert.doesNotThrow(() => clock.fire());
});

// Asserted as a value only, like the #58 delay above: calling connecting()
// without an injected clock would arm a real setTimeout and hold the runner
// open. The lower bound is what keeps the config-dial e2e (which dials a DEAD
// host and asserts #stream-status carries no `error` class) unaffected -- that
// suite finishes in well under a second per mode, and its longest poll is 15 s.
test('the default connect window is exported and outlasts the config-dial e2e (#63)', () => {
  assert.equal(typeof CONNECT_ESCALATION_MS, 'number');
  assert.ok(CONNECT_ESCALATION_MS >= 15_000, `too short: ${CONNECT_ESCALATION_MS}`);
});

// --- a real frame outranks the timer's verdict (issue #73) -----------------
// #63 latched the terminal state for a reason that still holds: `onStart`
// re-fires on every session-start retry, so a retry could otherwise repaint
// `streaming <server>:<port>` over a genuine failure and re-assert a connection
// that does not exist. What that latch over-reached into is OBSERVATION. It
// also discarded the one signal that cannot lie -- frames advancing on the
// video element, the signal #62 deliberately moved this whole state machine
// onto -- so a producer that came up 2 s after the connect window closed left a
// red `no video from the source` permanently on top of a picture that was
// demonstrably playing (v0.3.0-rc2 tag run: terminal at 06:19:48.863, frames
// advancing at 06:19:50.997, meanLuma 151.99, readout still there 30 s later).
//
// So the latch outranks CLAIMS and not OBSERVATION:
//   - claims  -- show() from `onStart`, connecting(), stopped(): still blocked
//   - media   -- hide() from a video event, and the watchdog seeing progress
//                advance past where it stood when the latch closed: clears it
//
// "Advanced past" is the whole distinction, and it is what keeps the #56 / #57
// stray-video-event specs above true on the progress-free fake: a `playing`
// event from an element that reports no frame progress at all is a claim like
// any other, and cannot reopen anything.

test('frames that arrive after the connect window elapsed clear the terminal state (#73)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, recoveryOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');

  clock.fireEvery(FAKE_CONNECT_MS); // the window elapsed with no picture
  assert.match(statusEl.textContent, /no video/i);
  assert.equal(statusEl.classList.contains('error'), true);

  videoEl.renderFrame(); // ... and then the producer finally came up
  videoEl.emit('playing');

  // Silently, deliberately: the user is looking at a working picture and does
  // not need to be told about a verdict that turned out to be wrong.
  assert.equal(statusEl.classList.contains('hidden'), true);
  assert.equal(statusEl.classList.contains('error'), false);
});

test('a session-start retry still cannot touch the terminal state, even once frames advance (#63, #73)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, recoveryOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');
  clock.fireEvery(FAKE_CONNECT_MS);
  const terminalText = statusEl.textContent;

  videoEl.renderFrame(); // the media now says the stream is alive ...
  ctl.connecting('connecting to 1.2.3.4:49100...'); // ... a claim still says nothing
  ctl.show('streaming 1.2.3.4:49100');

  // #63 intact: the retry neither overwrites the readout nor arms a window.
  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(clock.pending.filter((t) => t.ms === FAKE_CONNECT_MS).length, 0);

  // The media path, on the same controller and the same frames, still can.
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), true);
});

test('stopped() cannot touch the terminal state either, even once frames advance (#57, #73)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, recoveryOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');
  clock.fireEvery(FAKE_CONNECT_MS);
  const terminalText = statusEl.textContent;

  videoEl.renderFrame();
  ctl.stopped(); // the library's onStop, arriving after the fact

  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.equal(clock.pending.filter((t) => t.ms === FAKE_DELAY_MS).length, 0);
});

test('a terminal state with no frames stays terminal, poll after poll (#63, #73)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, recoveryOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');
  clock.fireEvery(FAKE_CONNECT_MS);
  const terminalText = statusEl.textContent;

  // The #63 case: the producer really is not there. Nothing renders, ever.
  pollTimes(clock, FAKE_SAMPLES * 4);
  videoEl.emit('playing'); // a video event with no frame behind it is not evidence

  assert.equal(statusEl.textContent, terminalText);
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
});

test('a recovered viewer is a live viewer again: a later stall re-announces and re-escalates (#73)', () => {
  const statusEl = fakeStatusEl();
  const clock = fakeClock();
  const videoEl = fakeStreamingVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger, recoveryOptions(clock));
  ctl.connecting('connecting to 1.2.3.4:49100...');
  clock.fireEvery(FAKE_CONNECT_MS);
  videoEl.renderFrame();
  videoEl.emit('playing');
  assert.equal(statusEl.classList.contains('hidden'), true);

  // Un-latching is a real state change, not just a hidden element: the whole
  // machine works again from here, including the states that produced the
  // wrong verdict in the first place.
  pollTimes(clock, FAKE_SAMPLES);
  assert.match(statusEl.textContent, /waiting/i);
  assert.equal(statusEl.classList.contains('error'), false);

  clock.fireEvery(FAKE_DELAY_MS);
  assert.match(statusEl.textContent, /ended|gone/i);
  assert.equal(statusEl.classList.contains('error'), true);
});
