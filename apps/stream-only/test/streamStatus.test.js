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
import { createStatusController, TERMINAL_ESCALATION_MS } from '../src/streamStatus.js';

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
    // Everything currently armed, as {fn, ms} records.
    get pending() {
      return [...timers.values()];
    },
    // Run (and clear) everything armed, i.e. "the window elapsed".
    fire() {
      const due = [...timers.values()];
      timers.clear();
      for (const t of due) t.fn();
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
