// Unit tests for buildStreamConfig (Node's built-in runner, no vitest).
//   node --test
// Pure ESM, no DOM, no bundler, no @nvidia import -- runs without a workspace
// install. Imports the source by relative path; apps import via 'stream-core'.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildStreamConfig } from '../src/buildStreamConfig.js';

test('builds a DIRECT config for a valid server + numeric port', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100);
  assert.equal(cfg.signalingServer, '127.0.0.1');
  assert.equal(cfg.mediaServer, '127.0.0.1');
  assert.equal(cfg.signalingPort, 49100);
  assert.equal(typeof cfg.signalingPort, 'number');
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

// --- media port (D1): optional 3rd arg, omitted when null, pinned when given ---

test('omits mediaPort when not given (default null = negotiate)', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100);
  assert.equal('mediaPort' in cfg, false);
});

test('omits mediaPort when explicitly null', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100, null);
  assert.equal('mediaPort' in cfg, false);
});

test('pins mediaPort when given a valid integer', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100, 47998);
  assert.equal(cfg.mediaPort, 47998);
  assert.equal(typeof cfg.mediaPort, 'number');
});

test('coerces a numeric string mediaPort', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100, '48098');
  assert.equal(cfg.mediaPort, 48098);
  assert.equal(typeof cfg.mediaPort, 'number');
});

test('throws on a non-integer mediaPort', () => {
  assert.throws(() => buildStreamConfig('host', 49100, 47998.5), /mediaPort/i);
});

test('throws on an out-of-range mediaPort', () => {
  assert.throws(() => buildStreamConfig('host', 49100, 0), /mediaPort/i);
  assert.throws(() => buildStreamConfig('host', 49100, 70000), /mediaPort/i);
});
