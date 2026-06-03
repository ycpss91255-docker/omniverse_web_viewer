// Unit tests for buildStreamConfig (Node's built-in runner, no vitest).
//   node --test
// Pure ESM, no DOM, no bundler -- this is why buildStreamConfig lives in a
// plain .js module separated from the DOM wiring in main.ts.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildStreamConfig } from './buildStreamConfig.js';

test('builds a DIRECT config for a valid server + numeric port', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100);
  assert.equal(cfg.signalingServer, '127.0.0.1');
  assert.equal(cfg.mediaServer, '127.0.0.1');
  assert.equal(cfg.signalingPort, 49100);
  assert.equal(typeof cfg.signalingPort, 'number');
  // Stream-only direct-connect essentials the streaming library needs.
  assert.equal(cfg.videoElementId, 'remote-video');
  assert.equal(cfg.audioElementId, 'remote-audio');
  assert.equal(cfg.authenticate, true);
});

test('accepts a numeric string port and coerces it to a number', () => {
  const cfg = buildStreamConfig('host.local', '49100');
  assert.equal(cfg.signalingPort, 49100);
  assert.equal(typeof cfg.signalingPort, 'number');
});

test('accepts a hostname as server', () => {
  const cfg = buildStreamConfig('isaac-host', 8011);
  assert.equal(cfg.signalingServer, 'isaac-host');
});

test('throws on empty server', () => {
  assert.throws(() => buildStreamConfig('', 49100), /server/i);
});

test('throws on whitespace-only server', () => {
  assert.throws(() => buildStreamConfig('   ', 49100), /server/i);
});

test('throws on an unsubstituted sentinel server (dev without config)', () => {
  assert.throws(() => buildStreamConfig('__OWV_SERVER__', 49100), /server/i);
});

test('throws on a server with illegal characters', () => {
  assert.throws(() => buildStreamConfig('a;rm -rf /', 49100), /server/i);
});

test('throws on a non-numeric port', () => {
  assert.throws(() => buildStreamConfig('host', 'not-a-port'), /port/i);
});

test('throws on a non-integer port', () => {
  assert.throws(() => buildStreamConfig('host', 49100.5), /port/i);
});

test('throws on an out-of-range port', () => {
  assert.throws(() => buildStreamConfig('host', 0), /port/i);
  assert.throws(() => buildStreamConfig('host', 70000), /port/i);
});
