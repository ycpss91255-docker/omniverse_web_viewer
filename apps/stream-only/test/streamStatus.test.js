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
import { createStatusController } from '../src/streamStatus.js';

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
// signals.

test('stopped() re-shows the readout as a recoverable, reconnecting state (#56)', () => {
  const statusEl = fakeStatusEl();
  const videoEl = fakeVideoEl();
  const ctl = createStatusController(statusEl, videoEl, silentLogger);
  ctl.show('streaming 1.2.3.4:49100');
  videoEl.emit('playing'); // normal stream: readout cleared
  assert.equal(statusEl.classList.contains('hidden'), true);

  ctl.stopped(); // producer went away mid-session
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.match(statusEl.textContent, /stopped/i);
  assert.match(statusEl.textContent, /reconnect/i);
  // Recoverable, not terminal: the library is still retrying (maxReconnects).
  assert.equal(statusEl.classList.contains('error'), false);
});

test('terminated() shows a distinct terminal state (#56)', () => {
  const statusEl = fakeStatusEl();
  const ctl = createStatusController(statusEl, fakeVideoEl(), silentLogger);
  ctl.terminated();
  assert.equal(statusEl.classList.contains('hidden'), false);
  assert.equal(statusEl.classList.contains('error'), true);
  assert.match(statusEl.textContent, /ended|gone/i);
  assert.doesNotMatch(statusEl.textContent, /reconnecting/i);
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
  const ctl = createStatusController(fakeStatusEl(), fakeVideoEl(), logger);
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
  const ctl = createStatusController(null, null, silentLogger);
  assert.doesNotThrow(() => ctl.stopped());
  assert.doesNotThrow(() => ctl.terminated());
});
