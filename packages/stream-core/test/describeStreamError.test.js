// Unit tests for describeStreamError (node --test). Pure, no DOM, no library.
//
// The shapes below are not invented. They were read out of the streaming
// library bundle that ships in this repo's image
// (/app/stream-only/dist/assets/omniverse-webrtc-streaming-library-*.js):
// eighteen `throw{action:...,status:...,info:"..."}` sites, where `info`
// carries the only sentence a user could act on. Both viewers rendered these
// with `String(e)`, which is "[object Object]".
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { describeStreamError } from '../src/describeStreamError.js';

test('a library rejection surfaces its info, not [object Object]', () => {
  const thrown = {
    action: 'start',
    status: 'error',
    info: 'Failed to connect to current stream',
  };
  const text = describeStreamError(thrown);
  assert.equal(text, 'Failed to connect to current stream');
  assert.ok(!text.includes('[object Object]'));
});

test('an info carrying newlines is kept whole', () => {
  const text = describeStreamError({
    action: 'start',
    status: 'error',
    info: 'Invalid prop DirectConfig.maxReconnects: -1\nExpected >= 0',
  });
  assert.match(text, /maxReconnects: -1/);
  assert.match(text, /Expected >= 0/);
});

test('an Error surfaces its message', () => {
  assert.equal(describeStreamError(new Error('boom')), 'boom');
});

test('a plain string is returned unchanged', () => {
  assert.equal(describeStreamError('no signalling server'), 'no signalling server');
});

test('an object with message but no info uses message', () => {
  assert.equal(describeStreamError({ message: 'nope' }), 'nope');
});

test('an object with neither is serialised rather than stringified', () => {
  const text = describeStreamError({ action: 'stop', status: 'error' });
  assert.ok(!text.includes('[object Object]'));
  assert.match(text, /stop/);
});

test('a non-string info is serialised rather than stringified', () => {
  const text = describeStreamError({ info: { code: 7 } });
  assert.ok(!text.includes('[object Object]'));
  assert.match(text, /7/);
});

test('null and undefined get a stable sentence, never "null"', () => {
  for (const value of [null, undefined]) {
    const text = describeStreamError(value);
    assert.ok(text.length > 0);
    assert.notEqual(text, 'null');
    assert.notEqual(text, 'undefined');
  }
});

test('a circular object does not throw out of the renderer', () => {
  const circular = { action: 'start' };
  circular.self = circular;
  const text = describeStreamError(circular);
  assert.equal(typeof text, 'string');
  assert.ok(text.length > 0);
});

test('the renderer never throws, whatever it is handed', () => {
  const hostile = {
    get info() {
      throw new Error('getter blew up');
    },
  };
  const text = describeStreamError(hostile);
  assert.equal(typeof text, 'string');
  assert.ok(text.length > 0);
});
