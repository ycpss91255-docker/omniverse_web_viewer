// Unit tests for the example's resolveTarget glue (node --test, DOM-free).
// The buildStreamConfig factory moved to stream-core (tested there); the
// example now owns only this input-resolution glue.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveTarget } from '../src/resolveTarget.js';

const TARGET = { server: '__OWV_SERVER__', signalingPort: '__OWV_PORT__', mediaPort: '__OWV_MEDIA_PORT__' };

test('falls back to the entrypoint-substituted target values', () => {
  const r = resolveTarget('', { server: '10.0.0.5', signalingPort: 49100, mediaPort: 47998 });
  assert.equal(r.server, '10.0.0.5');
  assert.equal(r.port, 49100);
  assert.equal(r.mediaPort, 47998);
});

test('?server=&port= query overrides the target', () => {
  const r = resolveTarget('?server=1.2.3.4&port=49200', TARGET);
  assert.equal(r.server, '1.2.3.4');
  assert.equal(r.port, '49200');
});

test('?media= query sets the media port', () => {
  const r = resolveTarget('?server=h&port=1&media=48098', { server: 'x', signalingPort: 2, mediaPort: null });
  assert.equal(r.mediaPort, '48098');
});

test('an unsubstituted media sentinel resolves to null', () => {
  const r = resolveTarget('?server=1.2.3.4&port=49100', TARGET);
  assert.equal(r.mediaPort, null);
});

test('passes the server sentinel through unchanged (buildStreamConfig rejects it)', () => {
  const r = resolveTarget('', TARGET);
  assert.equal(r.server, '__OWV_SERVER__');
});
