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
